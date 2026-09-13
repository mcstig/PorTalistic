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

extension GOGGameManager: GameManager {
    @MainActor static func launch(game: Game) async throws -> GameOperation {
        guard case .gog = game.storefront,
              let castGame = game as? GOGGame else { throw CocoaError(.coderInvalidValue) }

        return try await launch(game: castGame)
    }

    @MainActor static func move(game: Game,
                                to newLocation: URL) async throws -> GameOperation {
        guard case .gog = game.storefront,
              let castGame = game as? GOGGame else { throw CocoaError(.coderInvalidValue) }

        return try await move(game: castGame, to: newLocation)
    }

    @MainActor static func uninstall(game: Game,
                                     persistFiles: Bool) async throws -> GameOperation {
        guard case .gog = game.storefront,
              let castGame = game as? GOGGame else { throw CocoaError(.coderInvalidValue) }

        return try await uninstall(game: castGame, persistFiles: persistFiles)
    }
}

/// Running the GOG games that are already on disk.
///
/// There is no GOG equivalent of `legendary` here, and for launching there doesn't need to
/// be: a DRM-free game is an executable in a folder, so this ends up close to
/// ``LocalGameManager`` — which is the honest shape of the problem rather than a shortcut.
/// Installing is the part that needs machinery, and it isn't written yet.
class GOGGameManager {
    static var log: Logger { .custom(category: "GOGGameManager") }

    /// Thrown by the operations that need GOG's content system, which Mythic can't speak yet.
    struct InstallationUnsupportedError: LocalizedError {
        var errorDescription: String? {
            String(localized: "Mythic can't download GOG games yet.")
        }
        var recoverySuggestion: String? {
            String(localized: """
                Install the game with GOG Galaxy or from an offline installer, then add it from \
                Import Game › Local. Downloading from GOG directly is coming.
                """)
        }
    }

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
                guard let containerURL = game.containerURL else { throw Wine.Container.DoesNotExistError() }
                let container = try Wine.getContainerObject(at: containerURL)

                if UserDefaults.standard.bool(forKey: "minimiseOnGameLaunch") {
                    NSApp.windows.first?.miniaturize(nil)
                }

                let process: Process = .init()
                process.arguments = [location.path] + game.launchArguments
                process.environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: container.url)
                Wine.transformProcess(process, containerURL: containerURL)

                try process.run()
                process.waitUntilExit()
            }
        }

        Game.operationManager.queueOperation(operation)
        return operation
    }

    @discardableResult
    @MainActor static func move(game: GOGGame,
                                to newLocation: URL) async throws -> GameOperation {
        guard case .installed(let currentLocation, let platform) = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let operation: GameOperation = .init(game: game, type: .uninstall) { _ in
            try FileManager.default.moveItem(at: currentLocation, to: newLocation)
            game.installationState = .installed(location: newLocation, platform: platform)
        }
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

            // Unlike a local game, this one stays in the library: it's still owned, it's just
            // no longer on disk, and that's exactly what the storefront list is for.
            game.installationState = .uninstalled
        }
        return operation
    }
}
