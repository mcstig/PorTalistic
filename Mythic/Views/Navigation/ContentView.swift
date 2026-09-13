//
//  ContentView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 8/9/2023.
//
//  Reference
//  https://github.com/1998code/SwiftUI2-MacSidebar
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import SemanticVersion

struct ContentView: View {
    @EnvironmentObject var networkMonitor: NetworkMonitor
    
    @ObservedObject private var updateController: SparkleUpdateController = .shared
    @Bindable private var operationManager: GameOperationManager = .shared

    @State private var appVersion: String = .init()
    @State private var buildNumber: Int = 0
    
    @State private var engineVersion: SemanticVersion?
    
    var body: some View {
        NavigationSplitView(
            sidebar: {
                List {
                    Section {
                        NavigationLink(destination: HomeView()) {
                            Label("Home", systemImage: "house")
                                .help("Everything in one place")
                        }
                        
                        NavigationLink(destination: StoreView()) {
                            Label("Store", systemImage: "bag")
                                .help("Purchase new games from Epic")
                        }
                    }

                    // One shelf per storefront. They are installed, updated,
                    // launched and broken in completely different ways, so a single list
                    // that mixes them means every action has to be qualified by "…but which
                    // kind of game is this?" — for the user and for the code.
                    Section {
                        NavigationLink(destination: LibraryView()) {
                            Label("All Games", systemImage: "books.vertical")
                                .help("Every game, from every storefront")
                        }

                        NavigationLink(destination: LibraryView(storefront: .epicGames)) {
                            Label("Epic Games", systemImage: "gamecontroller")
                                .help("Games from your Epic Games library")
                        }

                        NavigationLink(destination: LibraryView(storefront: .gog)) {
                            Label("GOG", systemImage: "building.columns")
                                .help("Games from your GOG library")
                        }

                        if Game.Storefront.steam.isAvailable {
                            NavigationLink(destination: LibraryView(storefront: .steam)) {
                                Label("Steam", systemImage: "cloud")
                                    .help("Games installed through the Steam client")
                            }
                        }

                        NavigationLink(destination: LibraryView(storefront: .local)) {
                            Label("Local", systemImage: "internaldrive")
                                .help("Games you added from your own disk")
                        }
                    } header: {
                        Text("Library")
                    }

                    
                    Section {
                        NavigationLink(destination: ContainersView()) {
                            Label("Containers", systemImage: "cube")
                                .help("Manage containers for Windows® applications")
                        }
                        
                        Button("Support", systemImage: "questionmark.bubble") {
                            SupportWindowController.show()
                        }
                        .help("Get support")
                        .buttonStyle(.plain)
                        
                        NavigationLink(destination: AccountsView()) {
                            Label("Accounts", systemImage: "person.2")
                                .help("View all currently signed in accounts")
                        }
                    } header: {
                        Text("Management")
                    }
                }

                // separate downloads view from main list because alignment doesn't work within the main list
                if !operationManager.queue.isEmpty {
                    List { // must wrap in a list to have the same styling as the other links
                        NavigationLink(destination: OperationsView()) {
                            Label("Operations", systemImage: "progress.indicator")
                                .help("View all active game operations")
                        }
                    }
                    .frame(maxHeight: 40)
                    .scrollDisabled(true)
                    .scrollIndicators(.hidden)
                }
                
#if DEBUG
                VStack {
                    if let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                       let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                       let mythicVersion: SemanticVersion = .init("\(shortVersion)+\(bundleVersion)") {
                        Text("Mythic \(mythicVersion.prettyString)")
                    }
                    
                    if let engineVersion {
                        Text("Mythic Engine \(engineVersion.prettyString)")
                    }
                }
                .task { @MainActor in
                    engineVersion = await Engine.installedVersion
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom)
#endif // DEBUG

                switch updateController.state {
                case .updateAvailable:
                    updateBlock("Update Available", buttonText: "Show More") {
                        updateController.checkForUpdates(userInitiated: true)
                    }
                case .readyToRelaunch(let acknowledgement):
                    updateBlock("Update Ready", buttonText: "Relaunch") {
                        acknowledgement(.update)
                    }
                default:
                    EmptyView()
                }
            }, detail: {
                HomeView()
            }
        )
        .toolbar {
            ToolbarItem(placement: .status) {
                if !networkMonitor.isConnected {
                    Image(systemName: "network")
                        .symbolVariant(.slash)
                        .help("Mythic is not connected to the internet.")
                }
            }
        }
    }

    @ViewBuilder
    private func updateBlock(_ title: String, buttonText: String, action: @escaping () -> Void) -> some View {
        VStack {
            Label(title, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(action: action, label: {
                Text(buttonText)
                    .frame(maxWidth: .infinity)
            })
            .buttonStyle(.borderedProminent)
            .clipShape(.capsule)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ContentView()
        .environmentObject(NetworkMonitor.shared)
}
