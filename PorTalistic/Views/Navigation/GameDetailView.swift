//
//  GameDetailView.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI
import AppKit
import OSLog
import SwordRPC

/// Where a game card leads.
///
/// A dedicated type rather than the bare `Game.ID` it wraps, so that `navigationDestination`
/// matches on something only a card can produce — a `String` route would collide with any
/// other string anyone ever pushes.
struct GameRoute: Hashable {
    let gameID: Game.ID
}

/**
 Everything the app knows about one game, on one page.

 Nothing led here before: clicking a card did nothing at all, and a game's facts were
 divided between a truncated badge on the card, a "…" menu, and a settings sheet you had to
 already know existed. The automatic runtime selection made that worse rather than better —
 the app now decides which Wine build and which graphics translation layer each game gets,
 and records *why* in ``RuntimeProfile/reasons``, and there was nowhere in the interface for
 any of it to appear. "Automatic, but not silent" needs a page to not be silent on.
 */
struct GameDetailView: View {
    let route: GameRoute

    @Bindable private var gameDataStore: GameDataStore = .shared

    /// Resolved from the store on every render rather than captured.
    ///
    /// A library refresh replaces game objects, so a page holding the instance it was pushed
    /// with would keep showing a game that has since been uninstalled, renamed, or dropped.
    private var game: Game? {
        gameDataStore.library.first { $0.id == route.gameID }
    }

    var body: some View {
        if let game {
            GameDetailContent(game: .constant(game))
                .id(game.id)
        } else {
            ContentUnavailableView(
                "This game is no longer in your library.",
                systemImage: "questionmark.folder",
                description: .init("It may have been removed from the storefront it came from.")
            )
        }
    }
}

private struct GameDetailContent: View {
    @Binding var game: Game

    @EnvironmentObject private var networkMonitor: NetworkMonitor

    @State private var profile: RuntimeProfile?
    @State private var sizeOnDisk: Int64?

    @State private var isSettingsPresented: Bool = false
    @State private var isUninstallPresented: Bool = false

    private static let heroHeight: CGFloat = 320

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xlarge) {
                hero

                VStack(alignment: .leading, spacing: Theme.Spacing.xlarge) {
                    compatibility
                    details
                }
                .padding(.horizontal, Theme.Spacing.xlarge)
                .padding(.bottom, Theme.Spacing.section)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(game.title)
        .gameSettingsSheet(game: $game, isPresented: $isSettingsPresented)
        .gameUninstallSheet(game: $game, isPresented: $isUninstallPresented)
        .task(id: game.id) { await load() }
        .task(priority: .background) {
            discordRPC.setPresence({
                var presence: RichPresence = .init()
                presence.details = "Looking at \(game.title)"
                presence.state = "Browsing"
                presence.timestamps.start = .now
                presence.assets.largeImage = "macos_512x512_2x"
                return presence
            }())
        }
    }

    // MARK: Hero

    private var hero: some View {
        GameArtwork(
            game: game,
            url: game.horizontalImageURL ?? game.verticalImageURL,
            orientation: .horizontal,
            cornerRadius: 0
        )
        .frame(height: Self.heroHeight)
        .artworkScrim(opacity: 0.96)
        .artworkFadesOut()
        .overlay(alignment: .bottomLeading) { heroContent }
        .clipped()
    }

    private var heroContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                if let storefront = game.storefront {
                    PortalBadge(storefront.description, systemImage: storefront.symbolName, tint: .white)
                }

                PortalBadge(game.installationState.description,
                            tint: isInstalled ? .green : .white)

                if case .installed(_, let platform) = game.installationState {
                    PortalBadge(platform.description, tint: .white)
                }
            }

            Text(game.title)
                .font(Theme.Text.heroTitle)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)

            HStack(spacing: Theme.Spacing.medium) {
                // The same control as a card's, so the primary action looks the same
                // wherever it is found.
                GameCard.ActionIconButton(game: $game, isOnHero: true)

                GameCard.MenuView(game: $game,
                                  isSettingsPresented: $isSettingsPresented,
                                  isUninstallPresented: $isUninstallPresented)
                    .buttonStyle(.portalQuietCompact)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(Theme.Spacing.small)
                    .floatingCapsule(interactive: true)

                GameCard.FavouriteToggle(game: $game)
            }
        }
        .padding(Theme.Spacing.xlarge)
    }

    private var isInstalled: Bool {
        if case .installed = game.installationState { return true }
        return false
    }

    // MARK: Compatibility

    @ViewBuilder
    private var compatibility: some View {
        if let profile {
            RuntimeProfilePanel(profile: profile)
        }
    }

    // MARK: Details

    private var details: some View {
        DetailPanel(title: String(localized: "Details"), systemImage: "info.circle") {
            VStack(spacing: 0) {
                if let lastLaunched = game.lastLaunched {
                    DetailRow(String(localized: "Last played"),
                              value: lastLaunched.formatted(date: .abbreviated, time: .shortened))
                }

                if let sizeOnDisk {
                    DetailRow(String(localized: "Size on disk"),
                              value: sizeOnDisk.formatted(.byteCount(style: .file)))
                }

                // Only for an installed game. `Game.containerURL` falls back to whichever
                // container happens to be first when a game hasn't got one, so an
                // uninstalled Epic game confidently reported that it runs in "Steam".
                if isInstalled,
                   let containerURL = game.containerURL,
                   let container = try? Wine.Container(knownURL: containerURL) {
                    DetailRow(String(localized: "Container"), value: container.name)
                    DetailRow(String(localized: "Wine build"),
                              value: Wine.runtime(forContainerAtURL: containerURL).name)
                }

                if case .installed(let location, _) = game.installationState {
                    DetailRow(String(localized: "Location"), value: location.prettyPath) {
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([location])
                        }
                        .buttonStyle(.portalQuietCompact)
                    }
                }

                DetailRow(String(localized: "Actions"), value: nil) {
                    HStack(spacing: Theme.Spacing.small) {
                        Button("Settings", systemImage: "gear") { isSettingsPresented = true }
                        GameCard.Buttons.UpdateButton(game: $game, withLabel: true)
                        GameCard.Buttons.VerificationButton(game: $game, withLabel: true)
                        Button("Uninstall", systemImage: "xmark.bin") { isUninstallPresented = true }
                    }
                    .buttonStyle(.portalCompact)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        profile = await Provisioner.shared.profile(for: game)

        guard case .installed(let location, _) = game.installationState else {
            sizeOnDisk = nil
            return
        }

        sizeOnDisk = await Task.detached(priority: .utility) {
            Self.allocatedSize(of: location)
        }.value
    }

    /// Bytes actually taken on disk, walked off the main actor.
    ///
    /// `.totalFileAllocatedSize` rather than `.fileSize`: a game directory is tens of
    /// thousands of small files, and the difference between logical and allocated size on
    /// those runs to gigabytes — the number the user compares against Finder is the
    /// allocated one.
    private nonisolated static func allocatedSize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.totalFileAllocatedSize else { continue }
            total += Int64(size)
        }
        return total
    }
}

// MARK: - Runtime profile

/**
 What the app decided about a game, and why.

 Shared by the game's page and its settings sheet. "Automatic, but not silent" is only true
 where the reasoning is on screen, and it needs to be on screen in both places — the page
 you land on from a card, and the sheet you open to change something.
 */
struct RuntimeProfilePanel: View {
    let profile: RuntimeProfile

    var body: some View {
        DetailPanel(title: String(localized: "How this game runs"),
                    systemImage: "wand.and.sparkles") {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                HStack(spacing: Theme.Spacing.small) {
                    PortalBadge(profile.graphicsBackend?.description
                                ?? String(localized: "Runtime default"),
                                systemImage: "square.stack.3d.up",
                                tint: Theme.Palette.brandSecondary)

                    PortalBadge(Self.sourceDescription(profile.source),
                                systemImage: profile.source == .userOverride ? "hand.raised" : "gearshape.2")

                    if profile.requirements.thirtyTwoBit {
                        PortalBadge(String(localized: "32-bit"), tint: .orange)
                    }

                    if profile.requirements.nativeVulkan {
                        PortalBadge(String(localized: "Needs Vulkan"), tint: .red)
                    }
                }

                if profile.reasons.isEmpty {
                    Text("Nothing in this game's files said how it renders, so it gets the runtime's own defaults.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        ForEach(profile.reasons, id: \.self) { reason in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(Theme.Palette.brandSecondary)
                                    .imageScale(.small)

                                Text(reason)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    static func sourceDescription(_ source: RuntimeProfile.Source) -> String {
        switch source {
        case .userOverride: String(localized: "Your choice")
        case .database:     String(localized: "Known-good settings")
        case .inspection:   String(localized: "Read from the game")
        case .fallback:     String(localized: "Defaults")
        }
    }
}

// MARK: - Panels

/// A titled panel of related facts.
struct DetailPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label(title, systemImage: systemImage)
                .font(Theme.Text.sectionTitle)
                .labelStyle(.titleAndIcon)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.large)
                .cardSurface(cornerRadius: Theme.Radius.card, elevated: false)
        }
    }
}

/// One labelled fact, with an optional control on the right.
struct DetailRow<Accessory: View>: View {
    let label: String
    let value: String?
    let accessory: Accessory

    init(_ label: String, value: String?, @ViewBuilder accessory: () -> Accessory) {
        self.label = label
        self.value = value
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)

            if let value {
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.Spacing.medium)

            accessory
        }
        .font(.callout)
        .padding(.vertical, Theme.Spacing.small)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }
}

extension DetailRow where Accessory == EmptyView {
    init(_ label: String, value: String?) {
        self.init(label, value: value) { EmptyView() }
    }
}
