//
//  HomeView.swift
//  PorTalistic
//
//  Created by vapidinfinity (esi) on 12/9/2023.
//  Rebuilt by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI
import SwordRPC

/**
 The first thing the app shows: the game you were last playing, and a few rows worth of the
 rest.

 The previous Home gave the most recent game three quarters of the window's height and drew
 it with a progressive blur, which on a 16:9 cover cropped to a 4:3 opening meant the screen
 was mostly a black rectangle with a small caption in the corner. Underneath it, a
 `Form(.grouped)` — the visual language of a settings pane — held a grid of favourites and a
 list of Wine containers, so scrolling down from a cinematic hero landed you in System
 Settings.

 Now: a hero sized to leave room for what's below it, with a gradient scrim instead of a
 blur so the artwork survives; then horizontal shelves, which is how a library of 129 games
 is skimmed. Containers moved out entirely — they have their own place in the sidebar, and
 they were never something you wanted on the way to playing something.
 */
struct HomeView: View {
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @Bindable var gameDataStore: GameDataStore = .shared

    private var recent: Game? { gameDataStore.recent }

    /// Installed games by when they were last played, most recent first, minus the one
    /// already filling the hero.
    private var jumpBackIn: [Game] {
        gameDataStore.library
            .filter { $0.lastLaunched != nil && $0 != recent }
            .sorted { ($0.lastLaunched ?? .distantPast) > ($1.lastLaunched ?? .distantPast) }
            .prefix(14)
            .map(\.self)
    }

    private var favourites: [Game] {
        gameDataStore.library
            .filter { $0.isFavourited && $0 != recent }
            .sorted { $0.title < $1.title }
    }

    /// Installed and never launched from here — the pile you meant to get to.
    private var readyToPlay: [Game] {
        gameDataStore.library
            .filter { game in
                guard case .installed = game.installationState else { return false }
                return game.lastLaunched == nil && !game.isFavourited && game != recent
            }
            .sorted { $0.title < $1.title }
            .prefix(14)
            .map(\.self)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if let recent {
                    HomeHero(game: .constant(recent))
                } else {
                    welcome
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    GameShelf(title: String(localized: "Jump back in"),
                              systemImage: "clock.arrow.circlepath",
                              games: jumpBackIn)

                    GameShelf(title: String(localized: "Your favourites"),
                              systemImage: "star",
                              games: favourites,
                              emptyMessage: recent == nil ? nil : String(localized: "Games you favourite show up here. Right-click any game to favourite it."))

                    GameShelf(title: String(localized: "Ready to play"),
                              systemImage: "arrow.down.circle",
                              games: readyToPlay)
                }
                .padding(.bottom, Theme.Spacing.section)
            }
        }
        .artworkUnderTitleBar()
        .navigationTitle("Home")
        .task(priority: .background) {
            discordRPC.setPresence({
                var presence: RichPresence = .init()
                presence.details = "Viewing home"
                presence.state = "Idle"
                presence.timestamps.start = .now
                presence.assets.largeImage = "macos_512x512_2x"

                return presence
            }())
        }
    }

    private var welcome: some View {
        VStack(spacing: Theme.Spacing.large) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.portal)
                    .frame(width: 78, height: 78)
                    .blur(radius: 26)

                Image(systemName: "circle.hexagonpath")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Theme.Palette.portal)
            }

            VStack(spacing: Theme.Spacing.small) {
                Text("Welcome to \(Branding.name)")
                    .font(Theme.Text.heroTitle)

                Text("Sign in to a storefront in the sidebar, or import a game you already have. Whatever you play last shows up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical) { length, _ in min(max(length * 0.52, 280), 420) }
    }
}

// MARK: - Hero

private struct HomeHero: View {
    @Binding var game: Game

    var body: some View {
        GameArtwork(game: game,
                    url: game.horizontalImageURL ?? game.verticalImageURL,
                    orientation: .horizontal,
                    cornerRadius: 0)
            .containerRelativeFrame(.vertical) { length, _ in min(max(length * 0.52, 280), 440) }
            // A gradient, not a blur. `.glur` faded the image itself into the background,
            // which reads as "the art failed to load" rather than as depth, and it took the
            // whole bottom half of a cover with it.
            .artworkScrim(opacity: 0.96)
            // The window's close/minimise/zoom buttons float directly on this artwork, and
            // on a bright cover they vanish. A short darkening at the very top costs nothing
            // and means they are always visible.
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: 96)
                    .allowsHitTesting(false)
            }
            .artworkFadesOut()
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    Text("CONTINUE PLAYING")
                        .font(Theme.Text.heroEyebrow)
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.75))

                    Text(game.title)
                        .font(Theme.Text.heroTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)

                    HStack(spacing: Theme.Spacing.small) {
                        if let storefront = game.storefront {
                            PortalBadge(storefront.description,
                                        systemImage: storefront.symbolName,
                                        tint: .white)
                        }

                        if let lastLaunched = game.lastLaunched {
                            PortalBadge(lastLaunched.formatted(.relative(presentation: .named)),
                                        systemImage: "clock",
                                        tint: .white)
                        }
                    }

                    HStack(spacing: Theme.Spacing.medium) {
                        GameCard.PrimaryActionButton(game: $game, isCompact: false)

                        NavigationLink(value: GameRoute(gameID: game.id)) {
                            Label("Details", systemImage: "info.circle")
                                .font(.system(.body, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, Theme.Spacing.large)
                                .padding(.vertical, Theme.Spacing.small)
                        }
                        .buttonStyle(.plain)
                        .floatingCapsule(interactive: true)

                        GameCard.FavouriteToggle(game: $game)
                    }
                    .padding(.top, Theme.Spacing.xsmall)
                }
                .padding(.horizontal, Theme.Spacing.xlarge)
                // Clear of `artworkFadesOut`, so the Play button never sits in the part of
                // the hero that is busy dissolving.
                .padding(.bottom, Theme.Spacing.xxlarge)
            }
    }
}

// MARK: - Shelf

/// A horizontal row of cards under a heading.
///
/// Horizontal rather than a wrapping grid because a shelf's job is to be glanced at: a
/// `LazyVGrid` of favourites grew the page every time one was added, and pushed everything
/// below it further out of reach.
struct GameShelf: View {
    let title: String
    let systemImage: String
    let games: [Game]

    /// Shown in place of the row when there is nothing in it. `nil` hides the shelf entirely,
    /// which is the right answer for a shelf the user hasn't earned yet.
    var emptyMessage: String?

    @State private var hoveredGameID: Game.ID?
    @AppStorage(GameCardSize.storageKey) private var cardSize: GameCardSize = .regular

    var body: some View {
        if !games.isEmpty || emptyMessage != nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                HStack(spacing: Theme.Spacing.small) {
                    Label(title, systemImage: systemImage)
                        .font(Theme.Text.sectionTitle)

                }
                .padding(.horizontal, Theme.Spacing.xlarge)

                if games.isEmpty, let emptyMessage {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.xlarge)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Theme.Grid.spacing) {
                            ForEach(games) { game in
                                GameCard(game: .constant(game),
                                         isCompact: true,
                                         hoveredGameID: $hoveredGameID)
                                    .frame(width: cardSize.shelfCardWidth)
                            }
                        }
                        // Room for the hover lift and its shadow, which a tight clip would
                        // otherwise cut off at the top and bottom of the row.
                        .padding(.horizontal, Theme.Spacing.xlarge)
                        .padding(.vertical, Theme.Spacing.small)
                    }
                    .scrollIndicators(.hidden)
                    .onHover { if !$0 { hoveredGameID = nil } }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .environmentObject(NetworkMonitor.shared)
    }
    .frame(width: 1100, height: 720)
}
