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
        var errorDescription: String? { String(localized: "Mythic couldn't work out how to start \(title).") }
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

        defer {
            if UserDefaults.standard.bool(forKey: "minimiseOnGameLaunch") {
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        }

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

                let application = try await NSWorkspace.shared.openApplication(at: location, configuration: configuration)

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
                    application.terminate()
                }

            case .windows:
                // A Windows install is a directory, so what to run has to be read out of the
                // game's own play tasks rather than assumed to be the location itself.
                guard let target = GOGDL.primaryLaunchTarget(forGameAt: location, id: game.id, platform: platform) else {
                    throw NoLaunchTargetError(title: game.title)
                }

                guard let containerURL = game.containerURL else { throw Wine.Container.DoesNotExistError() }
                let container = try Wine.getContainerObject(at: containerURL)

                if UserDefaults.standard.bool(forKey: "minimiseOnGameLaunch") {
                    await MainActor.run { NSApp.windows.first?.miniaturize(nil) }
                }

                let process: Process = .init()
                process.arguments = [target.executable.path] + target.arguments + game.launchArguments
                process.environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: container.url)

                // GOG games routinely load their data by relative path, so starting one from
                // the wrong directory looks like missing assets rather than like a mistake here.
                process.currentDirectoryURL = target.workingDirectory

                Wine.transformProcess(process, containerURL: containerURL)

                try process.run()
                process.waitUntilExit()
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
