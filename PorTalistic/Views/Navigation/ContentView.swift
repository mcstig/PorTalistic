//
//  ContentView.swift
//  PorTalistic
//
//  Created by vapidinfinity (esi) on 8/9/2023.
//  Rebuilt by Claude Opus 5 on 14/9/2026.
//
//  Reference
//  https://github.com/1998code/SwiftUI2-MacSidebar
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import Foundation
import SwiftUI
import SemanticVersion

/**
 The window: a sidebar, and whatever it points at.

 Rebuilt around selection instead of links. The sidebar used to be a `List` of
 `NavigationLink(destination:)`, which is the pre-value-based navigation shape, and it cost
 three things at once: nothing in the sidebar ever looked selected, so the window couldn't
 say where you were; the detail column had to be given `HomeView()` as a hard-coded default,
 so Home existed twice over; and there was no `NavigationStack` anywhere, so no card could
 push a page — which is why clicking a game did nothing.

 One `selection`, one `NavigationStack` in the detail column, and a `navigationDestination`
 for ``GameRoute``. That last line is the whole reason a game can have a page.
 */
struct ContentView: View {
    @EnvironmentObject var networkMonitor: NetworkMonitor

    @ObservedObject private var updateController: SparkleUpdateController = .shared
    @Bindable private var operationManager: GameOperationManager = .shared
    @Bindable private var gameDataStore: GameDataStore = .shared

    @State private var selection: SidebarItem = .home
    @State private var path: NavigationPath = .init()
    @State private var engineVersion: SemanticVersion?

    enum SidebarItem: Hashable {
        case home
        case store
        /// `nil` is the combined library.
        case library(Game.Storefront?)
        case containers
        case accounts
        case operations
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                destination
                    .navigationDestination(for: GameRoute.self) { route in
                        GameDetailView(route: route)
                    }
            }
            .toolbar {
                ToolbarItem(placement: .status) {
                    if !networkMonitor.isConnected {
                        Image(systemName: "network")
                            .symbolVariant(.slash)
                            .foregroundStyle(.orange)
                            .help("\(Branding.name) is not connected to the internet.")
                    }
                }
            }
        }
        // Changing shelf while three pages deep in a game would otherwise leave the old
        // page on screen, since the stack belongs to the column rather than the selection.
        .onChange(of: selection) { path = .init() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                row(.home, title: String(localized: "Home"), systemImage: "house",
                    help: String(localized: "Everything in one place"))
                row(.store, title: String(localized: "Store"), systemImage: "bag",
                    help: String(localized: "Purchase new games from Epic"))
            }

            // One shelf per storefront. They are installed, updated, launched and broken in
            // completely different ways, so a single list that mixes them means every action
            // has to be qualified by "…but which kind of game is this?" — for the user and
            // for the code.
            Section("Library") {
                row(.library(nil), title: String(localized: "All Games"), systemImage: "books.vertical",
                    help: String(localized: "Every game, from every storefront"),
                    count: gameDataStore.library.count)

                ForEach(Game.Storefront.available, id: \.self) { storefront in
                    row(.library(storefront),
                        title: storefront.description,
                        systemImage: storefront.symbolName,
                        help: String(localized: "Games from your \(storefront.description) library"),
                        count: gameDataStore.library.filter { $0.storefront == storefront }.count)
                }
            }

            Section("Management") {
                row(.containers, title: String(localized: "Containers"), systemImage: "cube",
                    help: String(localized: "Manage containers for Windows® applications"))
                row(.accounts, title: String(localized: "Accounts"), systemImage: "person.2",
                    help: String(localized: "View all currently signed in accounts"))

                Button("Support", systemImage: "questionmark.bubble") {
                    SupportWindowController.show()
                }
                .help("Get support")
                .buttonStyle(.plain)
            }

            // In the list, not bolted underneath it. This was previously a second `List`
            // pinned to a 40-point frame with scrolling disabled, purely to borrow the
            // sidebar's row styling — and it sat outside the selection, so the row it
            // contained could never look selected.
            if !operationManager.queue.isEmpty {
                Section {
                    row(.operations,
                        title: String(localized: "Operations"),
                        systemImage: "progress.indicator",
                        help: String(localized: "View all active game operations"),
                        count: operationManager.queue.count)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 196, ideal: 214, max: 280)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    @ViewBuilder
    private func row(_ item: SidebarItem,
                     title: String,
                     systemImage: String,
                     help: String,
                     count: Int? = nil) -> some View {
        // A tagged row rather than a `NavigationLink`: in a two-column split view the
        // sidebar has no stack of its own to push onto, and it is the `List`'s selection
        // that drives the detail column — and that draws the selected row as selected,
        // which the old link-based sidebar never did.
        HStack {
            Label(title, systemImage: systemImage)

            if let count, count > 0 {
                Spacer(minLength: Theme.Spacing.small)

                Text(count, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .help(help)
        .tag(item)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: Theme.Spacing.small) {
            switch updateController.state {
            case .updateAvailable:
                updateBlock(String(localized: "Update Available"),
                            buttonText: String(localized: "Show More")) {
                    updateController.checkForUpdates(userInitiated: true)
                }
            case .readyToRelaunch(let acknowledgement):
                updateBlock(String(localized: "Update Ready"),
                            buttonText: String(localized: "Relaunch")) {
                    acknowledgement(.update)
                }
            default:
                EmptyView()
            }

#if DEBUG
            // Debug-only, and out of the corner it used to sit in — two lines of grey text
            // hard against the sidebar's bottom-left edge, with no padding and no separator.
            VStack(spacing: 1) {
                if let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                   let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                   let version: SemanticVersion = .init("\(shortVersion)+\(bundleVersion)") {
                    Text("\(Branding.name) \(version.prettyString)")
                }

                if let engineVersion {
                    Text("Engine \(engineVersion.prettyString)")
                }

                Text(verbatim: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: ""))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .task { @MainActor in engineVersion = await Engine.installedVersion }
#endif // DEBUG
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.bottom, Theme.Spacing.small)
    }

    @ViewBuilder
    private func updateBlock(_ title: String, buttonText: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: Theme.Spacing.small) {
            Label(title, systemImage: "sparkles")
                .font(.footnote.weight(.medium))

            Button(action: action) {
                Text(buttonText)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.portalProminentCompact)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity)
        .cardSurface(cornerRadius: Theme.Radius.tile, elevated: false)
    }

    // MARK: Detail

    @ViewBuilder
    private var destination: some View {
        switch selection {
        case .home:                     HomeView()
        case .store:                    StoreView()
        case .library(let storefront):  LibraryView(storefront: storefront)
        case .containers:               ContainersView()
        case .accounts:                 AccountsView()
        case .operations:               OperationsView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(NetworkMonitor.shared)
        .frame(width: 1100, height: 700)
}
