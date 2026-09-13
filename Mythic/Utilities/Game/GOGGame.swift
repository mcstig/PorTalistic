//
//  GOGGame.swift
//  Mythic
//
//  Created by Claude (Cowork) on 13/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import AppKit

/// A game on a GOG account.
///
/// Thinner than its Epic counterpart on purpose. GOG games are DRM-free: nothing has to be
/// running for one to start, nothing authorises a launch, and there is no client to ask
/// whether an update exists — so the questions `EpicGamesGame` forwards to `legendary` either
/// don't apply here or are answered by looking at the disk.
///
/// Everything GOG-specific is looked up by id rather than stored on the instance, because a
/// `Game` subclass can't add to what gets persisted: `Game.encode(to:)` is declared in an
/// extension and so can't be overridden. ``SteamGame`` solves the same problem by deriving
/// its AppID from `id`; artwork and platforms can't be derived, so they come from the
/// product cache ``GOG`` writes whenever it fetches the library — the same shape as
/// legendary's on-disk metadata.
class GOGGame: Game, @unchecked Sendable {
    override var storefront: Storefront? { .gog }

    override var computedVerticalImageURL: URL? { GOG.imageURL(forProductID: id, variant: .vertical) }
    override var computedHorizontalImageURL: URL? { GOG.imageURL(forProductID: id, variant: .horizontal) }

    /// What GOG ships builds for — not what Mythic can run, which is the whole point of a
    /// container. `nil` means the library hasn't been fetched yet rather than "none".
    override func getSupportedPlatforms() -> Set<Game.Platform>? {
        guard let cached = GOG.cachedProduct(id: id) else { return nil }

        var platforms: Set<Game.Platform> = .init()
        if cached.windows { platforms.insert(.windows) }
        if cached.mac { platforms.insert(.macOS) }

        return platforms.isEmpty ? nil : platforms
    }

    convenience init(product: GOG.Product) {
        self.init(id: String(product.id),
                  title: product.title,
                  installationState: .uninstalled)
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
        // super.init(from:) handles all decoding; everything GOG-specific is looked up from
        // the product cache by id, so there's nothing left here to decode.
        try super.init(from: decoder)
    }

    override func _checkIfGameIsRunning(location: URL, platform: Platform) -> Bool {
        // swiftlint:disable:previous identifier_name
        switch platform {
        case .macOS: NSWorkspace.shared.runningApplications.contains { $0.bundleURL == location }
        case .windows: false // as with Epic — wants a tasklist read, and this override is synchronous
        }
    }

    nonisolated override func _launch() async throws {
        try await GOGGameManager.launch(game: self)
    }

    nonisolated override func _update() async throws {
        throw GOGGameManager.InstallationUnsupportedError()
    }

    nonisolated override func _move(from currentLocation: URL,
                                    to newLocation: URL) async throws {
        try await GOGGameManager.move(game: self, to: newLocation)
    }

    nonisolated override func _verifyInstallation() async throws {
        throw GOGGameManager.InstallationUnsupportedError()
    }
}
