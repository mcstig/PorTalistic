//
//  GOGGameManager.swift
//  Mythic
//
//  Created by Claude (Cowork) on 13/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import AppKit
import OSLog

extension GOGGameManager: StorefrontGameManager {
    @MainActor static func launch(game: Game) async throws -> GameOperation {
        let castGame = try cast(game)
        return try await launch(game: castGame)
    }

    @MainActor static func move(game: Game,
                                to newLocation: URL) async throws -> GameOperation {
        let castGame = try cast(game)
        return try await move(game: castGame, to: newLocation)
    }

    @MainActor static func uninstall(game: Game,
                                     persistFiles: Bool) async throws -> GameOperation {
        let castGame = try cast(game)
        return try await uninstall(game: castGame, persistFiles: persistFiles)
    }

    static func install(game: Game, qualityOfService: QualityOfService) async throws -> GameOperation {
        let castGame = try cast(game)

        // The protocol doesn't carry a platform, and something has to choose one. A native
        // build is preferred where GOG ships one — no container, no translation layer — which
        // is the same choice the installation sheet defaults to.
        let supported = castGame.getSupportedPlatforms() ?? [.windows]
        let platform: Game.Platform = supported.contains(.macOS) ? .macOS : .windows

        // Straight to GOGDL rather than through this type's own `install`, whose first
        // argument is a `GOGGame`: those two overloads differ only by how specific that
        // argument is, and a resolution that picks the wrong one calls this method again
        // forever rather than failing to compile.
        return try await GOGDL.install(game: castGame, platform: platform, qualityOfService: qualityOfService)
    }

    static func update(game: Game, qualityOfService: QualityOfService) async throws -> GameOperation {
        return try await GOGDL.update(game: try cast(game), qualityOfService: qualityOfService)
    }

    static func repair(game: Game, qualityOfService: QualityOfService) async throws -> GameOperation {
        return try await GOGDL.repair(game: try cast(game), qualityOfService: qualityOfService)
    }

    static func fetchUpdateAvailability(for game: Game) throws -> Bool {
        let castGame = try cast(game)

        // Synchronous by protocol, and the answer lives on GOG's servers — so this reports
        // what the last refresh found rather than blocking a draw on a network round trip.
        // ``GOGDL/refreshUpdateAvailability(for:)`` is what puts an answer here.
        guard let cached = GOGDL.cachedUpdateAvailability(forGameID: castGame.id) else {
            throw CocoaError(.coderValueNotFound)
        }

        return cached
    }

    static func isFileVerificationRequired(for game: Game) throws -> Bool {
        // GOG has no equivalent of Epic's "this install was interrupted" flag: verification is
        // something the player asks for, not something the storefront demands.
        return false
    }

    @MainActor static func importGame(_ game: Game, platform: Game.Platform, at location: URL) async throws {
        try adoptInstallation(of: try cast(game), platform: platform, at: location)
    }

    private static func cast(_ game: Game) throws -> GOGGame {
        guard case .gog = game.storefront,
              let castGame = game as? GOGGame else { throw CocoaError(.coderInvalidValue) }

        return castGame
    }
}

/// Installing, updating and running the games on a GOG account.
///
/// Downloads are ``GOGDL``'s: GOG serves games through Galaxy's content system, and Mythic
/// bundles the tool that speaks it rather than reimplementing it. What's left here is
/// everything that happens either side of a download — where a game goes, what to run when it
/// gets there, and what to forget when it's removed.
class GOGGameManager {
    static var log: Logger { .custom(category: "GOGGameManager") }

    struct NoLaunchTargetError: LocalizedError {
        let title: String
        var errorDescription: String? { String(localized: "PorTalistic couldn't work out how to start \(title).") }
        var recoverySuggestion: String? {
            String(localized: "Its install may be incomplete. Verifying the game's files should repair it.")
        }
    }

    // MARK: - Installation

    @discardableResult
    @MainActor static func install(game: GOGGame,
                                   platform: Game.Platform,
                                   qualityOfService: QualityOfService = .default,
                                   baseDirectoryURL: URL? = UserDefaults.standard.url(forKey: "installBaseURL")) async throws -> GameOperation {
        return try await GOGDL.install(game: game,
                                       platform: platform,
                                       qualityOfService: qualityOfService,
                                       baseDirectoryURL: baseDirectoryURL)
    }

    @discardableResult
    @MainActor static func update(game: GOGGame, qualityOfService: QualityOfService = .default) async throws -> GameOperation {
        return try await GOGDL.update(game: game, qualityOfService: qualityOfService)
    }

    @discardableResult
    @MainActor static func repair(game: GOGGame, qualityOfService: QualityOfService = .default) async throws -> GameOperation {
        return try await GOGDL.repair(game: game, qualityOfService: qualityOfService)
    }

    /// Adopts a copy that's already on disk — one GOG Galaxy installed, or an offline installer left behind.
    @MainActor static func adoptInstallation(of game: GOGGame, platform: Game.Platform, at location: URL) throws {
        guard FileManager.default.fileExists(atPath: location.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        // Proof that this really is the game, and not a folder that happens to be named after
        // it: every GOG install carries its own `goggame-<id>.info`, and without one nothing
        // downstream would know what to run.
        guard GOGDL.primaryLaunchTarget(forGameAt: location, id: game.id, platform: platform) != nil else {
            throw NoLaunchTargetError(title: game.title)
        }

        game.installationState = .installed(location: location, platform: platform)
        GameDataStore.shared.library.update(with: game)
    }

    // MARK: - Running

    @discardableResult
    @MainActor static func launch(game: GOGGame) async throws -> GameOperation {
        guard case .installed(let location, let platform) = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let shouldHideLauncher = UserDefaults.standard.bool(forKey: "minimiseOnGameLaunch")

        let operation: GameOperation = .init(game: game, type: .launch) { _ in
            switch platform {
            case .macOS:
                // A macOS build from GOG *is* an app bundle — the install directory and the
                // thing to open are the same path — so there's nothing to resolve.
                let configuration: NSWorkspace.OpenConfiguration = .init()
                configuration.arguments = game.launchArguments

                guard (try? location.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .bundle) == true else {
                    throw CocoaError(.serviceApplicationLaunchFailed)
                }

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

                // A native game is up the moment its application is: no Wine, nothing to
                // identify by arrival, and `openApplication` has already waited for it.
                await MainActor.run { Game.operationManager.noteGameAppeared(forGameID: game.id) }

                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        NSWorkspace.shared.notificationCenter.addObserver(
                            forName: NSWorkspace.didTerminateApplicationNotification,
                            object: nil,
                            queue: .main
                        ) { notification in
                            if let observed = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                               observed == application {
                                continuation.resume()
                            }
                        }
                    }
                } onCancel: {
                    // Force Quit, not a request: `terminate()` asks, and a game that is still
                    // starting — or that puts up "are you sure?" — simply carries on.
                    application.forceTerminate()
                }

            case .windows:
                // A Windows install is a directory, so what to run has to be read out of the
                // game's own play tasks rather than assumed to be the location itself.
                guard let target = GOGDL.primaryLaunchTarget(forGameAt: location, id: game.id, platform: platform) else {
                    throw NoLaunchTargetError(title: game.title)
                }

                // Which runtime this game wants, the container belonging to that runtime,
                // and that game's own settings written into it. Replaces reading
                // `game.containerURL` and hoping: a game with no container used to simply
                // refuse to start, and a game whose container was built by the wrong Wine had
                // no way to say so.
                let plan = try await Provisioner.shared.planLaunch(for: game)
                let containerURL = plan.containerURL

                let process: Process = .init()
                process.arguments = [target.executable.path] + target.arguments + game.launchArguments

                var environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: containerURL,
                                                                      overriding: plan.settings)

                // Wine's default channels print a `fixme` for every Direct3D present — two
                // per frame, each a formatted write to stderr. Blades of Time's first two
                // minutes produced 23,000 of them and 1.4MB of log, and that is time the
                // frame isn't getting. Errors and every other channel are kept; only the
                // per-frame D3D chatter is dropped, because it says the same thing 11,000
                // times and buries the one line that matters.
                environment["WINEDEBUG"] = "fixme-d3d,fixme-d3d9"

                process.environment = environment

                // GOG games routinely load their data by relative path, so starting one from
                // the wrong directory looks like missing assets rather than like a mistake here.
                process.currentDirectoryURL = target.workingDirectory

                Wine.transformProcess(process, containerURL: containerURL)

                // Everything Wine and the game print, kept where it can be read afterwards.
                //
                // Until now a Windows game's entire output went to Mythic's own stderr, which
                // means nowhere unless Mythic happened to be running from Xcode. A game that
                // crashes on someone else's machine left nothing behind to look at, and the
                // reason is almost always in the last few lines Wine printed.
                //
                // A file handle rather than a `Pipe`: the wineserver and every Windows process
                // under it inherit the write end, so a pipe's reader waits for the last of
                // them rather than for the game. See ``Process/runBounded(timeout:)``.
                let logURL = Wine.logURL(forGameTitled: game.title, inContainerAtURL: containerURL)
                let logHandle = Wine.beginLogging(to: logURL,
                                                  describing: target.executable,
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

                // And what reaches the prefix: begun the moment Force Quit is pressed, finished
                // below. Not begun by the handler around the launch itself. A stop that lands
                // there either came first, so Wine was never started and the launch ends by
                // throwing — with nobody left to wait for passes it had begun — or came as Wine
                // started, which kills it on the spot and carries on into the handler that does.
                let forceQuit: Wine.ForceQuit = .init(containerAt: containerURL)

                try await withTaskCancellationHandler {
                    try launch.launch(process)
                } onCancel: {
                    launch.stop()
                }

                // Not a courtesy: Wine's Mac driver won't change the display mode until its
                // process is the active application, so a game left behind the launcher comes
                // up windowed no matter what its settings say.
                //
                // Its own task, and deliberately not awaited — see the same call on the Epic
                // path. It watches for up to a minute, and a launch that waits for it is a
                // launch that reports itself as still starting long after the game is up.
                let executableName = target.executable.lastPathComponent
                let winePID = process.processIdentifier
                let launchedGameID = game.id

                // The plan and the transcript, hoisted for the same reason as the pid: the
                // post-mortem runs after the game exits, and it has to read *this* launch's
                // log against *this* launch's settings.
                let launchedPlan = plan
                let launchedTranscriptURL = logURL

                await withTaskCancellationHandler {
                    // Followed until the game exits, not until this process does: a two-stage
                    // engine hands its window to a second process and the first one returns
                    // straight away. `async let`, so cancelling the launch cancels this too.
                    async let supervised: Void = Wine.superviseGame(named: executableName,
                                                                    startedAs: winePID,
                                                                    hidingLauncher: shouldHideLauncher,
                                                                    forGameWithID: launchedGameID,
                                                                    plan: launchedPlan,
                                                                    transcriptAt: launchedTranscriptURL)

                    await process.waitUntilExitOrCancellation()
                    await supervised
                } onCancel: {
                    // Stopping a game means stopping the prefix it runs in. This process *is*
                    // Wine, but the game is a descendant of it, so killing this one on its own
                    // leaves the game running and the launch looking stuck. Through the launch,
                    // never `terminate()`, which raises on a process that is not running — and
                    // the crash would take the kill below with it.
                    launch.stop()
                    forceQuit.begin()
                }

                // Made certain before the launch is over — see `Wine.forceQuit(containerAt:)`.
                if launch.hasBeenStopped {
                    await forceQuit.finish()
                }

                try? logHandle?.close()

                if shouldHideLauncher {
                    await MainActor.run { NSApp.unhide(nil) }
                }
            }
        }

        Game.operationManager.queueOperation(operation)
        return operation
    }

    // MARK: - Housekeeping

    @discardableResult
    @MainActor static func move(game: GOGGame,
                                to newLocation: URL) async throws -> GameOperation {
        guard case .installed(let currentLocation, let platform) = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let operation: GameOperation = .init(game: game, type: .move) { _ in
            try FileManager.default.moveItem(at: currentLocation, to: newLocation)

            await MainActor.run {
                game.installationState = .installed(location: newLocation, platform: platform)
                GameDataStore.shared.library.update(with: game)
            }
        }

        Game.operationManager.queueOperation(operation)
        return operation
    }

    @discardableResult
    @MainActor static func uninstall(game: GOGGame,
                                     persistFiles: Bool) async throws -> GameOperation {
        guard case .installed(let location, _) = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let operation: GameOperation = .init(game: game, type: .uninstall) { _ in
            if !persistFiles {
                try FileManager.default.removeItem(at: location)
            }

            await MainActor.run {
                // Unlike a local game, this one stays in the library: it's still owned, it's
                // just no longer on disk, and that's exactly what the storefront list is for.
                game.installationState = .uninstalled
                GameDataStore.shared.library.update(with: game)

                GOGDL.forgetInstall(ofGameID: game.id)
            }
        }

        Game.operationManager.queueOperation(operation)
        return operation
    }
}
