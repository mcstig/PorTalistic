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
                    let application = try await NSWorkspace.shared.openApplication(at: location, configuration: configuration)
                    
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
                        application.terminate()
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
                let logHandle = Wine.beginLogging(to: logURL, describing: location)

                if let logHandle {
                    process.standardOutput = logHandle
                    process.standardError = logHandle
                }

                defer { try? logHandle?.close() }

                try process.run()

                process.waitUntilExit()

                // Put the container back — shared per runtime, so this game's settings left
                // behind would quietly become the next game's.
                await Provisioner.shared.revert(plan)
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
