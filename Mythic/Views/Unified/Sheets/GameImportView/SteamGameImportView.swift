//
//  SteamGameImportView.swift
//  Mythic
//
//  Created by Claude (Cowork) on 4/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import OSLog

/// Walks the user through setting up Mythic's Steam integration and importing
/// already-installed Steam games into the library. See ``Steam`` for the mechanics.
struct SteamGameImportView: View {
    @Bindable var gameDataStore: GameDataStore = .shared

    @Binding var isPresented: Bool

    private enum Stage {
        case checkingPreflight
        case blockedOnPreflight([LocalizedError])
        case needsClientInstall
        case installingClient(progress: Double)
        case ready
    }

    @State private var stage: Stage = .checkingPreflight
    @State private var isScanning = false
    @State private var scanErrorDescription: String?
    @State private var importedGames: [SteamGame] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Steam", systemImage: "storefront")
                .font(.title2)
                .bold()

            switch stage {
            case .checkingPreflight:
                ProgressView()
                    .task { await refreshStage() }

            case .blockedOnPreflight(let issues):
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue.errorDescription ?? String(localized: "An unknown issue is preventing Steam from being set up."),
                              systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    }

                    Button("Check Again") {
                        Task { await refreshStage() }
                    }
                }

            case .needsClientInstall:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mythic runs the real, official Steam client inside a dedicated container so that logins, cloud saves, achievements, and the overlay all work normally.")
                        .foregroundStyle(.secondary)

                    Button("Set Up Steam") {
                        Task { await installClient() }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .installingClient(let progress):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress) {
                        Text("Downloading and installing Steam…")
                    }
                }

            case .ready:
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Open Steam…") {
                            Task { try? await Steam.openClient() }
                        }
                        .help("Sign in and install/update games from within the real Steam client.")

                        Button {
                            Task { await scanLibrary() }
                        } label: {
                            if isScanning {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Scan for Installed Games", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(isScanning)
                    }

                    if let scanErrorDescription {
                        Label(scanErrorDescription, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }

                    if !importedGames.isEmpty {
                        Text("\(importedGames.count) game(s) found and added to your library:")
                            .font(.subheadline)

                        List(importedGames) { game in
                            Text(game.title)
                        }
                        .frame(minHeight: 120)
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 320)
    }

    private func refreshStage() async {
        let issues = await Preflight.diagnose(containerURL: Steam.containerURL)
        if !issues.isEmpty {
            stage = .blockedOnPreflight(issues)
        } else if !Steam.isClientInstalled {
            stage = .needsClientInstall
        } else {
            stage = .ready
        }
    }

    private func installClient() async {
        stage = .installingClient(progress: 0)
        do {
            try await Steam.installClient(onProgress: { progress in
                Task { @MainActor in stage = .installingClient(progress: progress) }
            })
            await refreshStage()
        } catch {
            stage = .blockedOnPreflight([GenericLocalizedError(message: error.localizedDescription)])
        }
    }

    private func scanLibrary() async {
        isScanning = true
        scanErrorDescription = nil
        defer { isScanning = false }

        do {
            try await gameDataStore.refreshFromStorefronts(.steam)
            importedGames = gameDataStore.library
                .compactMap { $0 as? SteamGame }
                .sorted(by: { $0.title < $1.title })
        } catch {
            scanErrorDescription = error.localizedDescription
        }
    }
}

private struct GenericLocalizedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

#Preview {
    SteamGameImportView(isPresented: .constant(true))
}
