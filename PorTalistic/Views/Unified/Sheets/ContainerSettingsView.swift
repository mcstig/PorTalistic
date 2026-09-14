//
//  ContainerSettings.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 7/2/2024.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI

struct ContainerSettingsView: View {
    @Binding var selectedContainerURL: URL?
    var withPicker: Bool

    @ObservedObject private var variables: VariableManager = .shared

    @State private var containerScope: Wine.Container.Scope = .individual

    @State private var retinaMode: Bool = Wine.Container.Settings().retinaMode
    @State private var modifyingRetinaMode: Bool = true // keep progressview displayed until async fetching is complete
    @State private var retinaModeSuccess: Bool?

    @State private var commandStreamThread: Bool = true
    @State private var modifyingCommandStreamThread: Bool = true // keep the progressview up until the fetch lands
    @State private var commandStreamThreadSuccess: Bool?

    @State private var isDXVKDisclaimerPresented: Bool = false
    @State private var modifyingDXVK: Bool = false
    @State private var dxvkSuccess: Bool?

    @State private var availableRuntimes: [Runtime] = []

    @State private var windowsVersion: Wine.WindowsVersion = Wine.Container.Settings().windowsVersion
    @State private var modifyingWindowsVersion: Bool = true // keep progressview displayed until async fetching is complete
    @State private var windowsVersionSuccess: Bool?

    private func fetchCommandStreamThreadStatus() async {
        guard let selectedContainerURL else { return }

        let fetched = try? await Wine.getCommandStreamThread(containerURL: selectedContainerURL)

        // Separated, as above, so both updates don't land in one render pass.
        await MainActor.run { commandStreamThread = fetched ?? true }
        await MainActor.run { withAnimation { modifyingCommandStreamThread = false } }
    }

    private func fetchRetinaModeStatus() async {
        guard let selectedContainerURL else { return }
        
        do {
            let fetchedRetinaMode = try await Wine.getRetinaMode(containerURL: selectedContainerURL)
            
            await MainActor.run(body: { retinaMode = fetchedRetinaMode })
            // intentionally separated, to prevent both variable updates from occuring during the same render cycle
            await MainActor.run {
                withAnimation {
                    modifyingRetinaMode = false
                }
            }
        } catch {
            retinaModeSuccess = false
        }
    }

    private func fetchWindowsVersion() async {
        guard let selectedContainerURL else { return }

        do {
            if let fetchedWindowsVersion = try await Wine.getWindowsVersion(containerURL: selectedContainerURL) {
                await MainActor.run(body: { windowsVersion = fetchedWindowsVersion })
                // intentionally separated, to prevent both variable updates from occuring during the same render cycle
                await MainActor.run {
                    withAnimation {
                        modifyingWindowsVersion = false
                    }
                }
            }
        } catch {
            windowsVersionSuccess = false
        }
    }

    var body: some View {
        if withPicker {
            if variables.getVariable("booting") != true {
                Picker("Current Container", selection: $selectedContainerURL) {
                    ForEach(Wine.containerObjects) { container in
                        Text(container.name)
                            .tag(container.url)
                    }
                }
            } else {
                HStack {
                    Text("Current Container")
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }

        if let selectedContainerURL,
           let container = try? Wine.getContainerObject(at: selectedContainerURL) {
            Group {
                Toggle("Performance HUD", isOn: Binding(
                    get: { container.settings.metalHUD },
                    set: { container.settings.metalHUD = $0 }
                ))
                .disabled(variables.getVariable("booting") == true)

                Toggle("Retina Mode", isOn: $retinaMode)
                    .disabled(variables.getVariable("booting") == true)
                    .task(priority: .high) {
                        // asynchronously fetch retina mode status upon view presentation
                        await fetchRetinaModeStatus()
                    }
                    .withOperationStatus(
                        operating: $modifyingRetinaMode,
                        successful: $retinaModeSuccess,
                        observing: $retinaMode,
                        placement: .leading
                    ) {
                        try? await Wine.toggleRetinaMode(containerURL: container.url, toggle: retinaMode)
                        container.settings.retinaMode = retinaMode
                        retinaModeSuccess = true
                    }

                Toggle("Enhanced Sync (MSync)", isOn: Binding(
                    get: { container.settings.msync },
                    set: { container.settings.msync = $0 }
                ))
                .disabled(variables.getVariable("booting") == true)

                Toggle("Direct3D Command Stream (CSMT)", isOn: $commandStreamThread)
                    .disabled(variables.getVariable("booting") == true)
                    .task(priority: .high) { await fetchCommandStreamThreadStatus() }
                    .withOperationStatus(
                        operating: $modifyingCommandStreamThread,
                        successful: $commandStreamThreadSuccess,
                        observing: $commandStreamThread,
                        placement: .leading
                    ) {
                        try? await Wine.setCommandStreamThread(containerURL: container.url,
                                                               enabled: commandStreamThread)
                        container.settings.commandStreamThread = commandStreamThread
                        commandStreamThreadSuccess = true
                    }
                    .help("""
                        Lets wined3d do its graphics work on its own thread. Usually faster, \
                        and the first thing to turn off when a game that uses wined3d crashes \
                        or hangs. Games running through DXVK or D3DMetal aren't affected.
                        """)

                Toggle("Advanced Vector Extensions (AVX2)", isOn: Binding(
                    get: { container.settings.avx2 },
                    set: { container.settings.avx2 = $0 }
                ))
                .disabled({
                    if #available(macOS 15.0, *) {
                        return false
                    }
                    return true
                }())
                .help({
                    guard #unavailable(macOS 15.0) else { return "" }
                    return "AVX2 is only supported on macOS Sequoia (15) or later."
                }())

                Toggle("DXVK", isOn: Binding(
                    get: { container.settings.dxvk },
                    set: { _ in
                        isDXVKDisclaimerPresented = true
                    }
                ))
                .withOperationStatus(
                    operating: $modifyingDXVK,
                    successful: $dxvkSuccess,
                    observing: .constant(false),
                    placement: .leading,
                    action: { /* handled by alert presentation */ }
                )
                .alert("Quit games running in this container?",
                       isPresented: $isDXVKDisclaimerPresented) {
                    Button("OK", role: .destructive) {
                        Task(priority: .userInitiated) {
                            modifyingDXVK = true
                            defer { modifyingDXVK = false }

                            do {
                                if container.settings.dxvk {
                                    try await Wine.boot(at: container.url, parameters: .update)
                                } else {
                                    try await Wine.DXVK.install(toContainerAtURL: container.url)
                                }
                                container.settings.dxvk.toggle()
                                dxvkSuccess = true
                            } catch {
                                dxvkSuccess = false
                            }
                        }
                    }

                    Button("Cancel", role: .cancel, action: {})
                } message: {
                    Text("""
                        To toggle DXVK, \(Branding.name) must quit all games currently running in this container.
                        Additionally, D3DMetal will be disabled.
                        
                        Toggling DXVK may impact compatibility positively or negatively.
                        """)
                }

                Toggle("Asynchronous DXVK", isOn: Binding(
                    get: { container.settings.dxvkAsync },
                    set: { container.settings.dxvkAsync = $0 }
                ))
                .disabled(!container.settings.dxvk || modifyingDXVK)

                Picker("Wine Runtime", selection: Binding(
                    get: { container.settings.runtimeID ?? Runtime.bundled.id },
                    set: { newValue in
                        container.settings.runtimeID = (newValue == Runtime.bundled.id) ? nil : newValue

                        // The prefix's running wineserver still speaks the old runtime's
                        // protocol, and a wine binary that disagrees with it fails on stderr
                        // and nowhere else. Retire it now, while the user is here and
                        // expecting the change to take effect.
                        let containerURL = container.url
                        Task.detached(priority: .utility) {
                            await Wine.shutdownPrefix(at: containerURL)
                        }
                    }
                )) {
                    ForEach(availableRuntimes) { runtime in
                        Text(runtime.description).tag(runtime.id)
                    }
                }
                .task { availableRuntimes = Runtime.discoverAll() }
                .help("""
                    Which Wine build runs this container. Newer builds run newer software                     but drop D3DMetal; the bundled engine has D3DMetal but is older.
                    """)

                if let selected = availableRuntimes.first(where: { $0.id == (container.settings.runtimeID ?? Runtime.bundled.id) }),
                   !selected.isCompatible(withPrefixCreatedBy: .bundled) {
                    Label("""
                        This container was set up with an older Wine. Wine upgrades a container                         when it first runs and can't downgrade it again, so switching back may                         not work — make a fresh container if something breaks.
                        """, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Windows Version", selection: $windowsVersion) {
                    ForEach(Wine.WindowsVersion.allCases, id: \.self) { version in
                        Text("Windows® \(version.rawValue)").tag(version)
                    }
                }
                .task(priority: .high) {
                    // asynchronously fetch windows version upon view presentation
                    await fetchWindowsVersion()
                }
                .withOperationStatus(
                    operating: $modifyingWindowsVersion,
                    successful: $windowsVersionSuccess,
                    observing: $windowsVersion,
                    placement: .leading
                ) {
                    try await Wine.setWindowsVersion(containerURL: container.url, version: windowsVersion)
                    container.settings.windowsVersion = windowsVersion
                    windowsVersionSuccess = true
                }
            }
            .disabled(!Engine.isInstalled)
            .id(selectedContainerURL)
        } else if let selectedContainerURL,
                  Wine.containerExists(at: selectedContainerURL) {
            ContentUnavailableView(
                "Unable to retrieve container settings.",
                systemImage: "folder.badge.questionmark",
                description: Text("""
                This container (\(selectedContainerURL.prettyPath)) exists on disk,
                but the settings are inaccessible or corrupted.
                If this persists, please delete this container and create a new one.
                """)
            )
        } else {
            ContentUnavailableView(
                "Unable to locate container.",
                systemImage: "questionmark.folder",
                description: Text("""
                The container URL provided is invalid.
                If this container is not stored on an external device,
                Please remove it from \(Branding.name).
                """)
            )
        }
    }
}

#Preview {
    Form {
        ContainerSettingsView(
            selectedContainerURL: Binding(
                get: { Wine.containerURLs.first },
                set: { _ in }
            ),
            withPicker: true
        )
    }
    .formStyle(.grouped)
}
