//
//  SettingsView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 25/10/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import SwordRPC
import SemanticVersion

struct SettingsView: View {
    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                TabView {
                    Tab("General", systemImage: "gear") {
                        Form {
                            GeneralView()
                        }
                        .portalForm()
                    }

                    Tab("Views", systemImage: "document.viewfinder") {
                        Form {
                            ViewSettingsView()
                        }
                        .portalForm()
                    }

                    Tab("Launching", systemImage: "play") {
                        Form {
                            LaunchingView()
                        }
                        .portalForm()
                    }

                    Tab("Downloads", systemImage: "arrow.down.to.line") {
                        Form {
                            OperationsView()
                        }
                        .portalForm()
                    }

                    Tab("Updates", systemImage: "arrow.down.app") {
                        Form {
                            UpdatesView()
                        }
                        .portalForm()
                    }

                    Tab("Services", systemImage: "app.connected.to.app.below.fill") {
                        Form {
                            ServicesView()
                        }
                        .portalForm()
                    }

                    Tab("Engine", systemImage: "gamecontroller.circle") {
                        Form {
                            EngineView()
                        }
                        .portalForm()
                    }
                }
                .tabViewStyle(.automatic)
            } else { // macOS 15 unavailable ↓
                Form {
                    Section("General", content: { GeneralView() })
                    Section("Views", content: { ViewSettingsView() })
                    Section("Launching", content: { LaunchingView() })
                    Section("Operations", content: { OperationsView() })
                    Section("Updates", content: { UpdatesView() })
                    Section("Services", content: { ServicesView() })
                    Section("Engine", content: { EngineView() })
                }
                .portalForm()
            }
        }
        // Grouped `Form`s in a `TabView` are the right shape for a Settings window and stay
        // as they are; what they were missing is the app's ground and its buttons.
        .brandedSurface()
        .task(priority: .background) {
            discordRPC.setPresence({
                var presence: RichPresence = .init()
                presence.details = "Tweaking some settings"
                presence.state = "Configuring \(Branding.name)"
                presence.timestamps.start = .now
                presence.assets.largeImage = "macos_512x512_2x"

                return presence
            }())
        }
    }
}

extension SettingsView {
    struct GeneralView: View {
        @State private var isResetAlertPresented = false
        @State private var isResetSettingsAlertPresented = false

        var body: some View {
            Button("Reset \(Branding.name)", systemImage: "power.dotted") {
                isResetAlertPresented = true
            }
            .alert(
                "Reset \(Branding.name)?",
                isPresented: $isResetAlertPresented,
                actions: {
                    Button("OK", role: .destructive) {
                        if let bundleIdentifier = Bundle.main.bundleIdentifier {
                            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
                        }

                        if let appHome = Bundle.appHome {
                            try? FileManager.default.removeItem(at: appHome)
                        }

                        if let containersDirectory = Wine.containersDirectory {
                            try? FileManager.default.removeItem(at: containersDirectory)
                        }
                    }

                    Button("Cancel", role: .cancel) {  }
                },
                message: {
                    Text("This will erase every persistent setting and container, and cannot be undone.")
                }
            )

            Button("Reset settings to default", systemImage: "clock.arrow.circlepath") {
                isResetSettingsAlertPresented = true
            }
            .alert(
                "Reset \(Branding.name) Settings?",
                isPresented: $isResetSettingsAlertPresented,
                actions: {
                    Button("OK", role: .destructive) {
                        if let bundleIdentifier = Bundle.main.bundleIdentifier {
                            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
                        }
                    }

                    Button("Cancel", role: .cancel) {  }
                },
                message: {
                    Text("This will erase every persistent setting.")
                }
            )
        }
    }

    struct ViewSettingsView: View {
        @AppStorage(GameCardSize.storageKey) private var cardSize: GameCardSize = .regular
        @AppStorage("gameImageCardBlur") private var imageCardBlur: Double = 0.0
        @CodableAppStorage("gameListLayout") var gameListLayout: GameListViewModel.Layout = .grid
        @AppStorage("forceLegacyAppearance") private var forceLegacyAppearance: Bool = false

        var body: some View {
            Picker(selection: $cardSize) {
                ForEach(GameCardSize.allCases) { size in
                    Text(size.description).tag(size)
                }
            } label: {
                Label("Gamecard Size", systemImage: "square.resize")
                Text("Each step is 30%. Also on the library toolbar.")
                    .foregroundStyle(.secondary)
            }
            .pickerStyle(.segmented)

            Slider(value: $imageCardBlur, in: 0...20, step: 5) {
                Label("Gamecard Glow", systemImage: imageCardBlur <= 10 ? "sun.min" : "sun.max")
            }
            
            Picker("Game List Layout", systemImage: "macwindow", selection: $gameListLayout) {
                Label("List", systemImage: "rectangle.grid.1x3")
                    .tag(GameListViewModel.Layout.list)
                
                Label("Grid", systemImage: "square.grid.3x3")
                    .tag(GameListViewModel.Layout.grid)
            }
            .animation(.easeInOut, value: $gameListLayout.wrappedValue)

#if DEBUG
            // The app draws two appearances — Liquid Glass on macOS 26, a material with a
            // top-lit edge below it — and a machine can only ever show you one of them.
            // This forces the other, so the half that ships to everyone on Sonoma and
            // Sequoia can actually be looked at before it ships.
            Toggle("Draw the pre-macOS 26 appearance",
                   systemImage: "paintbrush.pointed",
                   isOn: $forceLegacyAppearance)
#endif
        }
    }

    struct LaunchingView: View {
        @AppStorage("minimiseOnGameLaunch") private var minimiseOnLaunch: Bool = false
        @AppStorage("quitOnAppClose") private var quitOnClose: Bool = false

        var body: some View {
            Toggle("Minimise to dock on game launch", systemImage: "dock.arrow.down.rectangle", isOn: $minimiseOnLaunch)
            Toggle("Force quit all games when \(Branding.name) closes", systemImage: "xmark.app", isOn: $quitOnClose)
        }
    }

    struct OperationsView: View {
        @AppStorage("installBaseURL") private var installBaseURL: URL = Bundle.appGames!
        @State private var isImporterPresented: Bool = false

        var body: some View {
            HStack {
                VStack(alignment: .leading) {
                    Label("Default Install Location", systemImage: "externaldrive.fill.badge.checkmark")
                    HStack {
                        Text(installBaseURL.prettyPath)
                            .foregroundStyle(.secondary)

                        if !FileLocations.isWritableFolder(url: installBaseURL) {
                            Image(systemName: "exclamationmark.triangle")
                                .symbolVariant(.fill)
                                .help("Folder is not writable.")
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing) {
                    Button("Browse...") {
                        isImporterPresented = true
                    }
                    .fileImporter(
                        isPresented: $isImporterPresented,
                        allowedContentTypes: [.folder]
                    ) { result in
                        if case .success(let url) = result {
                            installBaseURL = url
                        }
                    }
                    .buttonStyle(.portalProminent)

                    Button("Reset to Default") {
                        installBaseURL = Bundle.appGames!
                    }
                }
            }
        }
    }

    struct UpdatesView: View {
        @State private var isMythicUpdatesSectionExpanded: Bool = true
        @State private var isEngineUpdatesSectionExpanded: Bool = true

        @AppStorage("engineChannel") private var engineChannel: String = Engine.ReleaseChannel.stable.rawValue
        @State private var isEngineChannelChangeAlertPresented: Bool = false

        @State private var isEngineInstallationViewPresented: Bool = false
        @State private var engineInstallationError: Error?
        @State private var engineInstallationSuccessful: Bool = false

        @AppStorage("engineAutomaticallyChecksForUpdates") private var engineAutomaticallyChecksForUpdates: Bool = true

        var body: some View {
            Section(Branding.name, isExpanded: $isMythicUpdatesSectionExpanded) {
//                Toggle(
//                    "Automatically check for Mythic updates",
//                    systemImage: "arrow.down.app.dashed",
//                    isOn: Binding(
//                        get: { sparkleController.updater.automaticallyChecksForUpdates },
//                        set: { sparkleController.updater.automaticallyChecksForUpdates = $0 }
//                    )
//                )
//
//                Toggle(
//                    "Automatically download Mythic updates",
//                    systemImage: "arrow.down.app",
//                    isOn: Binding(
//                        get: { sparkleController.updater.automaticallyDownloadsUpdates },
//                        set: { sparkleController.updater.automaticallyDownloadsUpdates = $0 }
//                    )
//                )
            }

            Section("Mythic Engine", isExpanded: $isEngineUpdatesSectionExpanded) {
                Picker("Release Channel", systemImage: "app.badge.clock", selection: $engineChannel) {
                    Text("Stable")
                        .tag(Engine.ReleaseChannel.stable.rawValue)
                        .help("""
                            Existing stable features will be available in this channel.
                            This is the recommended stream for all users.
                            """)

                    Text("Preview")
                        .tag(Engine.ReleaseChannel.preview.rawValue)
                        .help("""
                            Experimental new features may be available in this channel, at the cost of stability.
                            Use at your own risk.
                            """)
                }
                .onChange(of: engineChannel) {
                    isEngineChannelChangeAlertPresented = true
                }
                .alert(
                    "Would you like to reinstall Mythic Engine?",
                    isPresented: $isEngineChannelChangeAlertPresented,
                    actions: {
                        Button("OK", role: .destructive) {
                            Task { @MainActor in
                                try? await Engine.remove()
                                isEngineInstallationViewPresented = true
                            }
                        }

                        Button("Cancel", role: .cancel) {  }
                    },
                    message: {
                        Text("""
                        To change Mythic Engine's release channel, it must be reinstalled.
                        If you choose not to, Mythic Engine will attempt to update to a 
                        newer version if it exists the next time it launches.
                        """)
                    }
                )
                .sheet(isPresented: $isEngineInstallationViewPresented) {
                    EngineInstallationView(
                        isPresented: $isEngineInstallationViewPresented,
                        installationError: $engineInstallationError,
                        installationComplete: $engineInstallationSuccessful
                    )
                    .padding()
                }

                Toggle("Automatically check for Mythic Engine updates", systemImage: "arrow.down.app.dashed", isOn: $engineAutomaticallyChecksForUpdates)
            }
        }
    }

    struct ServicesView: View {
        @AppStorage("discordRPC") private var discordRPCEnabled: Bool = true
        @State private var isServicesDiscordSectionExpanded: Bool = true
        @State private var isServicesEpicSectionExpanded: Bool = true
        @State private var isServicesSteamSectionExpanded: Bool = true
        @State private var isServicesRuntimesSectionExpanded: Bool = true

        @State private var installedRuntimes: [Runtime] = []
        @State private var installingRuntimeID: String?
        @State private var installStage: RuntimeInstaller.Stage?
        @State private var runtimeInstallError: String?
        @State private var repairingRuntimeID: String?
        @State private var runtimePendingRemoval: Runtime?

        private func remove(_ runtime: Runtime) {
            do {
                try RuntimeInstaller.remove(runtime)
                installedRuntimes = Runtime.discoverAll()
            } catch {
                runtimeInstallError = error.localizedDescription
            }
        }

        /// Adds the support libraries to a runtime installed before Mythic fetched them.
        private func repairRuntime(_ runtime: Runtime) async {
            repairingRuntimeID = runtime.id
            defer { repairingRuntimeID = nil }

            do {
                try await RuntimeInstaller.repairSupportLibraries(for: runtime)
                installedRuntimes = Runtime.discoverAll()
            } catch {
                runtimeInstallError = error.localizedDescription
            }
        }

        @State private var isCleaning: Bool = false
        @State private var isCleanupSuccessful: Bool?

        @State private var isEpicCloudSynchronising: Bool = false
        @State private var isEpicCloudSyncSuccessful: Bool?

        @State private var isOpeningSteam: Bool = false
        @State private var isOpeningSteamSuccessful: Bool?

        @State private var isExportingSteamDiagnostics: Bool = false
    @State private var isExportingSteamDiagnosticsSuccessful: Bool?
    @State private var isResettingSteamContainer: Bool = false
        @State private var isResettingSteamContainerSuccessful: Bool?
        @State private var isResetSteamContainerAlertPresented: Bool = false

        var body: some View {
            Section("Discord", isExpanded: $isServicesDiscordSectionExpanded) {
                Toggle("Display \(Branding.name) activity status on Discord", isOn: $discordRPCEnabled)
                    .onChange(of: discordRPCEnabled) { _, newValue in
                        if newValue {
                            _ = discordRPC.connect()
                        } else {
                            discordRPC.disconnect()
                        }
                    }
            }
            .disabled(!discordRPC.isDiscordInstalled)
            .help(discordRPC.isDiscordInstalled ? .init() : "Discord is not installed.")

            Section("Epic Games", isExpanded: $isServicesEpicSectionExpanded) {
                OperationButton(
                    "Clean Up Miscellaneous Caches",
                    systemImage: "bubbles.and.sparkles",
                    operating: $isCleaning,
                    successful: $isCleanupSuccessful
                ) {
                    // Not a bare `legendary cleanup`: the files it deletes include the
                    // `.resume` that lets an interrupted download carry on from where it
                    // stopped, so pressing this mid-install would quietly cost somebody their
                    // download. `cleanUpStaleData()` declines in that case, and says so by
                    // reporting failure here rather than a checkmark over nothing.
                    isCleanupSuccessful = await Legendary.cleanUpStaleData()
                }
                .help("Removes Epic metadata, manifests and temporary files that are no longer needed. Declines while a game is downloading: it would delete the files an interrupted download picks up from.")

                OperationButton(
                    "Manually Synchronise Cloud Saves",
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                    operating: $isEpicCloudSynchronising,
                    successful: $isEpicCloudSyncSuccessful
                ) {
                    let regex = try! Regex(#"Got [0-9]+ remote save game"#) // swiftlint:disable:this force_try
                    let result = await Legendary.synchroniseCloudSaves()

                    isEpicCloudSyncSuccessful = (try? regex.firstMatch(in: result?.standardError ?? "") != nil)
                }

                // TODO: potenially add manual cloud save deletion
            }

            if Game.Storefront.steam.isAvailable {
                Section("Steam", isExpanded: $isServicesSteamSectionExpanded) {
                    if Steam.isClientInstalled {
                        OperationButton(
                            "Open Steam Client",
                            systemImage: "storefront",
                            operating: $isOpeningSteam,
                            successful: $isOpeningSteamSuccessful
                        ) {
                            do {
                                try await Steam.openClient()
                                isOpeningSteamSuccessful = true
                            } catch {
                                isOpeningSteamSuccessful = false
                            }
                        }

                        OperationButton(
                            "Export Steam Diagnostics",
                            systemImage: "stethoscope",
                            operating: $isExportingSteamDiagnostics,
                            successful: $isExportingSteamDiagnosticsSuccessful
                        ) {
                            do {
                                let destination = try await Steam.exportDiagnostics()
                                isExportingSteamDiagnosticsSuccessful = true
                                NSWorkspace.shared.activateFileViewerSelecting([destination])
                            } catch {
                                isExportingSteamDiagnosticsSuccessful = false
                            }
                        }
                        .help("Collects the Steam container's logs and install state into a folder, for diagnosing launch failures.")

                        OperationButton(
                            "Reset Steam Container",
                            systemImage: "trash",
                            operating: $isResettingSteamContainer,
                            successful: $isResettingSteamContainerSuccessful
                        ) {
                            isResetSteamContainerAlertPresented = true
                        }
                        .alert("Reset the Steam container?", isPresented: $isResetSteamContainerAlertPresented) {
                            Button("Cancel", role: .cancel) { }
                            Button("Reset", role: .destructive) {
                                Task {
                                    do {
                                        if let containerURL = Steam.containerURL {
                                            try Wine.deleteContainer(containerURL: containerURL)
                                        }
                                        isResettingSteamContainerSuccessful = true
                                    } catch {
                                        isResettingSteamContainerSuccessful = false
                                    }
                                }
                            }
                        } message: {
                            Text("""
                            This deletes Steam's dedicated container, including the Steam client itself \
                            and every game installed inside it. Your Steam library and cloud saves aren't \
                            affected — reinstalling games afterward just re-downloads them through Steam. \
                            Use this if Steam or a game inside it becomes unreliable and reinstalling \
                            normally hasn't helped.
                            """)
                        }
                    } else {
                        Text("Steam hasn't been set up yet. Use Import Game > Steam from your library to set it up.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Wine Runtimes", isExpanded: $isServicesRuntimesSectionExpanded) {
                ForEach(installedRuntimes) { runtime in
                    HStack {
                        Image(systemName: runtime.isManagedByMythic ? "shippingbox.fill" : "shippingbox")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(runtime.name)
                            Text(runtime.version.map { "wine \($0.description)" } ?? String(localized: "unknown version"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !runtime.isManagedByMythic {
                            Text("Installed separately")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            if RuntimeInstaller.isMissingSupportLibraries(runtime) {
                                if repairingRuntimeID == runtime.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("Repair") {
                                        Task { await repairRuntime(runtime) }
                                    }
                                    .help("This runtime is missing the Unix libraries it links against, so it can't start Windows programs. Downloads and installs them.")
                                }
                            }

                            // Reinstalling is the only way back from a runtime that's been
                            // written into — by Mythic or by hand — so being able to install
                            // one without being able to remove it is a dead end.
                            Button("Remove", systemImage: "trash") {
                                runtimePendingRemoval = runtime
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.portalQuietCompact)
                            .foregroundStyle(.secondary)
                            .help("Deletes this runtime. Containers using it fall back to the bundled engine until you install it again.")
                        }
                    }
                }
                .alert("Remove \(runtimePendingRemoval?.name ?? String(localized: "this runtime"))?",
                       isPresented: .init(get: { runtimePendingRemoval != nil },
                                          set: { if !$0 { runtimePendingRemoval = nil } })) {
                    Button("Cancel", role: .cancel) { runtimePendingRemoval = nil }
                    Button("Remove", role: .destructive) {
                        if let runtimePendingRemoval { remove(runtimePendingRemoval) }
                        runtimePendingRemoval = nil
                    }
                } message: {
                    Text("""
                    Containers set to use it will run on the bundled engine until it's installed \
                    again. Nothing inside those containers is deleted.
                    """)
                }

                ForEach(RuntimeRelease.catalogue.filter { release in
                    !installedRuntimes.contains { $0.id == "managed:\(release.id)" }
                }) { release in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(release.name)
                                Text(release.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            Button("Install") {
                                install(release)
                            }
                            .disabled(installingRuntimeID != nil)
                        }

                        if installingRuntimeID == release.id {
                            HStack(spacing: 6) {
                                if case .downloading(let fraction) = installStage, let fraction {
                                    ProgressView(value: fraction)
                                } else {
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                Text(installStage?.localizedDescription ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let runtimeInstallError {
                    Text(runtimeInstallError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .task { refreshRuntimes() }
        }

        private func refreshRuntimes() {
            installedRuntimes = Runtime.discoverAll()
        }

        private func install(_ release: RuntimeRelease) {
            runtimeInstallError = nil
            installingRuntimeID = release.id

            Task {
                defer {
                    installingRuntimeID = nil
                    installStage = nil
                    refreshRuntimes()
                }

                do {
                    // Through the Provisioner, which may already be downloading this build for
                    // an installed game — see `Provisioner.installRuntime(_:onStage:)`.
                    try await Provisioner.shared.installRuntime(release) { stage in
                        Task { @MainActor in installStage = stage }
                    }
                } catch {
                    // Include the underlying reason: "didn't contain the files Mythic
                    // expected" alone isn't something anyone can act on, whereas naming
                    // the missing path is.
                    let reason = (error as? LocalizedError)?.failureReason
                    runtimeInstallError = [error.localizedDescription, reason]
                        .compactMap { $0 }
                        .joined(separator: "\n")
                }
            }
        }
    }

    struct EngineView: View {
        @State private var isForceQuitting: Bool = false
        @State private var isForceQuitSuccessful: Bool?

        @State private var isEngineRemoving: Bool = false
        @State private var isEngineRemovalSuccessful: Bool?

        @State private var isEngineRemovalAlertPresented: Bool = false

        @State private var isShaderCachePurging: Bool = false
        @State private var isShaderCachePurgeSuccessful: Bool?

        @State private var isAdvancedSectionExpanded: Bool = false

        @State private var engineVersion: SemanticVersion?

        @State private var isDXMTInstalling: Bool = false
        @State private var isDXMTInstallSuccessful: Bool?

        /// The runtime DXMT would be installed into: the newest one Mythic manages.
        ///
        /// Deliberately not "the newest available" — that list includes the Game Porting
        /// Toolkit, Whisky and Homebrew installs Mythic merely discovered, and those belong to
        /// other applications.
        private var dxmtTarget: Runtime? { .newestManagedByMythic() }

        var body: some View {
            if Engine.isInstalled {
                if let dxmtTarget {
                    if Wine.DXMT.isShippedByRuntime(dxmtTarget) {
                        // Nothing to offer, and offering it anyway invites replacing a working
                        // engine's own DXMT with one built against a different Wine.
                        Label("\(dxmtTarget.name) already has Direct3D 11 on Metal (DXMT).",
                              systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        OperationButton(
                            Wine.DXMT.isInstalled(in: dxmtTarget)
                                ? "Reinstall Direct3D 11 on Metal (DXMT) for \(dxmtTarget.name)"
                                : "Install Direct3D 11 on Metal (DXMT) for \(dxmtTarget.name)",
                            systemImage: "cpu",
                            operating: $isDXMTInstalling,
                            successful: $isDXMTInstallSuccessful
                        ) {
                            do {
                                try await Provisioner.shared.installDirect3DLayer(into: dxmtTarget)
                                isDXMTInstallSuccessful = true
                            } catch {
                                isDXMTInstallSuccessful = false
                            }
                        }
                        .help("Newer Wine has working networking but no Direct3D 11 on macOS; DXMT supplies it, which is what the Steam client and most Direct3D 11 games need.")
                    }
                }

                OperationButton(
                    "Force Quit Running Windows® Applications",
                    systemImage: "xmark.app",
                    operating: $isForceQuitting,
                    successful: $isForceQuitSuccessful
                ) {
                    do {
                        try Wine.killAll()
                        isForceQuitSuccessful = true
                    } catch {
                        isForceQuitSuccessful = false
                    }
                }

                OperationButton(
                    "Remove Mythic Engine",
                    systemImage: "gear.badge.xmark",
                    operating: $isEngineRemoving,
                    successful: $isEngineRemovalSuccessful
                ) {
                    isEngineRemovalAlertPresented = true
                }
                .alert(
                    "Are you sure you want to remove Mythic Engine?",
                    isPresented: $isEngineRemovalAlertPresented,
                    actions: {
                        Button("Remove", role: .destructive) {
                            Task { @MainActor in
                                do {
                                    try await Engine.remove()
                                    isEngineRemovalSuccessful = true
                                } catch {
                                    isEngineRemovalSuccessful = false
                                }
                            }
                        }

                        Button("Cancel", role: .cancel) {  }
                    },
                    message: {
                        Text("It'll have to be reinstalled in order to play Windows® games.")
                    }
                )

                Section("Advanced", isExpanded: $isAdvancedSectionExpanded) {
                    OperationButton(
                        "Purge D3DMetal Shader Cache",
                        systemImage: "square.stack.3d.up.slash",
                        operating: $isShaderCachePurging,
                        successful: $isShaderCachePurgeSuccessful
                    ) {
                        isShaderCachePurgeSuccessful = (try? Wine.purgeD3DMetalShaderCache()) != nil
                    }
                }

                Text("Mythic Engine \(engineVersion?.prettyString ?? "(Unknown Version)")")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                    .padding()
                    .task {
                        engineVersion = await Engine.installedVersion
                    }
            } else {
                Engine.NotInstalledView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
    }
}

#Preview {
    SettingsView()
}
