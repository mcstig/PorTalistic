//
//  GameOperationStatusView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 3/12/2023.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import Foundation
import Charts // TODO: TODO

struct GameOperationStatusView: View {
    @Binding var isPresented: Bool
    @Binding var operation: GameOperation
    @Bindable private var operationManager: GameOperationManager = .shared

    let estimatedTimeRemainingFormatter: DateComponentsFormatter = {
        let formatter: DateComponentsFormatter = .init()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack { // wrap in VStack to prevent padding from callers being applied within the view
            if operation.isExecuting {
                Text(operation.description)
                    .font(.title)
                    .bold()

                Form {
                    HStack {
                        Label("Progress", systemImage: "progress.indicator")

                        Spacer()

                        ProgressView(value: operation.progressKVOBridge.fractionCompleted)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text(operation.progressKVOBridge.fractionCompleted.formatted(.percent))
                    }

                    // Chunks, not files. legendary's `Progress: X% (a/b)` counts chunk tasks, and
                    // labelling that "Files" read as a game made of tens of thousands of small files
                    // — which sent a slow-download diagnosis in the wrong direction. Shown only when
                    // something reports it: GOG does not, and "(0/0)" said nothing.
                    if operation.type.modifiesFiles, let total = operation.progressKVOBridge.fileTotalCount, total > 0 {
                        HStack {
                            Label("Chunks", systemImage: "square.stack.3d.up")

                            Spacer()

                            Text("\(operation.progressKVOBridge.fileCompletedCount ?? 0) of \(total)")
                        }
                    }

                    if let estimatedTimeRemaining = operation.progressKVOBridge.estimatedTimeRemaining {
                        HStack {
                            Label("Estimated Time Remaining", systemImage: "clock")

                            Spacer()

                            Text(estimatedTimeRemainingFormatter.string(from: estimatedTimeRemaining) ?? "Unknown")
                        }
                    }

                    if let throughput = operation.progressKVOBridge.throughput {
                        HStack {
                            Label("Throughput", systemImage: "arrow.up.arrow.down")

                            Spacer()

                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(throughput), countStyle: .file))/s")
                        }
                    }

                    // What explains a dip, read as a pair. Full cache and fast disk writes: the
                    // disk is the limit. Full cache and disk writes near zero: waiting on one slow
                    // chunk, so the connection. Low cache and a low speed: the connection.
                    if let cache = operation.progressKVOBridge.downloadCacheUsage {
                        HStack {
                            Label("Download Cache", systemImage: "memorychip")

                            Spacer()

                            Text(ByteCountFormatter.string(fromByteCount: cache, countStyle: .memory))
                        }
                    }

                    if let disk = operation.progressKVOBridge.diskWriteThroughput {
                        HStack {
                            Label("Writing to Disk", systemImage: "internaldrive")

                            Spacer()

                            Text("\(ByteCountFormatter.string(fromByteCount: disk, countStyle: .file))/s")
                        }
                    }
                }
                .portalForm()
            } else {
                ContentUnavailableView(
                    "This operation isn't currently running.",
                    systemImage: "externaldrive.badge.checkmark"
                )
            }

            HStack {
                Button("Close", action: { isPresented = false })
                    .buttonStyle(.portalProminent)
            }
            .frame(maxWidth: 750)
        }
    }
}

#Preview {
    GameOperationStatusView(isPresented: .constant(true), operation: .constant(.init(game: placeholderGame(type: Game.self), type: .install, function: { _ in })))
        .padding()
}
