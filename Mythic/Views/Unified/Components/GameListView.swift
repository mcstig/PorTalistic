//
//  GameListView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 6/3/2024.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI

struct GameListView: View {
    /// Which storefront this list shows. `nil` shows everything.
    var storefront: Game.Storefront?

    @Bindable var viewModel: GameListViewModel = .shared
    @Bindable var gameDataStore: GameDataStore = .shared
    
    @CodableAppStorage("gameListLayout") var layout: GameListViewModel.Layout = .grid
    @AppStorage("gameCardSize") private var gameCardSize: Double = 200.0
    
    @State private var isGameImportViewPresented: Bool = false
    
    private var games: [Game] { viewModel.library(inStorefront: storefront) }

    var body: some View {
        VStack {
            if games.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "folder.badge.questionmark",
                    description: Text(emptyDescription)
                )
                .task {
                    try? await gameDataStore.refreshFromStorefronts()
                }

                Button {
                    isGameImportViewPresented = true
                } label: {
                    Label("Import Game", systemImage: "plus.app")
                        .padding(5)
                }
                .buttonStyle(.borderedProminent)
                .sheet(isPresented: $isGameImportViewPresented) {
                    // Opens on this list's storefront — there is no reason to ask again
                    // which storefront you meant when you asked from inside its library.
                    GameImportView(isPresented: $isGameImportViewPresented, storefront: storefront)
                }
            } else {
                ScrollView(.vertical) {
                    // FIXME: sortedLibrary should not be appended to or it'll cause overwrites.
                    // FIXME: a dirtyfix is to directly set to the underlying library
                    switch layout {
                    case .grid:
                        LazyVGrid(columns: [.init(.adaptive(minimum: gameCardSize))]) {
                            ForEach(games) { game in
                                GameCard(game: .constant(game))
                            }
                        }
                        .padding()
                    case .list:
                        LazyVStack {
                            ForEach(games) { game in
                                ListGameCard(game: .constant(game))
                            }
                        }
                        .padding()
                    }
                }
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
            }
        }
        .animation(.easeInOut, value: layout)
        .animation(.default, value: games)
    }

    /// Empty-state copy that names the storefront being looked at, rather than claiming the
    /// whole library is empty when it's only this one shelf that is.
    private var emptyTitle: String {
        guard let storefront else { return String(localized: "No games found. 😢") }
        return String(localized: "No \(storefront.description) games yet.")
    }

    private var emptyDescription: String {
        guard let storefront else {
            return String(localized: """
                Games in your library will appear here.
                If there are games in your library and they're not appearing, try restarting Mythic.
                """)
        }

        switch storefront {
        case .epicGames:
            return String(localized: "Sign in to Epic Games and your library will appear here.")
        case .steam:
            return String(localized: "Set up Steam, sign in to the Steam client, and the games you've installed will appear here.")
        case .local:
            return String(localized: "Games you add from your own disk will appear here.")
        }
    }
}
    
#Preview {
    GameListView()
        .environmentObject(NetworkMonitor.shared)
}
