//
//  GameImageCard.swift
//  PorTalistic
//
//  Created by vapidinfinity (esi) on 1/12/2025.
//  Reduced to a shim by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import Foundation
import SwiftUI

/**
 ``GameArtwork``, under the name eight sheets already call it by.

 This used to be the app's only image view, and it drew a missing cover as flat `.quinary`
 behind a shimmer and a failed one as a full `ContentUnavailableView` — a title, a body and
 a button — inside whatever space a card had. It also loaded through `AsyncImage`, which
 keeps nothing between appearances.

 Rather than change every installation sheet, import sheet and settings sheet that asks for
 it, this forwards to ``GameArtwork``: the coloured placeholder, the in-memory cache and the
 single border all arrive at those call sites for free. New code should use ``GameArtwork``
 directly.

 - Note: `isImageEmpty` is reported as before, so callers that lay something else out when a
   game has no art keep working.
 */
struct GameImageCard: View {
    var game: Game?
    var url: URL?
    @Binding var isImageEmpty: Bool

    /// Accepted and ignored. It existed to draw a blurred copy of the image behind itself so
    /// a letterboxed cover had something in the margins; artwork now fills its tile and is
    /// clipped, so there are no margins to fill.
    var withBlur: Bool

    init(game: Game? = nil, url: URL?, isImageEmpty: Binding<Bool>, withBlur: Bool = true) {
        self.game = game
        self.url = url
        self._isImageEmpty = isImageEmpty
        self.withBlur = withBlur
    }

    var body: some View {
        GameArtwork(
            game: game,
            url: url,
            cornerRadius: Theme.Radius.panel,
            isArtworkPresent: .init(get: { !isImageEmpty },
                                    set: { isImageEmpty = !$0 })
        )
    }
}

extension GameImageCard {
    /// The placeholder on its own, for callers that want it beside a title rather than behind one.
    struct FallbackGameImageCard: View {
        @Binding var game: Game
        var withBlur: Bool = true

        var body: some View {
            ArtworkPlaceholder(game: game)
                .clipShape(.rect(cornerRadius: Theme.Radius.tile, style: .continuous))
        }
    }
}

#Preview {
    HStack {
        GameImageCard(game: placeholderGame(type: LocalGame.self) as Game,
                      url: placeholderGame(type: LocalGame.self).horizontalImageURL,
                      isImageEmpty: .constant(false))
        .aspectRatio(16/9, contentMode: .fill)

        GameImageCard(game: placeholderGame(type: Game.self),
                      url: placeholderGame(type: Game.self).verticalImageURL,
                      isImageEmpty: .constant(false))
        .aspectRatio(3/4, contentMode: .fill)
    }
    .aspectRatio(contentMode: .fit)
    .padding()
}
