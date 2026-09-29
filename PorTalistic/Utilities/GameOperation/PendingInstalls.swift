//
//  PendingInstalls.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import Foundation
import OSLog

/**
 Installs that were interrupted, so the next launch can pick them up.

 An install is a child process — `legendary` or `gogdl` — and quitting used to leave it
 running, orphaned: the download carried on with nothing left to report it, finished at some
 point, and the game simply appeared as installed. Reopening the app showed a game that was
 not installed and not installing either, which is the same picture as a download that failed.

 Quitting now stops the download (see ``GameOperationManager/stopFileOperationsForQuit()``;
 both tools save what they have and resume from it), and this is what is left behind: what was
 being installed, and with what, so it can be started again and *seen* to be running.

 - Note: Deliberately only installs. An interrupted update or repair leaves the game playable
   as it was, so restarting one without being asked is work nobody requested.
 */
@MainActor
enum PendingInstalls {
    private static let key: String = "pendingInstalls"
    private static let log: Logger = .custom(category: "PendingInstalls")

    /// What an install needs to be started again exactly as it was asked for.
    struct Record: Codable, Equatable, Sendable, Identifiable {
        let gameID: String
        let storefront: Game.Storefront
        let platform: Game.Platform
        /// Where the game was being installed to. `nil` means the default at the time.
        let baseDirectory: URL?
        /// Epic's optional packs (language packs, high-res textures) as they were chosen.
        let optionalPackIDs: [String]
        let queuedAt: Date

        var id: String { gameID }

        init(gameID: String,
             storefront: Game.Storefront,
             platform: Game.Platform,
             baseDirectory: URL?,
             optionalPackIDs: [String] = .init(),
             queuedAt: Date = .now) {
            self.gameID = gameID
            self.storefront = storefront
            self.platform = platform
            self.baseDirectory = baseDirectory
            self.optionalPackIDs = optionalPackIDs
            self.queuedAt = queuedAt
        }
    }

    static var all: [Record] {
        (try? UserDefaults.standard.decodeAndGet([Record].self, forKey: key)) ?? .init()
    }

    /// Note that a game is being installed. Replaces any earlier note for the same game.
    static func remember(_ record: Record) {
        var records = all.filter { $0.gameID != record.gameID }
        records.append(record)
        save(records)
    }

    static func forget(gameID: String) {
        let records = all.filter { $0.gameID != gameID }
        guard records.count != all.count else { return }
        save(records)
    }

    private static func save(_ records: [Record]) {
        do {
            _ = try UserDefaults.standard.encodeAndSet(records, forKey: key)
        } catch {
            log.error("Couldn't write the list of interrupted installs: \(error.localizedDescription)")
        }
    }

    // MARK: - Resuming

    /// Start every interrupted install again, so it is both running and visible.
    ///
    /// Called once the library is loaded, because an install is queued against a game object
    /// and there are none before then. Safe to call twice: a game that already has an
    /// operation is left alone.
    static func resumeInterrupted() async {
        let records = all
        guard !records.isEmpty else { return }

        for record in records {
            let game = GameDataStore.shared.library.first { $0.id == record.gameID }

            switch decision(gameIsInLibrary: game != nil,
                            gameIsInstalled: game?.isInstalled == true,
                            gameHasAnOperation: game.map { GameOperationManager.shared.operation(for: $0) != nil } == true) {
            case .forget:
                forget(gameID: record.gameID)
                continue
            case .wait:
                continue
            case .resume:
                break
            }

            guard let game else { continue }

            do {
                guard try await resume(game, record: record) else { continue }
                log.notice("Picked \(game.title, privacy: .public)'s install back up where it left off")
            } catch {
                // Kept, not forgotten: a storefront that can't be reached now is one that may
                // answer on the next launch, and the partial download is still on disk.
                log.error("Couldn't resume \(game.title, privacy: .public)'s install: \(error.localizedDescription)")
            }
        }
    }

    /// What to do with a note now that the app is open again.
    ///
    /// Pure, and separate from the loop below, so the rules can be tested without a library, a
    /// storefront or the network — none of which a test may reach.
    ///
    /// - Parameters:
    ///   - gameIsInLibrary: a game that has gone — removed from the storefront, or the account
    ///     signed out — has nothing left to install.
    ///   - gameIsInstalled: it finished anyway. A download orphaned by an older build, or files
    ///     that were already there.
    ///   - gameHasAnOperation: something is already working on it, so this would be a second
    ///     copy of the same download writing to the same files.
    nonisolated static func decision(gameIsInLibrary: Bool, gameIsInstalled: Bool, gameHasAnOperation: Bool) -> Decision {
        guard gameIsInLibrary, !gameIsInstalled else { return .forget }
        guard !gameHasAnOperation else { return .wait }
        return .resume
    }

    enum Decision: Equatable, Sendable {
        /// Start the install again, where it left off.
        case resume
        /// Drop the note.
        case forget
        /// Leave it for now; it is neither finished nor abandoned.
        case wait
    }

    /// - Returns: whether an install was actually started.
    ///
    /// A record that can never be acted on is forgotten rather than kept: keeping it would
    /// have it retried on every launch, for ever, with nothing to show for it.
    @discardableResult
    private static func resume(_ game: Game, record: Record) async throws -> Bool {
        switch record.storefront {
        case .epicGames:
            guard let game = game as? EpicGamesGame else {
                log.warning("\(record.gameID, privacy: .public) is noted as an Epic install but isn't an Epic game; dropping the note")
                forget(gameID: record.gameID)
                return false
            }

            // `isAutomatic`: nobody asked for this one, so a failure is logged rather than put
            // in front of somebody who has just opened the app.
            _ = try await Legendary.install(game: game,
                                            forPlatform: record.platform,
                                            qualityOfService: .utility,
                                            optionalPackIDs: record.optionalPackIDs,
                                            baseDirectoryURL: record.baseDirectory,
                                            isAutomatic: true)
        case .gog:
            guard let game = game as? GOGGame else {
                log.warning("\(record.gameID, privacy: .public) is noted as a GOG install but isn't a GOG game; dropping the note")
                forget(gameID: record.gameID)
                return false
            }

            _ = try await GOGDL.install(game: game,
                                        platform: record.platform,
                                        qualityOfService: .utility,
                                        baseDirectoryURL: record.baseDirectory,
                                        isAutomatic: true)
        case .steam, .local:
            // Neither downloads through this app: a local game is imported from a folder, and
            // Steam's own client owns its downloads.
            forget(gameID: record.gameID)
            return false
        }

        return true
    }
}
