//
//  ContainerCreation.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 29/1/2024.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import SwordRPC

struct ContainerCreationView: View {
    @Binding var isPresented: Bool

    @State private var containerName: String = "My Container"
    @State private var containerURL: URL = Wine.containersDirectory!

    @State private var isContainerURLFileImporterPresented: Bool = false

    /// Which Wine build the new prefix is created by.
    ///
    /// Previously there was no choice: every container was booted by the bundled engine, and
    /// a container is effectively married to its runtime — Wine migrates a prefix forward on
    /// first run and has no downgrade path. So the only way to get a prefix on a newer Wine
    /// was to let the provisioner make one, and the only way to name it was to accept the
    /// name the provisioner chose.
    @State private var runtimeID: String = Runtime.bundled.id
    @State private var availableRuntimes: [Runtime] = []

    @State private var isBooting: Bool = false
    @State private var isCancellationAlertPresented: Bool = false
    
    @State private var bootErrorDescription: String = String(localized: "Unknown Error.")
    @State private var isBootFailureAlertPresented: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                Text("NEW CONTAINER")
                    .font(Theme.Text.heroEyebrow)
                    .tracking(1.2)
                    .foregroundStyle(.secondary)

                Text("A fresh Windows installation")
                    .font(.system(.title2, weight: .bold))

                Text("""
                    Its own registry, its own C: drive, and its own Wine. Games are assigned to \
                    one automatically — this is for when you want a separate one.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.xlarge)

            Divider()

            Form {
                TextField("Name", text: $containerName)

                if nameIsTaken {
                    Label("A container is already called that.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Wine build", selection: $runtimeID) {
                    ForEach(availableRuntimes) { runtime in
                        Text(runtime.description).tag(runtime.id)
                    }
                }
                .task {
                    availableRuntimes = Runtime.discoverAll()
                    // The newest build this project ships is the default here as everywhere;
                    // the engine only when nothing else is installed.
                    runtimeID = Runtime.newestManagedByMythic()?.id ?? Runtime.bundled.id
                }
                .help("""
                    Wine upgrades a container the first time it runs it and can't downgrade it \
                    again, so this can't be changed back later.
                    """)

                HStack {
                    VStack(alignment: .leading) {
                        Text("Location")

                        Text(containerURL.prettyPath)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    
                    if !FileLocations.isWritableFolder(url: containerURL) {
                        Image(systemName: "exclamationmark.triangle")
                            .symbolVariant(.fill)
                            .help("Folder is not writable.")
                    }
                    
                    Button("Browse...") {
                        isContainerURLFileImporterPresented = true
                    }
                    .fileImporter(
                        isPresented: $isContainerURLFileImporterPresented,
                        allowedContentTypes: [.folder]
                    ) { result in
                        if case .success(let url) = result {
                            containerURL = url
                        }
                    }
                }
            }
            .portalForm()
            
            HStack {
                Button("Cancel", role: .cancel) {
                    if isBooting {
                        isCancellationAlertPresented = true
                    } else {
                        isPresented = false
                    }
                }
                .alert(isPresented: $isCancellationAlertPresented) {
                    Alert(
                        title: .init("Are you sure you want to cancel container creation?"),
                        message: .init("This will cancel \"\(containerName)\"'s creation."),
                        primaryButton: .destructive(.init("OK")),
                        secondaryButton: .cancel()
                    )
                }
                
                Spacer()

                if isBooting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(0.5)
                }

                Button("Done") {
                    Task(priority: .userInitiated) {
                        withAnimation { isBooting = true }
                        do {
                            // `nil` is how a container says "the bundled engine", so that
                            // every prefix created before runtimes existed still resolves.
                            var settings: Wine.Container.Settings = .init()
                            settings.runtimeID = runtimeID == Runtime.bundled.id ? nil : runtimeID

                            _ = try await Wine.createContainer(baseURL: containerURL,
                                                               name: containerName,
                                                               settings: settings)
                            withAnimation { isBooting = false }
                            isPresented = false
                        } catch {
                            bootErrorDescription = error.localizedDescription
                            withAnimation { isBooting = false }
                            isBootFailureAlertPresented = true
                        }
                    }
                }
                .buttonStyle(.portalProminent)
                .disabled(isBooting)
                .disabled(!FileLocations.isWritableFolder(url: containerURL))
                .disabled(nameIsTaken)
            }
            .padding()
        }
        
        .alert(isPresented: $isBootFailureAlertPresented) {
            Alert(
                title: .init("Failed to boot \"\(containerName)\"."),
                message: .init(bootErrorDescription)
            )
        }
        
        .task(priority: .background) {
            discordRPC.setPresence({
                var presence: RichPresence = .init()
                presence.details = "Currently creating container \"\(containerName)\""
                presence.state = "Creating a container"
                presence.timestamps.start = .now
                presence.assets.largeImage = "macos_512x512_2x"
                
                return presence
            }())
        }
    }
}

private extension ContainerCreationView {
    var nameIsTaken: Bool {
        Wine.containerURLs.contains { $0.lastPathComponent == containerName }
    }
}

#Preview {
    ContainerCreationView(isPresented: .constant(true))
        .sheetSurface(minWidth: 640, minHeight: 440)
}
