//
//  SteamGameManager.swift
//  Mythic
//
//  Created by Claude (Cowork) on 4/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import AppKit
import OSLog

extension SteamGameManager: GameManager {
    @MainActor static func launch(game: Game) async throws -> GameOperation {
        guard case .steam = game.storefront,
              let castGame = game as? SteamGame else { throw CocoaError(.coderInvalidValue) }

        return try await launch(game: castGame)
    }

    @MainActor static func move(game: Game, to newLocation: URL) async throws -> GameOperation {
        guard case .steam = game.storefront,
              let castGame = game as? SteamGame else { throw CocoaError(.coderInvalidValue) }

        return try await move(game: castGame, to: newLocation)
    }

    @MainActor static func uninstall(game: Game, persistFiles: Bool) async throws -> GameOperation {
        guard case .steam = game.storefront,
              let castGame = game as? SteamGame else { throw CocoaError(.coderInvalidValue) }

        return try await uninstall(game: castGame, persistFiles: persistFiles)
    }
}

/// Runs Steam games by handing off to the real Windows Steam client installed in
/// Mythic's dedicated container — see ``Steam`` for the container/client management side.
final class SteamGameManager {
    static var log: Logger { .custom(category: "SteamGameManager") }

    struct UnsupportedOperationError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    @discardableResult
    @MainActor static func launch(game: SteamGame) async throws -> GameOperation {
        guard let containerURL = game.containerURL else { throw Wine.Container.DoesNotExistError() }

        let operation: GameOperation = .init(game: game, type: .launch) { _ in
            // Fail fast with a specific reason rather than a silent no-op or a
            // process that dies instantly inside Wine with no visible explanation.
            try await Preflight.requireReadyToLaunch(containerURL: containerURL)
            guard Steam.isClientInstalled else { throw Steam.NotInstalledError() }

            if UserDefaults.standard.bool(forKey: "minimiseOnGameLaunch") {
                NSApp.windows.first?.miniaturize(nil)
            }

            let process: Process = .init()
            // `-applaunch <appid>` is the same mechanism Steam's own desktop/Big Picture
            // shortcuts use — Steam resolves the appid to its installed executable,
            // working directory, and any launch options the game/depot specifies,
            // so Mythic never needs to know the game's actual exe path.
            process.arguments = [Steam.steamExecutableURL(containerURL: containerURL).path,
                                 "-applaunch", game.appID] + game.launchArguments
            process.environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: containerURL)
            Wine.transformProcess(process, containerURL: containerURL)

            try process.run()
            process.waitUntilExit()
        }

        Game.operationManager.queueOperation(operation)
        return operation
    }

    @discardableResult
    @MainActor static func move(game: SteamGame, to newLocation: URL) async throws -> GameOperation {
        throw UnsupportedOperationError(
            reason: String(localized: "Moving a Steam game's install location must be done from within the Steam client (Steam > Storage Manager), since Steam tracks the path itself.")
        )
    }

    @discardableResult
    @MainActor static func uninstall(game: SteamGame, persistFiles: Bool) async throws -> GameOperation {
        // Deleting a Steam game's files ourselves risks corrupting Steam's own
        // installation bookkeeping (its depot/manifest cache). The safe operation
        // Mythic can perform unilaterally is removing the game from *Mythic's*
        // library — actual uninstallation happens through the real Steam client,
        // same as `_move`/`_verifyInstallation` above.
        let operation: GameOperation = .init(game: game, type: .uninstall) { _ in
            await MainActor.run {
                _ = GameDataStore.shared.library.remove(game)
            }
        }

        Game.operationManager.queueOperation(operation)
        return operation
    }
}
