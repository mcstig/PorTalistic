//
//  GOGGameImportView.swift
//  Mythic
//
//  Created by Claude (Cowork) on 13/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import OSLog

/// The GOG tab of Import Game.
///
/// Epic's tab is an installer — pick a game, pick a platform, pick a folder — because
/// `legendary` can fetch the game. This one can't yet, so it's about the account: sign in,
/// see what arrived, and be told plainly where installing currently comes from instead of
/// being offered a button that would fail.
struct GOGGameImportView: View {
    @Binding var isPresented: Bool

    @Bindable var gameDataStore: GameDataStore = .shared

    @State private var isSignedIn: Bool = GOG.isSignedIn
    @State private var isRefreshing: Bool = false
    @State private var refreshError: Error?
    @State private var isRefreshErrorPresented: Bool = false

    private var ownedGames: [GOGGame] {
        gameDataStore.library.compactMap { $0 as? GOGGame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "building.columns")
                Text("GOG")
                    .font(.title2.bold())
            }

            if isSignedIn {
                Text("^[\(ownedGames.count) game](inflect: true) in your GOG library.")
                    .foregroundStyle(.secondary)

                Text("""
                    GOG games are DRM-free, so Mythic can run them without anything else \
                    running alongside. Downloading them from GOG isn't built yet — install a \
                    game with GOG Galaxy or an offline installer, then add it from the Local \
                    tab, and it'll launch from here.
                    """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Refresh Library", systemImage: "arrow.clockwise") {
                        refresh()
                    }
                    .disabled(isRefreshing)

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Button("Sign Out", role: .destructive) {
                        try? GOG.signOut()
                        isSignedIn = GOG.isSignedIn
                    }
                }
            } else {
                Text("Sign in to GOG to see the games you own.")
                    .foregroundStyle(.secondary)

                Button("Sign In", systemImage: "person.crop.circle") {
                    GOGWebAuthViewModel.shared.showSignInWindow()
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        // The sign-in happens in its own window, so this view has to notice on its own that
        // the account arrived rather than being told.
        .onChange(of: GOGWebAuthViewModel.shared.signInSuccess) { _, success in
            if success { isSignedIn = GOG.isSignedIn }
        }
        .onAppear { isSignedIn = GOG.isSignedIn }
        .alert(isPresented: $isRefreshErrorPresented) {
            .init(
                title: Text("Couldn't refresh your GOG library."),
                message: Text(refreshError?.localizedDescription ?? String(localized: "An unknown error occurred.")),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func refresh() {
        isRefreshing = true

        Task {
            do {
                try await gameDataStore.refreshFromStorefronts(.gog)
            } catch {
                refreshError = error
                isRefreshErrorPresented = true
            }

            isRefreshing = false
            isSignedIn = GOG.isSignedIn
        }
    }
}
