//
//  WhatsNewCollection.swift
//  PorTalistic
//
//  Created by vapidinfinity (esi) on 1/11/2024.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import WhatsNewKit
import SwiftUI

/**
 What each release of this application changed.

 This replaced upstream Mythic's collection rather than extending it. Eight entries described
 Mythic's 0.4.1 through 0.6.0 releases in its maintainer's own voice — quotes attributed to
 him, a prompt to donate to his project — and that sheet came up on every launch of *this*
 application. Keeping it would have been putting words in someone else's mouth and asking for
 money on their behalf.

 - Note: One entry per released version. The `version` is what `WhatsNewKit` records as seen,
   so a new one only appears when its version ships.
 */
extension PorTalisticApp: @MainActor WhatsNewCollectionProvider {
    var whatsNewCollection: WhatsNewCollection {
        WhatsNew(
            version: "0.6.0",
            title: "What's new in PorTalistic",
            features: [
                .init(
                    image: .init(
                        systemName: "wand.and.sparkles",
                        foregroundColor: .purple
                    ),
                    title: "Games choose their own setup",
                    subtitle: """
                        PorTalistic reads a game's own files to work out how it renders, then \
                        picks the Wine build and graphics layer that suit it. Each game's \
                        settings are applied when it launches and put back afterwards.
                        """
                ),
                .init(
                    image: .init(
                        systemName: "arrow.down.circle",
                        foregroundColor: .blue
                    ),
                    title: "Nothing to install by hand",
                    subtitle: """
                        Wine builds and graphics layers are fetched and kept current in the \
                        background, and only the ones your installed games actually need.
                        """
                ),
                .init(
                    image: .init(
                        systemName: "building.columns",
                        foregroundColor: .indigo
                    ),
                    title: "GOG support",
                    subtitle: """
                        Sign in, download, install and play GOG games, with cover art from \
                        GOG's own database.
                        """
                ),
                .init(
                    image: .init(
                        systemName: "square.stack.3d.up.slash",
                        foregroundColor: .orange
                    ),
                    title: "A library of games, not entitlements",
                    subtitle: """
                        Epic lists DLC and bonus content alongside games. Those no longer \
                        appear as duplicates of the games they belong to.
                        """
                ),
                .init(
                    image: .init(
                        systemName: "arrow.triangle.branch",
                        foregroundColor: .secondary
                    ),
                    title: "Built on Mythic",
                    subtitle: """
                        PorTalistic is a fork of Mythic by vapidinfinity, under the GPLv3. \
                        Your games, containers and sign-ins were carried over from it.
                        """
                )
            ]
        )
    }
}

#Preview {
    WhatsNewView(whatsNew: PorTalisticApp().whatsNewCollection.last ?? WhatsNew(title: "N/A", features: []))
}
