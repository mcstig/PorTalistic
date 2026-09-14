//
//  GameCard.swift
//  PorTalistic
//
//  Created by vapidinfinity (esi) on 5/3/2024.
//  Rebuilt by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI

/**
 One game in a grid or on a shelf.

 The previous card put the title, the storefront badge and every button *inside* the
 artwork, in a single row across the bottom. At the 200-point width the grid actually uses,
 that left about eight characters for the name — "BioSho…", "Blades…", "Horizo…" — and the
 row's height changed with the game's state, because an installed game has a Play button and
 a menu where an uninstalled one has neither. Rows of cards were visibly different heights.
 Text laid over artwork also had to be white, but only once the image had loaded, which is
 the entire reason for the `isImageEmpty` / `isImageEmptyPreMacOSTahoe` pair of flags and the
 flicker they caused.

 So: artwork is artwork, and the name lives under it, on the window, at full width and two
 lines deep with the space reserved whether it needs it or not — which is what keeps a grid
 aligned. Controls appear over the art on hover, where they cost nothing when you aren't
 reaching for them, and the menu stays in the caption row where the pointer can always find
 it. Clicking the card opens the game.
 */
struct GameCard: View {
    @Binding var game: Game

    /// Shown on shelves, where the row itself already says what these games have in common.
    var isCompact: Bool = false

    /// Which card in the enclosing grid or shelf the pointer is over, owned by that grid.
    ///
    /// Not `@State` on the card, because `.onHover` in a lazy grid does not reliably deliver
    /// the *exit* event: a card that scrolls out from under a stationary pointer, or is
    /// re-laid-out beneath one, keeps its hover state forever — which showed up as a random
    /// card in the library sitting there with its Play button and star revealed while the
    /// pointer was in the sidebar. One identifier for the whole grid can only ever name one
    /// card, and the grid clears it when the pointer leaves.
    @Binding var hoveredGameID: Game.ID?

    @State private var isSettingsPresented: Bool = false
    @State private var isUninstallPresented: Bool = false
    @Bindable private var operationManager: GameOperationManager = .shared

    /// Settings ▸ View calls this "Gamecard Glow". It used to draw a blurred copy of the
    /// artwork *behind the image itself*, to fill the margins of a letterboxed cover — so
    /// with artwork now filling its tile it had quietly stopped doing anything at all. A
    /// glow is what the label says, so a glow is what it does: the cover art bled out past
    /// the edges of its own tile. Nothing at all at the default of 0.
    @AppStorage("gameImageCardBlur") private var glowRadius: Double = 0

    private var operation: GameOperation? {
        operationManager.queue.first { $0.game == game && ($0.isExecuting || $0.type.modifiesFiles) }
    }

    private var isHovering: Bool { hoveredGameID == game.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            artwork
            caption
        }
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) {
                if hovering {
                    hoveredGameID = game.id
                } else if hoveredGameID == game.id {
                    hoveredGameID = nil
                }
            }
        }
        .contextMenu {
            GameCard.ContextMenuItems(game: $game,
                                      isSettingsPresented: $isSettingsPresented,
                                      isUninstallPresented: $isUninstallPresented)
        }
        .gameSettingsSheet(game: $game, isPresented: $isSettingsPresented)
        .gameUninstallSheet(game: $game, isPresented: $isUninstallPresented)
    }

    // MARK: Artwork

    private var artwork: some View {
        ZStack {
            NavigationLink(value: GameRoute(gameID: game.id)) {
                GameArtwork(game: game, url: game.verticalImageURL, orientation: .vertical)
                    .aspectRatio(Theme.Grid.artworkAspectRatio, contentMode: .fit)
                    .artworkScrim(opacity: isHovering ? 0.7 : 0)
            }
            .buttonStyle(.plain)
            .help(game.title)

            // Deliberately siblings of the link rather than inside its label: a button
            // nested in a `NavigationLink` on macOS never receives the click, the link does,
            // so the old card's Play button inside a tappable card would have opened the
            // game's page instead of playing it.
            overlayControls
        }
        .background {
            if glowRadius > 0, let url = game.verticalImageURL {
                GameArtwork(game: nil, url: url, cornerRadius: 0)
                    .blur(radius: glowRadius)
                    .opacity(0.55)
                    .scaleEffect(1.04)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(isHovering ? 1.02 : 1)
        .shadow(color: .black.opacity(isHovering ? 0.35 : 0), radius: 14, y: 6)
        .zIndex(isHovering ? 1 : 0)
    }

    @ViewBuilder
    private var overlayControls: some View {
        VStack {
            HStack(alignment: .top) {
                if game.isUpdateAvailable == true {
                    PortalBadge(String(localized: "Update"), systemImage: "arrow.down.circle")
                        .foregroundStyle(.white)
                        .padding(Theme.Spacing.xsmall)
                        .floatingCapsule()
                        .help("An update is available. Install it from this game's menu.")
                }

                Spacer(minLength: 0)

                if game.isFavourited || isHovering {
                    FavouriteToggle(game: $game)
                }
            }

            Spacer(minLength: 0)

            if isHovering {
                if let operation {
                    OperationCard.StatusView(operation: .constant(operation), withLabel: false)
                        .padding(Theme.Spacing.small)
                        .floatingCapsule()
                } else {
                    GameCard.PrimaryActionButton(game: $game)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.small)
    }

    // MARK: Caption

    private var caption: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xsmall) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                Text(game.title)
                    .font(Theme.Text.cardTitle)
                    // Two lines, reserved whether used or not. This single modifier is what
                    // makes every row of the grid the same height, and it's why the title no
                    // longer needs to be truncated to a word and a half.
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                    .help(game.title)

                HStack(spacing: Theme.Spacing.xsmall) {
                    if let operation {
                        Text(operation.type.description)
                            .font(Theme.Text.badge)
                            .foregroundStyle(Theme.Palette.brandSecondary)
                            .lineLimit(1)
                    } else {
                        if let storefront = game.storefront, !isCompact {
                            PortalBadge(storefront.description, tint: storefront.tint)
                        }

                        if case .uninstalled = game.installationState {
                            PortalBadge(String(localized: "Not installed"))
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            GameCard.MenuView(game: $game)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .opacity(isHovering ? 1 : 0.4)
        }
        .padding(.horizontal, Theme.Spacing.tiny)
    }
}

// MARK: - Favourite

extension GameCard {
    /// The star, as a control on the artwork rather than a glyph beside the title.
    struct FavouriteToggle: View {
        @Binding var game: Game

        var body: some View {
            Button {
                withAnimation(Theme.Motion.hover) { game.isFavourited.toggle() }
            } label: {
                Image(systemName: "star")
                    .symbolVariant(game.isFavourited ? .fill : .none)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(game.isFavourited ? .yellow : .white)
                    .padding(Theme.Spacing.small - 2)
            }
            .buttonStyle(.plain)
            .floatingCapsule(interactive: true)
            .help(game.isFavourited
                  ? String(localized: "Remove \(game.description) from your favourites")
                  : String(localized: "Add \(game.description) to your favourites"))
        }
    }

    /// Play, or install, depending on which one the game can do — one prominent control
    /// rather than a row of same-sized icons with no hierarchy between them.
    struct PrimaryActionButton: View {
        @Binding var game: Game
        var isCompact: Bool = true

        var body: some View {
            if case .installed = game.installationState {
                GameCard.Buttons.Prominent.PlayButton(game: $game, withLabel: true, isCompact: isCompact)
            } else {
                GameCard.Buttons.Prominent.InstallButton(game: $game, withLabel: true, isCompact: isCompact)
            }
        }
    }
}

/// ViewModifier that enables views to have a fade in effect.
struct FadeInModifier: ViewModifier {
    @State private var opacity: Double = 0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5)) {
                    opacity = 1
                }
            }
    }
}

#Preview {
    NavigationStack {
        LazyVGrid(columns: [.init(.adaptive(minimum: 170), spacing: Theme.Grid.spacing)],
                  spacing: Theme.Grid.spacing) {
            ForEach(0..<4, id: \.self) { _ in
                GameCard(game: .constant(placeholderGame(type: Game.self)),
                         hoveredGameID: .constant(nil))
            }
        }
        .padding(Theme.Spacing.xlarge)
    }
    .environmentObject(NetworkMonitor.shared)
    .frame(width: 760, height: 420)
}
