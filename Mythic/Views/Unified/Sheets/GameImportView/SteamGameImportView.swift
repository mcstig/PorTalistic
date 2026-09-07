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
    @State private var openErrorDescription: String?
    @State private var isClientStarting = false
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
                            Task { await openClient() }
                        }
                        .disabled(isClientStarting)
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

                    if isClientStarting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Steam is starting. The first launch after an update can take a couple of minutes, and its window won't appear until it's finished.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let openErrorDescription {
                        // Bounded and scrollable on purpose. The sheet sizes itself to its
                        // content, so a long message doesn't wrap — it grows the window
                        // until the whole thing looks frozen.
                        ScrollView {
                            Label(openErrorDescription, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 90)
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

    /// Launches the real Steam client and stays with it until it either settles or dies.
    ///
    /// Steam's failure mode under Wine is to exit quietly: it spends two minutes on an
    /// update check that times out, then shuts down without ever drawing a window. To the
    /// user that is indistinguishable from a button that does nothing, which is exactly what
    /// this used to look like. So: report that it's starting, and if it exits, read its own
    /// bootstrap log back and say why.
    private func openClient() async {
        openErrorDescription = nil
        isClientStarting = true
        defer { isClientStarting = false }

        let process: Process
        do {
            process = try await Steam.openClient()
        } catch {
            // Never swallow this. A button that silently does nothing is worse than one
            // that fails loudly.
            openErrorDescription = [
                error.localizedDescription,
                (error as? LocalizedError)?.failureReason,
                (error as? LocalizedError)?.recoverySuggestion
            ].compactMap { $0 }.joined(separator: "\n")
            return
        }

        // Wait for the bootstrapper we spawned to finish handing off. Polling rather than a
        // termination handler keeps this on the main actor for the whole wait, so the
        // non-Sendable Process never crosses an isolation boundary.
        let deadline: Date = .now.addingTimeInterval(120)
        while process.isRunning, .now < deadline {
            try? await Task.sleep(for: .seconds(2))
        }

        // Its exit proves nothing: `steam.exe` starts the client and gets out of the way.
        // Ask the container whether Steam is actually up before calling this a failure.
        if await Steam.waitForClientToAppear() { return }

        if let containerURL = Steam.containerURL,
           let reason = Steam.lastClientError(containerURL: containerURL)
            ?? Steam.lastBootstrapError(containerURL: containerURL) {
            openErrorDescription = String(
                localized: "Steam closed before it finished starting. Its own log says: \(reason)"
            )
        } else {
            openErrorDescription = String(
                localized: "Steam didn't come up, and left nothing in its logs explaining why. Export Steam diagnostics from Settings for the full picture."
            )
        }
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
