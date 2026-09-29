//
//  GameInstallProgress.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 18/2/2024.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI

struct InteractiveGameOperationProgressView: View {
    @Binding var operation: GameOperation
    var withLabel: Bool = true

    @State private var isGameOperationStatusViewPresented: Bool = false

    @State private var isStopGameOperationAlertPresented: Bool = false
    @State private var isHoveringOverDestructiveButton: Bool = false

    var body: some View {
        HStack {
            OperationProgressView(operation: operation, withLabel: withLabel)
                .layoutPriority(1)

            if operation.type.modifiesFiles, operation.isExecuting {
                Button {
                    isGameOperationStatusViewPresented = true
                } label: {
                    Image(systemName: "info")
                }
                .clipShape(.capsule)
                .help("View operation progress")
                .sheet(isPresented: $isGameOperationStatusViewPresented) {
                    GameOperationStatusView(isPresented: $isGameOperationStatusViewPresented, operation: $operation)
                        .padding()
                }
            }

            Button {
                isStopGameOperationAlertPresented = true
            } label: {
                Image(systemName: "xmark")
                    .conditionalTransform(if: isHoveringOverDestructiveButton) { view in
                        view.foregroundStyle(.red)
                    }
            }
            .clipShape(.capsule)
            .help(isLaunch
                  ? String(localized: "Force \"\(operation.game.title)\" to quit")
                  : String(localized: "Cancel operation"))
            .onHover { hovering in
                withAnimation {
                    isHoveringOverDestructiveButton = hovering
                }
            }
            .alert(stopPrompt, isPresented: $isStopGameOperationAlertPresented) {
                // Through the manager, never the operation itself: stopping an install the
                // person asked to stop is not the same as one stopped by quitting, and only
                // one of the two is picked up again next time. See
                // `GameOperationManager.cancel(_:)`.
                Button(isLaunch ? "Force Quit" : "Stop", role: .destructive) {
                    GameOperationManager.shared.cancel(operation)
                }

                Button("Cancel", role: .cancel, action: {})
            }
        }
    }

    private var isLaunch: Bool { operation.type == .launch }

    /// A running game is force-quit, not cancelled: `wineserver -k` takes the prefix down and
    /// the game loses whatever it hasn't saved, which is worth saying out loud.
    private var stopPrompt: String {
        isLaunch
            ? String(localized: "Force \"\(operation.game.title)\" to quit? Anything unsaved will be lost.")
            : String(localized: "Do you wish to stop \(operation.type.description.localizedLowercase) \(operation.game.description)?")
    }
}

struct OperationProgressView: View {
    var operation: GameOperation

    var withLabel: Bool = false

    var body: some View {
        if operation.type == .launch {
            // A launch has nothing to be a fraction of. It is either still starting — which is
            // what the spinner means, and it ends when the game is actually on screen — or the
            // game is up and this is the row that can force it closed.
            if operation.launchPhase != .running {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "play.fill")
                    .imageScale(.small)
            }

            if withLabel {
                Text(operation.statusDescription)
                    .lineLimit(1)
            }
        } else if operation.progressKVOBridge.fractionCompleted == 0 {
            ProgressView()
                .controlSize(.small)
            
            if withLabel {
                Text(operation.statusDescription)
                    .lineLimit(1)
            }
        } else {
            ProgressView(value: operation.progressKVOBridge.fractionCompleted)
                .help("\(operation.progressKVOBridge.fractionCompleted.formatted(.percent)) complete")
            
            if withLabel {
                Text(operation.progressKVOBridge.fractionCompleted.formatted(.percent))
                    .layoutPriority(1)
                    .lineLimit(1)
            }
        }
    }
}

#Preview {
    InteractiveGameOperationProgressView(
        operation: .constant(
            .init(game: placeholderGame(type: Game.self),
                  type: .install,
                  function: { _ in })
        )
    )
}
