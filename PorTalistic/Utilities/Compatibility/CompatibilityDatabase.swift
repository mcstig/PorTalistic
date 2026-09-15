//
//  CompatibilityDatabase.swift
//  Mythic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 What is known about specific games, beyond what their binaries admit.

 Reading an executable answers "32-bit Direct3D 9" well and answers "this one's networking
 falls over on Wine 7.7" not at all. That second kind of fact only ever comes from running the
 game, so it has to be written down somewhere — which is what this is.

 Two rules about what goes in here, both learned the hard way:

 - **Only what has been observed.** A guessed entry is worse than no entry, because an absent
   entry falls back to inspection — which is usually right — while a wrong entry overrides it.
 - **Say why.** "Retina Mode off" is meaningless in six months. "Off, because on it renders a
   quarter of the screen" is still actionable, and is what the game's settings can show.

 - Note: The intent is for this to be fetched from the public repository and verified by
   digest, so a game can be fixed for everyone without shipping an app update. The compiled-in
   seed below is then the offline fallback. Until that lands, the seed *is* the database.
 */
struct CompatibilityDatabase: Codable, Hashable {
    static let log: Logger = .custom(category: "CompatibilityDatabase")

    var entries: [Entry]

    struct Entry: Codable, Hashable {
        /// Storefront-qualified game ids this applies to. Exact, and the preferred way in.
        var identifiers: [Identifier] = []

        /// Titles this applies to, for the same game on a storefront whose id we don't have.
        /// Matched after normalisation, so punctuation and trademark symbols don't matter.
        var titles: [String] = []

        /// Override the translation layer the binary implies.
        var graphicsBackend: RuntimeProfile.GraphicsBackend?

        /// The game needs a Wine with a working socket layer, which the bundled 7.7 engine
        /// does not have. Not inferable from the executable — every game imports `ws2_32` —
        /// so it can only be recorded here.
        var requiresModernNetworking: Bool?

        var settings: RuntimeProfile.SettingsOverride = .init()

        /// Why this entry exists, shown to the user as the reason for the choice.
        var note: String?

        struct Identifier: Codable, Hashable {
            let storefront: Game.Storefront
            let id: String
        }
    }

    // MARK: - Lookup

    /// The entry for a game, by id first and title second.
    ///
    /// Takes plain values rather than a `Game` so it can be called from wherever the work is
    /// happening: `Game` is a main-actor-bound reference type, and profile resolution reads
    /// executables off disk, which has no business on the main actor.
    func entry(storefront: Game.Storefront?, id: String, title: String) -> Entry? {
        if let storefront, let byIdentifier = entries.first(where: { entry in
            entry.identifiers.contains { $0.storefront == storefront && $0.id == id }
        }) {
            return byIdentifier
        }

        let normalised = Self.normalise(title)
        guard !normalised.isEmpty else { return nil }

        return entries.first { entry in
            entry.titles.contains { Self.normalise($0) == normalised }
        }
    }

    @MainActor
    func entry(for game: Game) -> Entry? {
        entry(storefront: game.storefront, id: game.id, title: game.title)
    }

    /// Titles arrive decorated differently from every storefront — "Fallout New Vegas®",
    /// "Sid Meier's Civilization® VI", "PREY" — so matching is on letters and digits only.
    static func normalise(_ title: String) -> String {
        title.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    // MARK: - Contents

    /// The database in force.
    ///
    /// A stored property rather than a computed one so a fetched database can replace it, and
    /// `nonisolated(unsafe)` for the same reason the runtime discovery cache is: written once
    /// during provisioning, read from wherever a game is about to launch.
    nonisolated(unsafe) static var current: CompatibilityDatabase = .seed

    /// What has actually been observed on a real machine, with the observation attached.
    ///
    /// Short on purpose. Every line here is something a game did, not something a game is
    /// expected to do.
    static let seed: CompatibilityDatabase = .init(entries: [
        .init(
            identifiers: [.init(storefront: .gog, id: "1158493447")],
            titles: ["Prey"],
            settings: .init(retinaMode: false),
            note: """
                Retina Mode off: with it on, Prey's 2048×1330 fullscreen is rendered into a \
                quarter of a 4096×2660 desktop and every display gets captured.
                """
        ),
        .init(
            identifiers: [.init(storefront: .gog, id: "1164193173")],
            titles: ["Blades of Time"],
            note: """
                On wined3d, Retina Mode off sent this down the fullscreen path — different \
                code from the windowed one — where it crashed with a stack overflow on the \
                render thread. That was wined3d; it runs on DXMT now, so the entry no longer \
                forces Retina Mode on and it follows the default with everything else. If \
                that crash comes back, turning Retina Mode on for this game is the fix.
                """
        )
    ])
}
