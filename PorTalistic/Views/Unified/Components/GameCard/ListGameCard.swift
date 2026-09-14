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

 The previous row drew the game's 16:9 art full-bleed behind the text at a 30-point blur,
 then doubled its own height on hover and un-blurred — so moving the pointer down a list
 made every row below it jump, twice. It also flipped its text between primary and white
 depending on whether an image had finished loading.

 A row is a row: a thumbnail, the name, what it is, and the one thing you'd want to do to
 it. Constant height, so the list holds still under the pointer.
 */
struct ListGameCard: View {
    @Binding var game: Game

    @State private var isHovering: Bool = false
    @State private var isSettingsPresented: Bool = false
    @State private var isUninstallPresented: Bool = false

    @Bindable private var operationManager: GameOperationManager = .shared

    static let defaultHeight: CGFloat = 76

    private var operation: GameOperation? {
        operationManager.queue.first { $0.game == game && ($0.isExecuting || $0.type.modifiesFiles) }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.large) {
            NavigationLink(value: GameRoute(gameID: game.id)) {
                HStack(spacing: Theme.Spacing.large) {
                    GameArtwork(game: game,
                                url: game.verticalImageURL,
                                orientation: .vertical,
                                cornerRadius: Theme.Radius.control)
                        .frame(width: 44, height: 58)

                    VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                        Text(game.title)
                            .font(Theme.Text.rowTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.primary)

                        HStack(spacing: Theme.Spacing.xsmall) {
                            GameCard.SubscriptedInfoView(game: $game)

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

            if let operation {
                OperationCard.StatusView(operation: .constant(operation))
                    .frame(maxWidth: 220, alignment: .trailing)
            } else {
                GameCard.PrimaryActionButton(game: $game)
                    .opacity(isHovering ? 1 : 0.75)
            }

            GameCard.MenuView(game: $game)
                .buttonStyle(.portalQuietCompact)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .frame(height: Self.defaultHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(isHovering ? AnyShapeStyle(Theme.Palette.surface) : AnyShapeStyle(Color.clear))
        }
        .contentShape(.rect(cornerRadius: Theme.Radius.tile))
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) { isHovering = hovering }
        }
        .contextMenu {
            GameCard.ContextMenuItems(game: $game,
                                      isSettingsPresented: $isSettingsPresented,
                                      isUninstallPresented: $isUninstallPresented)
        }
        .gameSettingsSheet(game: $game, isPresented: $isSettingsPresented)
        .gameUninstallSheet(game: $game, isPresented: $isUninstallPresented)
    }
}

#Preview {
    NavigationStack {
        LazyVStack(spacing: Theme.Spacing.small) {
            ForEach(0..<4, id: \.self) { _ in
                ListGameCard(game: .constant(placeholderGame(type: Game.self)))
            }
        }
        .padding()
    }
    .environmentObject(NetworkMonitor.shared)
    .frame(width: 720, height: 380)
}
