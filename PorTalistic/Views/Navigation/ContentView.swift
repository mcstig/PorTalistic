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

    /// The sidebar, drawn rather than delegated.
    ///
    /// This was a `List(selection:)`, and that cost two things that looked like one bug.
    ///
    /// The selection colour is the system accent and `.tint` does not override it, so on a
    /// machine whose accent is red the selected row in a violet app was red. And `List` on
    /// macOS is an `NSTableView`: it reuses its rows, and it does not re-evaluate a row's
    /// content when something outside that row's identity changes — so the tinted tile that
    /// was *also* meant to indicate selection stayed lit on whichever row had it last. The
    /// system highlight moved and the drawn one didn't, which reads as a highlight stuck on
    /// the previous item.
    ///
    /// A `ScrollView` of buttons has neither problem: nothing is reused, every row reads
    /// `selection` as it draws, and the pill is the app's own violet because the app draws
    /// it.
    ///
    /// - Note: what this gives up is `List`'s arrow-key navigation between rows. Worth
    ///   restoring with `onMoveCommand` on a focusable container.
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                row(.home, title: String(localized: "Home"), systemImage: "house",
                    tint: Theme.Palette.brand,
                    help: String(localized: "Everything in one place"))
                row(.store, title: String(localized: "Store"), systemImage: "bag",
                    tint: Theme.Palette.brand,
                    help: String(localized: "Purchase new games from Epic"))

                sectionHeader(String(localized: "Library"))

                // One shelf per storefront. They are installed, updated, launched and broken
                // in completely different ways, so a single list that mixes them means every
                // action has to be qualified by "…but which kind of game is this?" — for the
                // user and for the code.
                row(.library(nil), title: String(localized: "All Games"), systemImage: "square.grid.2x2",
                    tint: Theme.Palette.brandSecondary,
                    help: String(localized: "Every game, from every storefront"),
                    count: gameDataStore.library.count)

                ForEach(Game.Storefront.available, id: \.self) { storefront in
                    row(.library(storefront),
                        title: storefront.description,
                        systemImage: storefront.symbolName,
                        tint: storefront.tint,
                        help: String(localized: "Games from your \(storefront.description) library"),
                        count: gameDataStore.library.filter { $0.storefront == storefront }.count,
                        // A storefront you're signed out of looks exactly like an empty one
                        // from here, and the only way to find out was to open it.
                        needsAttention: storefront.usesAccount && !storefront.isSignedIn)
                }

                sectionHeader(String(localized: "Manage"))

                row(.containers, title: String(localized: "Containers"), systemImage: "cube",
                    tint: Theme.Palette.brandSecondary,
                    help: String(localized: "Manage containers for Windows® applications"))
                row(.accounts, title: String(localized: "Accounts"), systemImage: "person.2",
                    tint: Theme.Palette.brand,
                    help: String(localized: "View all currently signed in accounts"))

                // Support opens its own window, so it is never the selected destination.
                Button {
                    SupportWindowController.show()
                } label: {
                    rowContent(title: String(localized: "Support"),
                               systemImage: "questionmark.bubble",
                               tint: .secondary,
                               isSelected: false)
                }
                .buttonStyle(PortalRailButtonStyle(isSelected: false))
                .help("Get support")

                if !operationManager.queue.isEmpty {
                    sectionHeader(String(localized: "Activity"))

                    row(.operations,
                        title: String(localized: "Operations"),
                        systemImage: "arrow.down.circle",
                        tint: Theme.Palette.brandSecondary,
                        help: String(localized: "View all active game operations"),
                        count: operationManager.queue.count)
                }
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.bottom, Theme.Spacing.medium)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .navigationSplitViewColumnWidth(min: 214, ideal: 232, max: 300)
        .safeAreaInset(edge: .top, spacing: 0) { wordmark }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    /// The app, at the top of its own sidebar.
    ///
    /// The window used to begin with the word "Home" against the traffic lights and nothing
    /// else — no name, no mark, nothing to say which application you were looking at.
    ///
    /// Sized to be a masthead rather than the first row of the menu. At a 22-point mark and
    /// a `.subheadline` name it matched the rows below it almost exactly — same height, same
    /// weight, an icon at the same scale in the same column — so it read as another
    /// destination you could click. It is nearly twice that now, the name is `.title3` bold,
    /// and the mark carries a violet glow, which is both what separates it from the list and
    /// the one place in the window the portal gets to look like a portal.
    private var wordmark: some View {
        HStack(spacing: Theme.Spacing.medium) {
            BundleIconView()
                .frame(width: 38, height: 38)
                .shadow(color: Theme.Palette.brand.opacity(0.55), radius: 11, y: 1)

            Text(Branding.name)
                .font(.system(.title3, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.medium + 2)
        .padding(.top, Theme.Spacing.xsmall)
        .padding(.bottom, Theme.Spacing.large)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.top, Theme.Spacing.medium)
            .padding(.bottom, Theme.Spacing.xsmall)
    }

    @ViewBuilder
    private func row(_ item: SidebarItem,
                     title: String,
                     systemImage: String,
                     tint: Color,
                     help: String,
                     count: Int? = nil,
                     needsAttention: Bool = false) -> some View {
        let isSelected = selection == item

        Button {
            selection = item
        } label: {
            rowContent(title: title,
                       systemImage: systemImage,
                       tint: tint,
                       isSelected: isSelected,
                       count: count,
                       needsAttention: needsAttention)
        }
        .buttonStyle(PortalRailButtonStyle(isSelected: isSelected))
        .help(help)
    }

    /// A sidebar row.
    ///
    /// The symbol sits in a tinted tile rather than floating beside the text, which is what
    /// lets a storefront carry its own colour: four monochrome glyphs in a column are four
    /// things to read, where four coloured tiles are four things to recognise. On the
    /// selected row the tile goes to white-on-violet, because a coloured tile inside a
    /// violet pill is two colours arguing.
    @ViewBuilder
    private func rowContent(title: String,
                            systemImage: String,
                            tint: Color,
                            isSelected: Bool,
                            count: Int? = nil,
                            needsAttention: Bool = false) -> some View {
        HStack(spacing: Theme.Spacing.small + 2) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .white : tint)
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Color.white.opacity(0.22))
                                         : AnyShapeStyle(tint.opacity(0.18)))
                }

            Text(title)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.xsmall)

            if needsAttention {
                Circle()
                    .fill(isSelected ? Color.white : .orange)
                    .frame(width: 6, height: 6)
                    .help("You're not signed in to \(title).")
            }

            if let count, count > 0 {
                Text(count, format: .number)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85))
                                                : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .padding(.horizontal, Theme.Spacing.small - 2)
                    .padding(.vertical, 1)
                    .background {
                        Capsule(style: .continuous)
                            .fill(isSelected ? AnyShapeStyle(Color.white.opacity(0.22))
                                             : AnyShapeStyle(HierarchicalShapeStyle.quaternary))
                    }
            }
        }
        .padding(.vertical, 1)
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
