//
//  GameImportView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 29/9/2023.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import OSLog

struct GameImportView: View {
    @Binding var isPresented: Bool

    /// Which storefront to open on. Passed in from the library you asked from, so importing
    /// into the Steam library doesn't begin by asking which storefront you meant.
    @State private var selection: Game.Storefront

    init(isPresented: Binding<Bool>, storefront: Game.Storefront? = nil) {
        self._isPresented = isPresented
        self._selection = .init(initialValue: storefront ?? .epicGames)
    }

    var body: some View {
        VStack {
            if #available(macOS 15.0, *) {
                TabView(selection: $selection) {
                    Tab("Epic", systemImage: "storefront", value: Game.Storefront.epicGames) {
                        EpicGamesGameImportView(isPresented: $isPresented)
                    }

                    Tab("Steam", systemImage: "storefront", value: Game.Storefront.steam) {
                        SteamGameImportView(isPresented: $isPresented)
                    }

                    Tab("Local", systemImage: "storefront", value: Game.Storefront.local) {
                        LocalGameImportView(isPresented: $isPresented)
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
                .tabViewSidebarHeader(content: { Text("Select storefront:") })
            } else {
                TabView(selection: $selection) {
                    EpicGamesGameImportView(isPresented: $isPresented)
                        .tabItem {
                            Label("Epic", systemImage: "storefront")
                        }
                        .tag(Game.Storefront.epicGames)

                    SteamGameImportView(isPresented: $isPresented)
                        .tabItem {
                            Label("Steam", systemImage: "storefront")
                        }
                        .tag(Game.Storefront.steam)

                    LocalGameImportView(isPresented: $isPresented)
                        .tabItem {
                            Label("Local", systemImage: "storefront")
                        }
                        .tag(Game.Storefront.local)
                }
                .padding()
            }
        }
        .navigationTitle("Import Game")
        .frame(minWidth: 750, minHeight: 300, idealHeight: 350)
    }
}

#Preview {
    GameImportView(isPresented: .constant(true))
}
