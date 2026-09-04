//
//  SteamGame.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 15/11/2025.
//  Steam support implemented by Claude (Cowork) on 4/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/// A game installed through the real Windows Steam client, running inside Mythic's
/// dedicated Steam container. See ``Steam`` for how that container/client is managed.
class SteamGame: Game, @unchecked Sendable {
    override var storefront: Storefront? { .steam }

    /// Prefix that namespaces Steam AppIDs into Mythic's global game-ID space,
    /// so a Steam game and an Epic game can never collide on `id`.
    static let idPrefix: String = "steam_"

    /// Mythic's internal identifier for a given Steam AppID.
    static func id(forAppID appID: String) -> String { idPrefix + appID }

    /// Steam's own numeric identifier for this app.
    ///
    /// Deliberately *derived* from `id` rather than stored alongside it: the two can
    /// then never drift out of sync, and no extra `Codable` plumbing is needed —
    /// which matters here because `Game.encode(to:)` is declared in an extension and
    /// therefore cannot be overridden by a subclass.
    var appID: String {
        id.hasPrefix(Self.idPrefix) ? String(id.dropFirst(Self.idPrefix.count)) : id
    }

    override var computedVerticalImageURL: URL? { Steam.artworkURL(appID: appID, kind: .library600x900) }
    override var computedHorizontalImageURL: URL? { Steam.artworkURL(appID: appID, kind: .libraryHero) }

    convenience init(appID: String,
                     title: String,
                     installationState: InstallationState,
                     containerURL: URL? = nil) {
        self.init(id: Self.id(forAppID: appID),
                  title: title,
                  installationState: installationState,
                  containerURL: containerURL)
    }

    override init(id: String,
                  title: String,
                  installationState: InstallationState,
                  containerURL: URL? = nil) {
        super.init(id: id,
                   title: title,
                   installationState: installationState,
                   containerURL: containerURL)
    }

    required init(from decoder: any Decoder) throws {
        // super.init(from:) handles all decoding; `appID` is derived from `id`,
        // so there's nothing Steam-specific left to decode.
        try super.init(from: decoder)
    }

    override func _checkIfGameIsRunning(location: URL, platform: Platform) -> Bool {
        // swiftlint:disable:previous identifier_name
        // Steam games are launched *through* steam.exe, so the running process isn't at
        // `location` — it's whatever executable Steam itself launched inside the prefix.
        // `Wine.tasklist(for:)` could tell us, but it's async and this override's
        // signature (inherited from `Game`) is synchronous — same constraint
        // `EpicGamesGame` hit for its own Windows-platform case. FIXME: stub, same as
        // EpicGamesGame's; revisit if/when `_checkIfGameIsRunning` becomes async.
        return false
    }

    nonisolated override func _launch() async throws {
        try await SteamGameManager.launch(game: self)
    }

    nonisolated override func _update() async throws {
        // Steam updates its own games automatically/on next launch — there's nothing
        // separate for Mythic to trigger, so this is intentionally a no-op rather than
        // a fabricated update flow.
    }

    nonisolated override func _move(from currentLocation: URL,
                                    to newLocation: URL) async throws {
        try await SteamGameManager.move(game: self, to: newLocation)
    }

    nonisolated override func _verifyInstallation() async throws {
        throw SteamGameManager.UnsupportedOperationError(
            reason: String(localized: "To verify a Steam game's files, right-click it in the real Steam client and choose Properties > Installed Files > Verify integrity of game files.")
        )
    }
}
