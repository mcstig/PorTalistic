//
//  OperationsView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 5/4/2024.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import Shimmer
import SwordRPC

struct OperationsView: View {
    @Bindable private var operationManager: GameOperationManager = .shared
    
    var body: some View {
        Group {
            if !operationManager.queue.isEmpty {
                GeometryReader { geometry in
                    ScrollView {
                        VStack {
                            if let prominentOperation = operationManager.queue.first(where: { $0.isExecuting && $0.type.modifiesFiles }) {
                                ProminentOperationCard(operation: .constant(prominentOperation))
                                    .frame(width: geometry.size.width,
                                           height: min(geometry.size.height * 0.55, 420))
                            }
                            
                            let nonProminentOperations = operationManager.queue.filter({ $0 != operationManager.queue.first(where: { $0.isExecuting && $0.type.modifiesFiles }) })
                            
                            if nonProminentOperations.isEmpty {
                                ContentUnavailableView(
                                    "No new game operations are queued.",
                                    systemImage: "checkmark",
                                    description: .init("If you attempt to download more than one game at the same time, it'll be added to this queue.")
                                )
                            } else {
                                VStack(spacing: Theme.Spacing.medium) {
                                    ForEach(nonProminentOperations) { operation in
                                        OperationCard(operation: .constant(operation))
                                    }
                                }
                                .padding(Theme.Spacing.xlarge)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No new operations! 😁",
                    systemImage: "checkmark",
                    description: Text("""
                        All game operations that may have been pending are complete.
                        You may access downloaded games in your [\(Image(systemName: "books.vertical")) Library].
                        """)
                )
            }
        }
        .artworkUnderTitleBar()
        .navigationTitle("Operations")
        .task(priority: .background) {
            discordRPC.setPresence({
                var presence: RichPresence = .init()
                presence.details = "Waiting for games to finish operating"
                presence.state = "Viewing Operations"
                presence.timestamps.start = .now
                presence.assets.largeImage = "macos_512x512_2x"
                
                return presence
            }())
        }
    }
}

#Preview {
    OperationsView()
}
