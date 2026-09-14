//
//  ContainersView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 12/9/2023.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import SwordRPC

struct ContainersView: View {
    @State private var isContainerCreationViewPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Label("Wine containers", systemImage: "cube")
                    .font(Theme.Text.sectionTitle)

                Text("Each container is a separate Windows installation with its own registry and its own C: drive. \(Branding.name) assigns games to one that suits them; you rarely need to touch these.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Theme.Spacing.small)

                ContainerListView()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(Theme.Spacing.xlarge)
        }
        .navigationTitle("Containers")
        .standardTitleBar()

        .task(priority: .background) {
            discordRPC.setPresence({
                var presence: RichPresence = .init()
                presence.details = "Managing their Windows® Instances"
                presence.state = "Managing containers"
                presence.timestamps.start = .now
                presence.assets.largeImage = "macos_512x512_2x"

                return presence
            }())
        }

        .toolbar {
            if Engine.isInstalled {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isContainerCreationViewPresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add a container")
                }

                if let containersDirectory = Wine.containersDirectory {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            NSWorkspace.shared.open(containersDirectory)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Open Containers directory")
                    }
                }
            }
        }
        .id(isContainerCreationViewPresented)

        .sheet(isPresented: $isContainerCreationViewPresented) {
            ContainerCreationView(isPresented: $isContainerCreationViewPresented)
                .brandedSurface()
        }
    }
}

#Preview {
    ContainersView()
}
