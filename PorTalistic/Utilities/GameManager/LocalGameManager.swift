//
//  LocalGameManager.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 16/11/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import AppKit
import OSLog

extension LocalGameManager: GameManager {
    @MainActor static func launch(game: Game) async throws -> GameOperation {
        guard case .local = game.storefront,
              let castGame = game as? LocalGame else { throw CocoaError(.coderInvalidValue) }

        return try await launch(game: castGame)
    }

    @MainActor static func move(game: Game,
                                to newLocation: URL) async throws -> GameOperation {
        guard case .local = game.storefront,
              let castGame = game as? LocalGame else { throw CocoaError(.coderInvalidValue) }

        return try await move(game: castGame, to: newLocation)
    }

    @MainActor static func uninstall(game: Game,
                                     persistFiles: Bool) async throws -> GameOperation {
        guard case .local = game.storefront,
              let castGame = game as? LocalGame else { throw CocoaError(.coderInvalidValue) }

        return try await uninstall(game: castGame, persistFiles: persistFiles)
    }
}

class LocalGameManager {
    static var log: Logger { .custom(category: "LocalGameManager") }

    @discardableResult
    @MainActor static func launch(game: LocalGame) async throws -> GameOperation {
        guard case .installed(let location, let platform) = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        defer {
            if UserDefaults.standard.bool(forKey: "minimiseOnGameLaunch") {
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        }

        let operation: GameOperation = .init(game: game, type: .launch) { _ in
            switch platform {
            case .macOS:
                let configuration: NSWorkspace.OpenConfiguration = .init()
                configuration.arguments = game.launchArguments
                
                if (try? location.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .bundle) == true {
                    // `openApplication` can't be interrupted, and it waits for the application to
                    // finish launching — seconds, for a game. A Force Quit already pressed is heard
                    // here rather than after it.
                    try Task.checkCancellation()

                    let application = try await NSWorkspace.shared.openApplication(at: location, configuration: configuration)

                    // And one pressed while it was opening lands here, with the game up: ended now,
                    // rather than by the wait below — whose handler runs as it is entered, before
                    // there is anything listening for the game to go.
                    guard !Task.isCancelled else {
                        application.forceTerminate()
                        return
                    }

                    // A native game is up as soon as its application is.
                    await MainActor.run { Game.operationManager.noteGameAppeared(forGameID: game.id) }

                    // await application closure
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                              object: nil,
                                                                              queue: .main) { notification in
                                if let observedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                                   observedApplication == application {
                                    continuation.resume()
                                }
                            }
                        }
                    } onCancel: {
                        // Force Quit, not a request: `terminate()` asks, and a game that is still
                        // starting — or that puts up "are you sure?" — simply carries on.
                        application.forceTerminate()
                    }
                } else {
                    throw CocoaError(.serviceApplicationLaunchFailed)
                }
            case .windows:
                // Which runtime this executable wants, the container belonging to that
                // runtime, and this game's own settings written into it — the same path Epic
                // and GOG launches take. It replaces reading `game.containerURL` and hoping:
                // an imported `.exe` with no container simply refused to start, which for a
                // local game is most of them, since nothing in the import flow makes one.
                let plan = try await Provisioner.shared.planLaunch(for: game)
                let containerURL = plan.containerURL

                Self.log.notice("""
                    Launching \(game.title, privacy: .public) on \(plan.runtimeName, privacy: .public): \
                    \(plan.reasons.joined(separator: "; "), privacy: .public)
                    """)

                var environment: [String: String] = .init()
                environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: containerURL,
                                                                   overriding: plan.settings)

                if UserDefaults.standard.bool(forKey: "minimiseOnGameLaunch") {
                    NSApp.windows.first?.miniaturize(nil)
                }

                let process: Process = .init()
                process.arguments = [location.path] + game.launchArguments
                process.environment = environment

                // Games routinely load their data by relative path, so starting one from the
                // wrong directory looks like missing assets rather than like a mistake here.
                process.currentDirectoryURL = location.deletingLastPathComponent()

                Wine.transformProcess(process, containerURL: containerURL)

                // Everything Wine and the game print, kept where it can be read afterwards —
                // beside the container, one "Open…" from the person who has to send it to you.
                // Until now a local game's entire output went to the app's own stderr, which
                // means nowhere unless the app happened to be running from Xcode.
                let logURL = Wine.logURL(forGameTitled: game.title, inContainerAtURL: containerURL)
                let logHandle = Wine.beginLogging(to: logURL,
                                                  describing: location,
                                                  environment: environment)

                if let logHandle {
                    process.standardOutput = logHandle
                    process.standardError = logHandle
                }

                defer { try? logHandle?.close() }

                // How Force Quit reaches this launch, whenever it is pressed. The process used to be
                // started with nothing watching for a stop, so a Force Quit pressed while the
                // container was being set up found nothing to stop and the game started anyway.
                // Killed rather than asked: see the same launch on the Epic path.
                let launch: StoppableLaunch = .init(halting: { $0.stopIfRunning(SIGKILL) })

                // And what reaches the prefix — see the same pair on the GOG path.
                let forceQuit: Wine.ForceQuit = .init(containerAt: containerURL)

                try await withTaskCancellationHandler {
                    try launch.launch(process)
                } onCancel: {
                    launch.stop()
                }

                // See `Wine.superviseGame(named:startedAs:hidingLauncher:forGameWithID:)`: the
                // Mac driver defers the display mode until its process is active, so a game
                // that stays behind the library comes up windowed — and the person pressed
                // Play, so the game is what they asked to be looking at. The same watch is
                // what keeps the launch alive while the game is.
                let executableName = location.lastPathComponent
                let winePID = process.processIdentifier
                let launchedGameID = game.id

                // The plan and the transcript, hoisted for the same reason as the pid: the
                // post-mortem runs after the game exits, and it has to read *this* launch's
                // log against *this* launch's settings.
                let launchedPlan = plan
                let launchedTranscriptURL = logURL

                await withTaskCancellationHandler {
                    async let supervised: Void = Wine.superviseGame(named: executableName,
                                                                    startedAs: winePID,
                                                                    hidingLauncher: false,
                                                                    forGameWithID: launchedGameID,
                                                                    plan: launchedPlan,
                                                                    transcriptAt: launchedTranscriptURL)

                    await process.waitUntilExitOrCancellation()
                    await supervised
                } onCancel: {
                    // Stopping a game means stopping the prefix it runs in — see the same
                    // handler on the GOG path. Through the launch, never `terminate()`, which
                    // raises on a process that is not running.
                    launch.stop()
                    forceQuit.begin()
                }

                // Made certain before the launch is over — see `Wine.forceQuit(containerAt:)`.
                if launch.hasBeenStopped {
                    await forceQuit.finish()
                }
            }
        }

        Game.operationManager.queueOperation(operation)
        return operation
    }

    @discardableResult
    @MainActor static func move(game: LocalGame,
                                to newLocation: URL) async throws -> GameOperation {
        guard case .installed(let currentLocation, let platform) = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let operation: GameOperation = .init(game: game, type: .uninstall) {  _ in
            try FileManager.default.moveItem(at: currentLocation, to: newLocation)
            game.installationState = .installed(location: newLocation, platform: platform)
        }
        return operation
    }

    @discardableResult
    @MainActor static func uninstall(game: LocalGame,
                                     persistFiles: Bool) async throws -> GameOperation {
        guard case .installed(let location, _) = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let operation: GameOperation = .init(game: game, type: .uninstall) {  _ in
            if !persistFiles {
                try FileManager.default.removeItem(at: location)
            }
            
            game.installationState = .uninstalled
            
            // remove the game from the library if present.
            // this is only necessary for non-storefront games.
            if GameDataStore.shared.library.contains(game) {
                GameDataStore.shared.library.remove(game)
            }
        }

        Game.operationManager.queueOperation(operation)
        return operation
    }
}
