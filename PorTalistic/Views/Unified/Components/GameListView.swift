//
//  GameListView.swift
//  PorTalistic
//
//  Created by vapidinfinity (esi) on 6/3/2024.
//  Rebuilt by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import Foundation
import SwiftUI

struct GameListView: View {
    /// Which storefront this list shows. `nil` shows everything.
    var storefront: Game.Storefront?

    @Bindable var viewModel: GameListViewModel = .shared
    @Bindable var gameDataStore: GameDataStore = .shared

    @CodableAppStorage("gameListLayout") var layout: GameListViewModel.Layout = .grid
    @AppStorage(GameCardSize.storageKey) private var cardSize: GameCardSize = .regular
    // Read once here and handed to the cards, rather than each card keeping its own
    // defaults observer.
    @AppStorage("gameImageCardBlur") private var glowRadius: Double = 0

    @State private var isGameImportViewPresented: Bool = false

    /// Which card the pointer is over. An object, so a hover doesn't come back through this
    /// view's own state and rebuild the grid.
    @State private var hover: CardHoverState = .init()

    private var games: [Game] { viewModel.library(inStorefront: storefront) }

    /// Worked out once per body pass and handed down.
    ///
    /// `games` filters and sorts the library, and the body used to ask for it three times —
    /// for `isEmpty`, for the `ForEach`, and again as an `.animation` value — so every
    /// redraw of the list did the whole thing three times over.
    var body: some View {
#if DEBUG
        RenderCounter.record("GameListView")
#endif
        return content(for: games)
    }

    @ViewBuilder
    private func content(for games: [Game]) -> some View {
        Group {
            if games.isEmpty {
                empty
            } else {
                ScrollView(.vertical) {
                    switch layout {
                    case .grid:
                        LazyVGrid(
                            columns: [.init(.adaptive(minimum: cardSize.cardWidth), spacing: Theme.Grid.spacing)],
                            alignment: .leading,
                            spacing: Theme.Spacing.xlarge
                        ) {
                            ForEach(games) { game in
                                GameCard(game: game,
                                         hover: hover,
                                         glowRadius: glowRadius,
                                         cardSize: cardSize)
                            }
                        }
                        .padding(Theme.Spacing.xlarge)
                    case .list:
                        LazyVStack(spacing: Theme.Spacing.small) {
                            ForEach(games) { game in
                                ListGameCard(game: game)
                            }
                        }
                        .padding(Theme.Spacing.large)
                    }
                }
                // The grid's cards report hover here rather than each keeping its own flag;
                // this is the half that clears it when the pointer leaves the grid entirely,
                // which no individual card is in a position to notice.
                .modifier(ScrollPhaseReporter(hover: hover))
                .onHover { if !$0 { hover.gameID = nil } }
            }
        }
        // On the `Group`, so it outlives its own result. Attached to the scroll view inside
        // the `else`, a filter that matched nothing took the branch away — and the search
        // field with it, tokens included — leaving no way to undo the filter that had just
        // emptied the library. Filtering by Steam, which is behind a flag and owns no games,
        // did exactly that.
        .searchable(text: $viewModel.searchString,
                    tokens: $viewModel.searchTokens,
                    suggestedTokens: .constant(viewModel.suggestedTokens),
                    placement: .toolbar) { token in
            switch token {
            case .platform(let platform):
                Text(platform.description)
            case .storefront(let storefront):
                Text(storefront.description)
            case .installed:
                Text("Installed")
            case .notInstalled:
                Text("Not Installed")
            case .favourited:
                Text("Favourited")
            }
        }
        .animation(Theme.Motion.layout, value: layout)
        .animation(Theme.Motion.layout, value: cardSize)
        // The count, not the array. `value: games` compared every game to every game on
        // every body pass, and animated a relayout of the entire grid whenever any one of
        // them changed in any way — including a title fetch or a favourite being toggled.
        .animation(.default, value: games.count)
    }

    @ViewBuilder
    private var empty: some View {
        if viewModel.isFiltering {
            filteredToNothing
        } else {
            nothingHere
        }
    }

    /// The library isn't empty — the filter is just too narrow.
    ///
    /// Worth its own state rather than reusing "Nothing here yet.": that copy told someone
    /// with a hundred and thirty-seven games that they had none, and offered to import one,
    /// which is not the problem and not the fix.
    private var filteredToNothing: some View {
        VStack(spacing: Theme.Spacing.large) {
            ContentUnavailableView(
                String(localized: "No matches."),
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Nothing in this library matches what you're filtering by.")
            )

            Button("Clear Filters", systemImage: "xmark.circle") {
                withAnimation(Theme.Motion.layout) { viewModel.clearFilters() }
            }
            .buttonStyle(.portalProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nothingHere: some View {
        VStack(spacing: Theme.Spacing.large) {
            ContentUnavailableView(
                emptyTitle,
                systemImage: "square.grid.3x3.square",
                description: Text(emptyDescription)
            )
            .task {
                try? await gameDataStore.refreshFromStorefronts()
            }

            Button("Import Game", systemImage: "plus.app") {
                isGameImportViewPresented = true
            }
            .buttonStyle(.portalProminent)
            .sheet(isPresented: $isGameImportViewPresented) {
                // Opens on this list's storefront — there is no reason to ask again
                // which storefront you meant when you asked from inside its library.
                GameImportView(isPresented: $isGameImportViewPresented, storefront: storefront)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Empty-state copy that names the storefront being looked at, rather than claiming the
    /// whole library is empty when it's only this one shelf that is.
    private var emptyTitle: String {
        guard let storefront else { return String(localized: "Nothing here yet.") }
        return String(localized: "No \(storefront.description) games yet.")
    }

    private var emptyDescription: String {
        guard let storefront else {
            return String(localized: """
                Games in your library will appear here.
                If there are games in your library and they're not appearing, try restarting \(Branding.name).
                """)
        }

        switch storefront {
        case .epicGames:
            return String(localized: "Sign in to Epic Games and your library will appear here.")
        case .gog:
            return String(localized: "Sign in to GOG and your library will appear here.")
        case .steam:
            return String(localized: "Set up Steam, sign in to the Steam client, and the games you've installed will appear here.")
        case .local:
            return String(localized: "Games you add from your own disk will appear here.")
        }
    }
}

#Preview {
    NavigationStack {
        GameListView()
            .environmentObject(NetworkMonitor.shared)
    }
    .frame(width: 1000, height: 620)
}
