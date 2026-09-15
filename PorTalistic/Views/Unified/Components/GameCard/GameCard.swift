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

/// Which card in a grid or shelf the pointer is over.
///
/// Its own observable object so that a hover change reaches the cards without going through
/// the grid: as `@State` on the grid, every crossing re-ran the grid's body, and its body
/// filters and sorts the whole library.
@Observable final class CardHoverState {
    var gameID: Game.ID?

    /// Set while the enclosing scroll view is moving.
    ///
    /// Hover is the thing driving the remaining redraws: `onHover` fires as cards slide
    /// under a pointer that is standing still, so a scroll produced a hover change every
    /// time a card's edge crossed the cursor, and every card reads the hovered id. Measured
    /// at about two hundred card bodies a second while scrolling, which is six or seven
    /// hover changes across thirty visible cards.
    ///
    /// Nobody is pointing at anything on purpose mid-scroll, so hover simply stops updating
    /// until it settles. Deliberately not read from any `body` — only inside event handlers,
    /// where reading it registers no dependency.
    var isScrolling: Bool = false
}

/// Turns the scroll view's phase into ``CardHoverState/isScrolling``.
///
/// A modifier because `onScrollPhaseChange` needs macOS 15 and the app targets 14.
struct ScrollPhaseReporter: ViewModifier {
    let hover: CardHoverState

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                let isScrolling = phase != .idle
                guard hover.isScrolling != isScrolling else { return }

                hover.isScrolling = isScrolling

                // Once, at the start. Leaving a card hovered through a scroll would strand
                // its Play button somewhere in the middle of the grid.
                if isScrolling { hover.gameID = nil }
            }
        } else {
            content
        }
    }
}

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
    /// The game, not a binding to it.
    ///
    /// This mattered more than anything else in here. `Binding` is not comparable, so a view
    /// that stores one can never be skipped: SwiftUI has to re-run its body whenever the
    /// enclosing list is laid out, which during a scroll is every tick. The render counter
    /// measured three hundred card bodies a second against *three* artwork bodies — and
    /// `GameArtwork` takes plain values, so SwiftUI could skip it. The cards were the only
    /// thing in the grid it couldn't.
    ///
    /// `Game` is a class and `@Observable`, so a binding bought nothing anyway: the children
    /// that still ask for one get ``boundGame``, which writes to the same object.
    let game: Game

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
    ///
    /// An object rather than a `Binding` to the grid's `@State`, which is what it was: a
    /// binding writes *through* to the grid, so every card the pointer crossed invalidated
    /// the grid's own body — which filters and sorts the library and rebuilds every card in
    /// it. Moving the pointer across a full-screen library did that once per card, and so
    /// did scrolling, because the cards move under a pointer that is standing still.
    let hover: CardHoverState

    /// Settings ▸ View calls this "Gamecard Glow". It used to draw a blurred copy of the
    /// artwork *behind the image itself*, to fill the margins of a letterboxed cover — so
    /// with artwork now filling its tile it had quietly stopped doing anything at all. A
    /// glow is what the label says, so a glow is what it does: the cover art bled out past
    /// the edges of its own tile. Nothing at all at the default of 0.
    ///
    /// Passed in rather than read with `@AppStorage`, as is ``cardSize``. Each `@AppStorage`
    /// is a defaults observer per card, and every one of them wakes on *any* defaults write
    /// — including the library encoding itself into `UserDefaults`, which happens on every
    /// library change. Two per card across a library is a few hundred observers taking a
    /// look every time anything is saved.
    var glowRadius: Double = 0

    /// Read here only to decide how much of a badge fits.
    var cardSize: GameCardSize = .regular

    @State private var isSettingsPresented: Bool = false
    @State private var isUninstallPresented: Bool = false

    private var isHovering: Bool { hover.gameID == game.id }

    /// For the children that still take a `Binding<Game>`.
    ///
    /// `.constant` is honest here rather than lossy: `Game` is a reference type, so every
    /// one of those children is mutating the same object this card was handed.
    private var boundGame: Binding<Game> { .constant(game) }

    var body: some View {
#if DEBUG
        RenderCounter.record("GameCard")
#endif
        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            artwork
            caption
        }
        .contentShape(.rect)
        .onHover { hovering in
            // Not mid-scroll: see `CardHoverState.isScrolling`. Read here rather than in the
            // body on purpose — an event handler registers no observation dependency.
            guard !hover.isScrolling else { return }

            withAnimation(Theme.Motion.hover) {
                if hovering {
                    hover.gameID = game.id
                } else if hover.gameID == game.id {
                    hover.gameID = nil
                }
            }
        }
        .contextMenu {
            GameCard.ContextMenuItems(game: boundGame,
                                      isSettingsPresented: $isSettingsPresented,
                                      isUninstallPresented: $isUninstallPresented)
        }
        .gameSettingsSheet(game: boundGame, isPresented: $isSettingsPresented)
        .gameUninstallSheet(game: boundGame, isPresented: $isUninstallPresented)
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

                FavouriteToggle(game: boundGame)
                    .revealedOnHover(game.isFavourited || isHovering)
            }

            Spacer(minLength: 0)

            // Progress only, and not hidden behind hover: a download you can't see the state
            // of without pointing at it is worse than no indicator. The primary action moved
            // to the caption row — see `GameCard.ActionIconButton`.
            GameCard.OperationStatus(game: boundGame)

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
                    GameCard.CaptionBadges(game: boundGame, isCompact: isCompact, cardSize: cardSize)
                }
            }

            Spacer(minLength: 0)

            // Download or play, beside the menu rather than over the artwork. Always visible:
            // it is the one thing on a card someone came to press, and hiding it behind hover
            // is what made the artwork ambiguous about what a click on the card itself does.
            GameCard.ActionIconButton(game: boundGame)

            // `isPopulated` rather than `if isHovering { … }`: same view, same identity, same
            // size, so nothing shifts — but the four command views are only built while the
            // pointer is on the card, which is the only time this can be opened. Built
            // unconditionally they were constructed in every card body evaluation, two
            // hundred a second while scrolling, for a control nobody could click.
            GameCard.MenuView(game: boundGame,
                              isSettingsPresented: $isSettingsPresented,
                              isUninstallPresented: $isUninstallPresented,
                              isPopulated: isHovering)
                .buttonStyle(.portalQuietCompact)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .opacity(isHovering ? 1 : 0.4)
        }
        .padding(.horizontal, Theme.Spacing.tiny)
    }
}

// MARK: - Queue-dependent pieces

extension GameCard {
    /// What this game is doing, over its artwork — and nothing at all when it isn't.
    ///
    /// A view of its own so that reading the operation queue invalidates *this* and not the
    /// whole card. `GameCard` used to hold a `@Bindable GameOperationManager` and ask it for
    /// the game's operation twice per body, so every progress tick of any download in the
    /// queue redrew every card in the grid — artwork, placeholder gradients and all.
    struct OperationStatus: View {
        @Binding var game: Game

        @Bindable private var operationManager: GameOperationManager = .shared

        var body: some View {
            if let operation = operationManager.operation(for: game) {
                OperationCard.StatusView(operation: .constant(operation), withLabel: false)
                    .padding(Theme.Spacing.small)
                    .floatingCapsule()
            }
        }
    }

    /// What sits under the title: what the game is doing, or where it came from.
    struct CaptionBadges: View {
        @Binding var game: Game
        var isCompact: Bool = false
        var cardSize: GameCardSize = .regular

        @Bindable private var operationManager: GameOperationManager = .shared

        var body: some View {
            if let operation = operationManager.operation(for: game) {
                Text(operation.type.description)
                    .font(Theme.Text.badge)
                    .foregroundStyle(Theme.Palette.brandSecondary)
                    .lineLimit(1)
            } else {
                if let storefront = game.storefront, !isCompact {
                    PortalBadge(cardSize == .small ? "" : storefront.description,
                                systemImage: storefront.symbolName,
                                tint: storefront.tint)
                        .help(storefront.description)
                }

                if case .uninstalled = game.installationState {
                    PortalBadge(String(localized: "Not installed"))
                }
            }
        }
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
                GameCard(game: placeholderGame(type: Game.self), hover: .init())
            }
        }
        .padding(Theme.Spacing.xlarge)
    }
    .environmentObject(NetworkMonitor.shared)
    .frame(width: 760, height: 420)
}
