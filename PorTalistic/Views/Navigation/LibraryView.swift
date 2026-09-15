//
//  LibraryView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 12/9/2023.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import SwiftyJSON
import SwordRPC

/// A view displaying the user's library of games.
struct LibraryView: View {
    /// Which storefront this library shows. `nil` is the combined view.
    var storefront: Game.Storefront?

    @Bindable var gameDataStore: GameDataStore = .shared
    @ObservedObject private var variables: VariableManager = .shared

    @State private var isGameImportSheetPresented = false
    @Bindable var gameListViewModel: GameListViewModel = .shared
    @CodableAppStorage("gameListLayout") var gameListLayout: GameListViewModel.Layout = .grid
    @AppStorage(GameCardSize.storageKey) private var cardSize: GameCardSize = .regular

    var body: some View {
        VStack(spacing: 0) {
            // Above the list, not instead of it: a signed-out storefront may still have games
            // from a previous session worth looking at, and hiding them to show a sign-in
            // prompt would lose that.
            if let storefront {
                StorefrontSignInBanner(storefront: storefront)
            }

            GameListView(storefront: storefront)
        }
            .navigationTitle(storefront?.description ?? String(localized: "All Games"))
            .standardTitleBar()
        
            .toolbar {
                ToolbarItem(placement: .status) {
                    if gameListViewModel.isUpdatingLibrary {
                        ProgressView()
                            .controlSize(.small)
                            .help("\(Branding.name) is updating your library.")
                            .padding(10)
                    }
                }
                
                ToolbarItem(placement: .automatic) {
                    Button {
                        isGameImportSheetPresented = true
                    } label: {
                        Label("Import Game", systemImage: "plus.app")
                    }
                    .help(storefront.map { String(localized: "Import a \($0.description) game") }
                          ?? String(localized: "Import a game"))
                }
                
                if let storefront, storefront.usesAccount, !storefront.isSignedIn {
                    ToolbarItem(placement: .automatic) {
                        Button("Sign In", systemImage: "person") {
                            storefront.presentSignIn()
                        }
                        .help("Sign in to \(storefront.description)")
                    }
                }

                // Plain buttons rather than a size picker, because this is a zoom control
                // and zoom controls are two buttons everywhere else on the system. Each step
                // is 30%; they disable themselves at the ends so the current size is always
                // legible from the toolbar without opening anything.
                if gameListLayout == .grid, gameListViewModel.hasAnyGames(inStorefront: storefront) {
                    ToolbarItemGroup(placement: .automatic) {
                        Button("Smaller Cards", systemImage: "minus.magnifyingglass") {
                            if let smaller = cardSize.stepped(by: -1) { cardSize = smaller }
                        }
                        .disabled(cardSize.stepped(by: -1) == nil)
                        .help("Make the game cards 30% smaller")

                        Button("Larger Cards", systemImage: "plus.magnifyingglass") {
                            if let larger = cardSize.stepped(by: 1) { cardSize = larger }
                        }
                        .disabled(cardSize.stepped(by: 1) == nil)
                        .help("Make the game cards 30% larger")
                    }
                }

                ToolbarItem(placement: .automatic) {
                    Button("Force-refresh", systemImage: "arrow.clockwise") {
                        // The one refresh that reaches for external drives. macOS may ask for
                        // permission to them, which is fair here: the user pressed this.
                        Task(priority: .userInitiated) {
                            try? await gameDataStore.refreshFromStorefronts(probingExternalVolumes: true)
                        }
                    }
                    .help("Re-check your library, including games on external drives.")
                }
                
                // MARK: GameListView filter views
                //
                // `hasAnyGames`, not `sortedLibrary.isEmpty`: these are the controls that undo
                // a filter, so testing them against the filtered result is what made a filter
                // matching nothing unrecoverable.
                if gameListViewModel.hasAnyGames(inStorefront: storefront) {
                    ToolbarItem(placement: .automatic) {
                        Picker("Layout", systemImage: "macwindow", selection: $gameListLayout) {
                            Label("List", systemImage: "rectangle.grid.1x3")
                                .tag(GameListViewModel.Layout.list)
                            
                            Label("Grid", systemImage: "square.grid.3x3")
                                .tag(GameListViewModel.Layout.grid)
                        }
                        .animation(.easeInOut, value: $gameListLayout.wrappedValue)
                    }
                    
                    ToolbarItem(placement: .automatic) {
                        Menu("Filters", systemImage: "line.3.horizontal.decrease") {
                            Section("Platform") {
                                ForEach(Game.Platform.allCases, id: \.self) { platform in
                                    Toggle(platform.description,
                                           isOn: searchTokenBinding(for: .platform(platform)))
                                }
                            }
                            
                            // Only in the combined view: filtering "Storefront" while
                            // already inside Steam's library is a control that can only
                            // make the list wrong.
                            if storefront == nil {
                                Section("Storefront") {
                                    // `.available`, not `allCases`: Steam is behind a flag,
                                    // so offering it as a filter meant filtering the library
                                    // down to nothing on purpose.
                                    ForEach(Game.Storefront.available, id: \.self) { candidate in
                                        Toggle(candidate.description,
                                               isOn: searchTokenBinding(for: .storefront(candidate)))
                                    }
                                }
                            }
                            
                            Section("Installation") {
                                Toggle("Installed",
                                       isOn: searchTokenBinding(for: .installed))
                                Toggle("Not Installed",
                                       isOn: searchTokenBinding(for: .notInstalled))
                            }
                            
                            Section {
                                Toggle("Favourites", isOn: searchTokenBinding(for: .favourited))
                            }

                            // A way out from inside the control that got you here, so undoing
                            // a filter never depends on whatever the filtered result happens
                            // to be showing.
                            if gameListViewModel.isFiltering {
                                Section {
                                    Button("Clear Filters", systemImage: "xmark.circle") {
                                        gameListViewModel.clearFilters()
                                    }
                                }
                            }
                        }
                        .menuIndicator(.hidden)
                    }
                }
            }
        
            .task(priority: .background) {
                discordRPC.setPresence({
                    var presence: RichPresence = .init()
                    presence.details = storefront.map { "Looking through their \($0.description) library" }
                        ?? "Looking through their game library"
                    presence.state = "Viewing Library"
                    presence.timestamps.start = .now
                    presence.assets.largeImage = "macos_512x512_2x"
                    
                    return presence
                }())
            }
        
            .sheet(isPresented: $isGameImportSheetPresented) {
                GameImportView(isPresented: $isGameImportSheetPresented, storefront: storefront)
            }
    }
    
    private func searchTokenBinding(for token: GameListViewModel.SearchToken) -> Binding<Bool> {
        .init(
            get: { gameListViewModel.searchTokens.contains(token) },
            set: { isOn in
                if isOn {
                    gameListViewModel.searchTokens.append(token)
                } else {
                    gameListViewModel.searchTokens.removeAll { $0 == token }
                }
            }
        )
    }
}

#Preview {
    LibraryView()
        .environmentObject(NetworkMonitor.shared)
        .frame(minHeight: 300)
}
