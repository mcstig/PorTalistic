//
//  OperationCard.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 26/6/2024.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI

/**
 The operation currently doing the work, at the top of the Operations page.

 Both cards here used to draw their own Liquid Glass panels inline — four
 `#available(macOS 26.0, *)` checks between them, each with a different fallback, one of
 which wrapped its content in `.background(in:)` and one of which did nothing at all. They
 also flipped their text between `.primary` and white depending on whether an image had
 loaded. Surfaces come from the design system now, and the scrim means the text colour was
 never a question.
 */
struct ProminentOperationCard: View {
    @Binding var operation: GameOperation

    var body: some View {
        GameArtwork(game: operation.game,
                    url: operation.game.horizontalImageURL ?? operation.game.verticalImageURL,
                    orientation: .horizontal,
                    cornerRadius: 0)
            .artworkScrim(opacity: 0.94)
            .artworkFadesOut()
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    Text(operation.statusDescription.uppercased())
                        .font(Theme.Text.heroEyebrow)
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.75))

                    Text(operation.game.title)
                        .font(Theme.Text.heroTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)

                    HStack(spacing: Theme.Spacing.small) {
                        if let storefront = operation.game.storefront {
                            PortalBadge(storefront.description,
                                        systemImage: storefront.symbolName,
                                        tint: .white)
                        }
                    }

                    OperationCard.StatusView(operation: $operation, hideStatusIfUnknown: true)
                        .frame(maxWidth: 420, alignment: .leading)
                        .padding(.top, Theme.Spacing.xsmall)
                }
                .padding(.horizontal, Theme.Spacing.xlarge)
                .padding(.bottom, Theme.Spacing.xxlarge)
            }
    }
}

/// One queued or running operation, as a row.
struct OperationCard: View {
    @Binding var operation: GameOperation

    static let height: CGFloat = 76

    var body: some View {
        HStack(spacing: Theme.Spacing.large) {
            GameArtwork(game: operation.game,
                        url: operation.game.verticalImageURL,
                        cornerRadius: Theme.Radius.control)
                .frame(width: 44, height: 58)

            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                Text(operation.game.title)
                    .font(Theme.Text.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: Theme.Spacing.xsmall) {
                    PortalBadge(operation.statusDescription,
                                systemImage: "progress.indicator",
                                tint: Theme.Palette.brandSecondary)

                    GameCard.SubscriptedInfoView(game: .constant(operation.game))
                }
            }

            Spacer(minLength: Theme.Spacing.medium)

            StatusView(operation: $operation)
                .frame(maxWidth: 240, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .frame(height: Self.height)
        .panelSurface(cornerRadius: Theme.Radius.tile)
    }
}

extension OperationCard {
    struct StatusView: View {
        @Binding var operation: GameOperation
        @Bindable private var operationManager: GameOperationManager = .shared
        
        var hideStatusIfUnknown: Bool = false
        var withLabel: Bool = true
        
        var body: some View {
            if operation.isExecuting {
                InteractiveGameOperationProgressView(operation: $operation, withLabel: withLabel)
                    .clipShape(.capsule)
            } else if operationManager.queue.contains(operation), !operation.isCancelled {
                Button {
                    operationManager.cancel(operation)
                } label: {
                    Image(systemName: "minus")
                        .padding(2)
                }
                .help("Remove operation from queue")
            } else if operation.isCancelled {
                Image(systemName: "checkmark")
                    .help("This operation has been cancelled.")
            } else if !hideStatusIfUnknown {
                Image(systemName: "questionmark")
                    .help("This operation's status is unknown.")
            }
        }
    }
}

#Preview {
    ProminentOperationCard(operation: .constant(.init(game: placeholderGame(type: Game.self), type: .install, function: { _ in })))
        .padding()
        .environmentObject(NetworkMonitor.shared)
}
