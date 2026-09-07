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
    @State private var isClientAlreadyRunning = false
    @State private var isRestartingClient = false
    @State private var isPinningClient = false
    @State private var pinStatusDescription: String?
    @State private var availablePins: [SteamClientPin] = []
    @State private var selectedPinID: String?
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
                        .disabled(isClientStarting || isRestartingClient)
                        .help("Sign in and install/update games from within the real Steam client.")

                        // Always offered, not just when Mythic believes Steam is running.
                        //
                        // The state this button exists to fix is exactly the state in which
                        // detection is least trustworthy: a client that died halfway leaves
                        // processes behind that `tasklist` may or may not report, and every
                        // subsequent "Open Steam…" quietly hands off to the wreckage instead
                        // of starting anything. Hiding the way out until Mythic is sure there
                        // is something to shut down gets it backwards.
                        Button("Restart Steam") {
                            Task { await restartClient() }
                        }
                        .disabled(isRestartingClient)
                        .help("Shut the container down completely and start Steam again.")

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

                    if isClientStarting || isRestartingClient {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(isRestartingClient
                                 ? "Shutting Steam down…"
                                 : "Steam is starting. The first launch after an update can take a couple of minutes, and its window won't appear until it's finished.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if isClientAlreadyRunning, !isRestartingClient {
                        Text("Steam is already running. If its window is missing or blank, restart it — closing Steam can leave part of it behind, and the next launch quietly hands over to that instead of opening.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Client version")
                                .font(.headline)

                            Spacer()

                            if let pinned = Steam.pinnedClient {
                                Text(pinned.name)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Current")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("Today's Steam interface doesn't render under Wine — it connects and runs, but draws nothing and closes itself. Installing an older client from the Internet Archive is what Wine and CrossOver users use instead. Builds around mid-2024 are the ones reported working; late-2025 builds have been tried here and don't. Valve retires old clients eventually, so if sign-in stops working, come back and try a newer one.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Picker("Install", selection: $selectedPinID) {
                                Text("Choose a build…").tag(String?.none)
                                ForEach(availablePins) { pin in
                                    Text(pin.name).tag(String?.some(pin.id))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                            .disabled(availablePins.isEmpty || isPinningClient)

                            Button("Install") {
                                guard let pin = availablePins.first(where: { $0.id == selectedPinID }) else { return }
                                Task { await pinClient(to: pin) }
                            }
                            .disabled(selectedPinID == nil || isPinningClient || isClientStarting)

                            if Steam.pinnedClient != nil {
                                Button("Use Current") {
                                    Task { await unpinClient() }
                                }
                                .help("Let Steam update itself back to the newest client.")
                                .disabled(isPinningClient || isClientStarting)
                            }
                        }
                        .task {
                            guard availablePins.isEmpty else { return }
                            availablePins = (try? await SteamClientPin.availableSnapshots()) ?? [.fallback]
                        }

                        if isPinningClient {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Downloading the archived client. This is a few hundred megabytes from the Internet Archive and is not quick.")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if let pinStatusDescription {
                            Text(pinStatusDescription)
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

        // Pressing Open when Steam is already up would spawn a bootstrapper that hands off
        // to the running instance and exits, which looks like nothing happening. Say so, and
        // offer the one thing that actually helps.
        if await Steam.isClientRunning() {
            isClientAlreadyRunning = true
            return
        }

        isClientAlreadyRunning = false
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

    /// Shuts Steam down and starts it again.
    ///
    /// The recovery path for the state where Steam is "running" only in the sense that
    /// something of it is still resident — no window, and every attempt to open it hands
    /// off to that remnant.
    private func restartClient() async {
        openErrorDescription = nil
        isRestartingClient = true

        do {
            try await Steam.quitClient()
        } catch {
            openErrorDescription = error.localizedDescription
        }

        isRestartingClient = false
        isClientAlreadyRunning = false

        await openClient()
    }

    /// Replaces the installed client with an archived build.
    private func pinClient(to pin: SteamClientPin) async {
        openErrorDescription = nil
        pinStatusDescription = nil
        isPinningClient = true
        defer { isPinningClient = false }

        do {
            try await Steam.installPinnedClient(pin)
            pinStatusDescription = String(localized: "Steam is now on the \(pin.name) client. Open Steam to sign in.")
        } catch {
            openErrorDescription = [
                error.localizedDescription,
                (error as? LocalizedError)?.failureReason,
                (error as? LocalizedError)?.recoverySuggestion
            ].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func unpinClient() async {
        openErrorDescription = nil
        pinStatusDescription = nil
        isPinningClient = true
        defer { isPinningClient = false }

        do {
            try await Steam.unpinClient()
            pinStatusDescription = String(localized: "Steam will update itself to the current client the next time it opens.")
        } catch {
            openErrorDescription = error.localizedDescription
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
