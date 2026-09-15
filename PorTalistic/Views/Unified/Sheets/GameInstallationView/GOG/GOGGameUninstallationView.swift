//
//  GOGGameUninstallationView.swift
//  Mythic
//
//  Created by Claude (Cowork) on 13/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import OSLog

struct GOGGameUninstallationView: View {
    @Binding var game: GOGGame
    @Binding var isPresented: Bool

    @State private var isImageEmpty: Bool = true
    @State private var isOperating: Bool = false

    @State private var removeFromDisk: Bool = true

    var body: some View {
        BaseGameInstallationView(
            game: .init(get: { game as Game },
                        set: {
                            if let castGame = $0 as? GOGGame {
                                game = castGame
                            }
                        }),
            isPresented: $isPresented,
            isImageEmpty: $isImageEmpty,
            type: "Uninstall",
            operating: $isOperating,
            action: {
                Task(priority: .userInitiated) { @MainActor [game] in
                    _ = try await GOGGameManager.uninstall(game: game, persistFiles: !removeFromDisk)
                }
            },
            content: {
                Form {
                    Toggle("Remove files from disk",
                           systemImage: "trash",
                           isOn: $removeFromDisk)
                }
                .portalForm()

                Text("The game stays in your library — it's still yours, it's just no longer installed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        )
        .navigationTitle("Uninstall \(game.description)")
    }
}

#Preview {
    GOGGameUninstallationView(game: .constant(placeholderGame(type: GOGGame.self)),
                              isPresented: .constant(true))
    .padding()
}
