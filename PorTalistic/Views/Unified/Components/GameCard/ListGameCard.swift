//
//  ListGameCard.swift
//  PorTalistic
//
//  Created by vapidinfinity (esi) on 10/20/24.
//  Rebuilt by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI

/**
 One game as a row.

 Mythic's rows drew the game's art full-bleed behind the text, which looked good, and paid
 for it three ways: a 30-point blur on every visible row, a height that doubled on hover — so
 moving the pointer down a list made every row below it jump, twice — and text that flipped
 between primary and white depending on whether the image had finished loading.

 The look is worth keeping; those three things are not. So the art bleeds in from the left
 behind the text, faded out by a gradient mask well before it reaches the title: no blur, no
 second image (the mask and the thumbnail draw the same cached picture), no movement, and
 text that is one colour because the art never gets near it. Hover brightens the wash and
 fills the row's surface, and nothing changes size.

 The thumbnail is 16:9 and prefers the game's landscape art, which is the other half of why
 the old row looked better than the rebuilt one: a 44-point portrait frame was cropping the
 sides off box art that is mostly landscape, so a list of games was a list of centre strips.
 */
struct ListGameCard: View {
    /// The game, not a binding to it — see ``GameCard/game``. A view holding a `Binding`
    /// cannot be skipped, so every row re-ran its body on every scroll tick.
    let game: Game

    /// For the children that still take a `Binding<Game>`. `Game` is a class, so this
    /// writes to the same object.
    private var boundGame: Binding<Game> { .constant(game) }

    /// Which row the pointer is over, shared with the rest of the list — see ``CardHoverState``.
    ///
    /// Rows used to keep a flag each. `.onHover` fires as rows slide under a pointer that is
    /// standing still, so every scroll started and stopped a hover animation on each row it
    /// passed — redrawing its wash mid-scroll — and a row that scrolled out from under the
    /// pointer could keep its hover for good. The grid already had the answer to both.
    let hover: CardHoverState

    @State private var isSettingsPresented: Bool = false
    @State private var isUninstallPresented: Bool = false

    static let defaultHeight: CGFloat = 76

    /// The art this row draws, in both places it draws it.
    ///
    /// Landscape first: a row is a wide shape and most storefront box art is wide. One URL
    /// for the thumbnail *and* the backdrop on purpose — they then share a single cached,
    /// decoded image, so the wash costs a second draw rather than a second download.
    private var artworkURL: URL? { game.horizontalImageURL ?? game.verticalImageURL }

    private var shape: RoundedRectangle { .init(cornerRadius: Theme.Radius.tile, style: .continuous) }

    private var isHovering: Bool { hover.gameID == game.id }

    /// Greyed out: not installed, and not the row the pointer is on.
    private var isMuted: Bool { !game.isInstalled && !isHovering }

    var body: some View {
#if DEBUG
        RenderCounter.record("ListGameCard")
#endif
        return HStack(spacing: Theme.Spacing.large) {
            NavigationLink(value: GameRoute(gameID: game.id)) {
                HStack(spacing: Theme.Spacing.large) {
                    GameArtwork(game: game,
                                url: artworkURL,
                                orientation: .horizontal,
                                cornerRadius: Theme.Radius.control,
                                isMuted: isMuted)
                        .frame(width: 100, height: 56)

                    VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                        Text(game.title)
                            .font(Theme.Text.rowTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(isMuted ? Color.secondary : Color.primary)

                        HStack(spacing: Theme.Spacing.xsmall) {
                            GameCard.SubscriptedInfoView(game: boundGame)

                            if case .uninstalled = game.installationState {
                                PortalBadge(String(localized: "Not installed"))
                            }
                        }
                    }

                    Spacer(minLength: Theme.Spacing.medium)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            // In its own view, so a progress tick invalidates the trailing control and not
            // the whole row with its artwork. This row used to hold the operation manager
            // itself, which meant one download redrew every row in the list several times a
            // second.
            TrailingControl(game: boundGame, isHovering: isHovering)

            GameCard.MenuView(game: boundGame,
                              isSettingsPresented: $isSettingsPresented,
                              isUninstallPresented: $isUninstallPresented)
                .buttonStyle(.portalQuietCompact)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .frame(height: Self.defaultHeight)
        .background {
            // Flattened into one picture, clip and all — the surface, the wash and its mask. The
            // mask and the rounded clip around two layers were each a pass of their own, for
            // every visible row, on every frame of a scroll, for a background that had not
            // changed; now a scroll only moves it, and only a hover redraws it.
            ZStack {
                shape.fill(isHovering ? AnyShapeStyle(Theme.Palette.surface) : AnyShapeStyle(Color.clear))

                // The same picture as the thumbnail, bled across the row and faded out by a
                // gradient mask before it reaches the title. A mask rather than the old blur:
                // it is one compositing pass instead of a 30-point Gaussian per visible row,
                // and it keeps the text on a flat background, which is what lets the title be
                // one colour rather than changing when the image arrives.
                GameArtwork(game: game, url: artworkURL, orientation: .horizontal, cornerRadius: 0, isMuted: isMuted)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(isHovering ? 0.34 : 0.20), location: 0),
                                .init(color: .black.opacity(isHovering ? 0.10 : 0.05), location: 0.35),
                                .init(color: .clear, location: 0.62)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .drawingGroup()
        }
        .contentShape(.rect(cornerRadius: Theme.Radius.tile))
        .onHover { hovering in
            // Not mid-scroll — see `CardHoverState.isScrolling`. Read here rather than in the
            // body, so it registers no dependency.
            guard !hover.isScrolling else { return }

            withAnimation(Theme.Motion.hover) { hover.pointer(isOver: hovering, gameID: game.id) }
        }
        .contextMenu {
            GameCard.ContextMenuItems(game: boundGame,
                                      isSettingsPresented: $isSettingsPresented,
                                      isUninstallPresented: $isUninstallPresented)
        }
        .gameSettingsSheet(game: boundGame, isPresented: $isSettingsPresented)
        .gameUninstallSheet(game: boundGame, isPresented: $isUninstallPresented)
    }
}

extension ListGameCard {
    /// The running operation's progress, or the action button when nothing is running.
    struct TrailingControl: View {
        @Binding var game: Game
        var isHovering: Bool

        @Bindable private var operationManager: GameOperationManager = .shared

        var body: some View {
            if let operation = operationManager.operation(for: game) {
                OperationCard.StatusView(operation: .constant(operation))
                    .frame(maxWidth: 220, alignment: .trailing)
            } else {
                // The same icon as a card's and the game page's, rather than a labelled
                // pill — one primary action with one appearance wherever it is found.
                GameCard.ActionIconButton(game: $game)
            }
        }
    }
}

#Preview {
    NavigationStack {
        LazyVStack(spacing: Theme.Spacing.small) {
            ForEach(0..<4, id: \.self) { _ in
                ListGameCard(game: placeholderGame(type: Game.self), hover: .init())
            }
        }
        .padding()
    }
    .environmentObject(NetworkMonitor.shared)
    .frame(width: 720, height: 380)
}
