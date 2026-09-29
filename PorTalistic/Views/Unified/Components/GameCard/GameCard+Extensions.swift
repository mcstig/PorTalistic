//
//  GameCard+Extensions.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 10/20/24.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import AppKit

// TODO: architectural refactor, for new GameOperationManager
// swiftlint:disable nesting
extension GameCard {
    struct Buttons {
        // `Prominent.PlayButton` and `Prominent.InstallButton` used to live here: labelled
        // pills, each carrying its own sheets and alert. `ActionIconButton` is the one
        // primary action now and owns that logic, and the `Prominent` grouping went with
        // them. Leaving a second spelling of the same control behind is what let the Home
        // hero keep showing the old one long after everywhere else had changed.

        struct VerificationButton: View {
            @Binding var game: Game
            var withLabel: Bool = false

            @EnvironmentObject var networkMonitor: NetworkMonitor
            @Bindable private var operationManager: GameOperationManager = .shared

            @State private var verificationError: Error?
            @State private var isVerificationErrorAlertPresented: Bool = false

            var body: some View {
                Button {
                    Task { [game] in
                        do {
                            try await game.verifyInstallation()
                        } catch {
                            verificationError = error
                            isVerificationErrorAlertPresented = true
                        }
                    }
                } label: {
                    if withLabel {
                        Label("Verify", systemImage: "checkmark.circle.badge.questionmark")
                    } else {
                        Image(systemName: "checkmark.circle.badge.questionmark")
                            .padding(2)
                    }
                }
                .disabled(!networkMonitor.isReachable(for: game.storefront))
                .disabled(game.storefront == .local)
                .disabled(operationManager.queue.contains(where: { $0.game == game && $0.type == .repair }))
                // A game that isn't on disk has nothing to verify. Gated on the library's own
                // view of that, not the filesystem: this is a button in a card grid.
                .disabled(!game.isInstalled)
                .alert("Unable to verify installation.",
                       isPresented: $isVerificationErrorAlertPresented,
                       presenting: verificationError) { _ in
                    if #available(macOS 26.0, *) {
                        Button(role: .close, action: {})
                    } else {
                        Button("OK", role: .cancel, action: {})
                    }
                } message: { error in
                    Text(error?.localizedDescription ?? "Unknown error.")
                }
                .help("Verify game files' integrity for \(game.description).")
            }
        }
        struct UpdateButton: View {
            @Binding var game: Game
            var withLabel: Bool = false

            @EnvironmentObject var networkMonitor: NetworkMonitor
            @Bindable private var operationManager: GameOperationManager = .shared
            
            var body: some View {
                Button {
                    Task(priority: .userInitiated) {
                        try await game.update()
                    }
                } label: {
                    if withLabel {
                        if let isUpdateAvailable = game.isUpdateAvailable {
                            Label(isUpdateAvailable ? "Update" : "Up to date",
                                  systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        } else {
                            Label("Update checking unavailable",
                                  systemImage: "checkmark.circle.dotted")
                        }
                    } else {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                            .padding(2)
                    }
                }
                .disabled(!networkMonitor.isReachable(for: game.storefront))
                // FIXME: .disabled(game.checkIfGameIsRunning())
                .disabled(game.isUpdateAvailable != true)
                .disabled(operationManager.queue.contains(where: { $0.game == game && $0.type == .update }))
                // A game that isn't on disk has nothing to update. Gated on the library's own
                // view of that, not the filesystem: this is a button in a card grid.
                .disabled(!game.isInstalled)
                .help("Update \"\(game.title)\"")
            }
        }

        struct SettingsButton: View {
            @Binding var game: Game
            var withLabel: Bool = false

            @Binding var isGameSettingsSheetPresented: Bool

            var body: some View {
                Button {
                    isGameSettingsSheetPresented = true
                } label: {
                    if withLabel {
                        Label("Settings", systemImage: "gear")
                    } else {
                        Image(systemName: "gear")
                            .padding(2)
                    }
                }
                .help("Modify settings for \"\(game.title)\"")
                // FIXME: unable to propagate in menuview - this view is not in the hierarchy if called by `Menu`.
                // FIXME: you must add the sheet below to whatever view you call this button in!!
                /*
                 .sheet(isPresented: $isGameSettingsSheetPresented) {
                 GameSettingsView(game: $game, isPresented: $isGameSettingsSheetPresented)
                 .padding()
                 .frame(minWidth: 750)
                 }
                 */
            }
        }

        struct FavouriteButton: View {
            @Binding var game: Game
            var withLabel: Bool = false

            @State private var hoveringOverFavouriteButton = false
            @State private var animateFavouriteIcon = false

            var body: some View {
                Button {
                    game.isFavourited.toggle()
                    withAnimation { animateFavouriteIcon = game.isFavourited }
                } label: {
                    if withLabel {
                        Label(game.isFavourited ? "Unfavourite" : "Favourite", systemImage: "star")
                            .symbolVariant(animateFavouriteIcon ? (hoveringOverFavouriteButton ? .slash.fill : .fill) : .none)
                            .contentTransition(.symbolEffect(.replace))
                    } else {
                        Image(systemName: "star")
                            .symbolVariant(animateFavouriteIcon ? (hoveringOverFavouriteButton ? .slash.fill : .fill) : .none)
                            .contentTransition(.symbolEffect(.replace))
                            .padding(2)
                    }
                }
                .onHover { hoveringOverFavouriteButton = $0 }
                .help("Favourite \"\(game.title)\"")
                .task { animateFavouriteIcon = game.isFavourited }
                .shadow(color: .secondary, radius: animateFavouriteIcon ? 20 : 0)
            }
        }

        /// Uninstalls a game — the word the sheet it opens has always used.
        struct UninstallButton: View {
            @Binding var game: Game
            var withLabel: Bool = false

            @Binding var isUninstallSheetPresented: Bool

            @Bindable private var operationManager: GameOperationManager = .shared

            @State private var hoveringOverDestructiveButton = false

            var body: some View {
                Button {
                    isUninstallSheetPresented = true
                } label: {
                    if withLabel {
                        Label("Uninstall", systemImage: "xmark.bin")
                    } else {
                        Image(systemName: "xmark.bin")
                            .padding(2)
                    }
                }
                .disabled(operationManager.queue.contains(where: { $0.game == game && $0.type == .uninstall }))
                // A game that isn't on disk has nothing to remove. Gated on the library's own
                // view of that, not the filesystem: this is a button in a card grid.
                .disabled(!game.isInstalled)
                // FIXME: .disabled(game.checkIfGameIsRunning())
                .help("Uninstall \"\(game.title)\"")
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        hoveringOverDestructiveButton = hovering
                    }
                }
                // FIXME: unable to propagate in menuview - this view is not in the hierarchy if called by `Menu` smh so much for modularity.
                // FIXME: you must add the sheet below to whatever view you call this button in!!
                /*
                 .sheet(isPresented: $isUninstallSheetPresented) {
                 UninstallGameView(game: $game, isPresented: $isUninstallSheetPresented)
                 }
                 */
            }
        }
    }

    /// Whichever installation sheet this game's storefront needs.
    ///
    /// Written out at both install buttons before this existed, which is two places to
    /// remember when a storefront is added.
    struct InstallationSheet: View {
        @Binding var game: Game
        @Binding var isPresented: Bool

        var body: some View {
            Group {
                switch game {
                case let epicGame as EpicGamesGame:
                    EpicGamesGameInstallationView(
                        game: .init(get: { epicGame }, set: { game = $0 }),
                        isPresented: $isPresented
                    )
                case let gogGame as GOGGame:
                    GOGGameInstallationView(
                        game: .init(get: { gogGame }, set: { game = $0 }),
                        isPresented: $isPresented
                    )
                default:
                    EmptyView()
                }
            }
            .padding()
            .frame(width: 700, height: 380)
            .brandedSurface()
        }
    }

    /// One icon: download when the game isn't installed, play when it is.
    ///
    /// Replaces the prominent Play/Install pill that used to sit in the middle of a card's
    /// artwork, revealed on hover. It moved next to the menu for two reasons: the artwork was
    /// crowded, and a large button over the art made it ambiguous what clicking the card
    /// itself would do — which is open the game's page.
    ///
    /// The same button appears on that page, so the primary action looks the same wherever it
    /// is found.
    struct ActionIconButton: View {
        @Binding var game: Game

        /// On the game's page this sits on a hero image and needs a surface of its own; on a
        /// card it belongs to the quiet row of controls beside the title.
        var isOnHero: Bool = false

        @EnvironmentObject var networkMonitor: NetworkMonitor
        @Bindable private var operationManager: GameOperationManager = .shared

        /// Set while Play has been pressed and the launch hasn't been queued yet.
        ///
        /// Only that gap. Everything after it belongs to the launch operation, which now lives
        /// as long as the game does and says whether the game is still starting or up — see
        /// ``GameOperation/launchPhase``. This used to be a fixed six seconds because there was
        /// nothing to ask: the spinner stopped while the game was still loading, and Play went
        /// live again underneath it, so a second press started a second copy.
        @State private var isRequestingLaunch: Bool = false

        @State private var isInstallSheetPresented: Bool = false
        @State private var isLaunchErrorAlertPresented: Bool = false
        @State private var launchError: Error?
        @State private var isEngineInstallationViewPresented: Bool = false
        @State private var engineInstallationError: Error?
        @State private var engineInstallationSuccess: Bool = false

        var body: some View {
            // Branching here rather than attaching all three presentations to one button: an
            // uninstalled game has no use for the launch alert or the engine installer, and a
            // card grid pays for every presenter the moment a card appears. `@State` belongs
            // to this view, not to either branch, so nothing is lost by choosing.
            if isInstalled {
                play
            } else {
                download
            }
        }

        // MARK: Play

        private var play: some View {
            Button {
                isRequestingLaunch = true

                Task(priority: .userInitiated) {
                    defer { isRequestingLaunch = false }

                    do {
                        try await game.launch()
                    } catch {
                        launchError = error
                        isLaunchErrorAlertPresented = true
                    }
                }
            } label: {
                icon(systemImage: "play.fill")
            }
            .modifier(Chrome(isOnHero: isOnHero, isDimmed: isRunning))
            .disabled(isStarting || isRunning || isBusy)
            .help(playHelp)
            .alert(isPresented: $isLaunchErrorAlertPresented) {
                if launchError is Engine.NotInstalledError {
                    return Alert(
                        title: Text("\(Branding.name) Engine is not installed."),
                        message: Text("""
                            It is required to launch this game.
                            Would you like to install it now?
                            """),
                        primaryButton: .default(.init("Install")) {
                            isEngineInstallationViewPresented = true
                        },
                        secondaryButton: .cancel()
                    )
                } else {
                    return Alert(
                        title: Text("Error launching \"\(game.title)\"."),
                        message: Text(launchError?.localizedDescription ?? "Unknown Error.")
                    )
                }
            }
            .sheet(isPresented: $isEngineInstallationViewPresented) {
                EngineInstallationView(
                    isPresented: $isEngineInstallationViewPresented,
                    installationError: $engineInstallationError,
                    installationComplete: $engineInstallationSuccess
                )
                .padding()
                .brandedSurface()
            }
        }

        private var playHelp: String {
            if launchOperation?.isForceQuitting == true { return String(localized: "Force quitting \"\(game.title)\"…") }
            if isStarting { return String(localized: "Starting \"\(game.title)\"…") }
            if isRunning { return String(localized: "\"\(game.title)\" is already running.") }
            if isBusy { return String(localized: "\(game.description) has work outstanding.") }
            return String(localized: "Play \"\(game.title)\"")
        }

        // MARK: Download

        private var download: some View {
            Button {
                isInstallSheetPresented = true
            } label: {
                icon(systemImage: "arrow.down.to.line")
            }
            .modifier(Chrome(isOnHero: isOnHero, isDimmed: false))
            // Epic's reachability check gates Epic. A GOG game has no business being
            // ungrabbable because epicgames.com didn't answer.
            .disabled(!networkMonitor.isReachable(for: game.storefront))
            .disabled(game.storefront == .local)
            .disabled(isBusy)
            .help(downloadHelp ?? String(localized: "Install \(game.description)"))
            .sheet(isPresented: $isInstallSheetPresented) {
                GameCard.InstallationSheet(game: $game, isPresented: $isInstallSheetPresented)
            }
        }

        /// Why the button won't respond — a disabled control that can't say why is
        /// indistinguishable from a broken one.
        private var downloadHelp: String? {
            if isBusy {
                return String(localized: "\(game.description) already has work queued.")
            }

            if !networkMonitor.isReachable(for: game.storefront) {
                return String(localized: "\(Branding.name) can't reach \(game.storefront?.description ?? String(localized: "this storefront")) right now.")
            }

            if game.storefront == .local {
                return String(localized: "\(game.description) was added from a folder, so there's nothing to download.")
            }

            return nil
        }

        // MARK: Shape

        /// The icon, or a spinner in its place, at the size of the menu button beside it — so
        /// the row doesn't move when the state changes.
        private func icon(systemImage: String) -> some View {
            Group {
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .imageScale(.medium)
                }
            }
            .frame(width: 22, height: 18)
            .contentShape(.rect)
        }

        /// Everything that differs between the card's quiet row and the hero's glass circle.
        private struct Chrome: ViewModifier {
            let isOnHero: Bool
            let isDimmed: Bool

            func body(content: Content) -> some View {
                if isOnHero {
                    // The glass is the button's own, so the whole circle turns violet under
                    // the pointer and the whole circle can be clicked. It used to be padding
                    // and glass wrapped around a quiet button: violet in the middle, a dark
                    // ring round it that did nothing. Dimmed while the game runs by being
                    // disabled, which the style shows.
                    content
                        .buttonStyle(.portalFloating)
                } else {
                    content
                        .buttonStyle(.portalQuietCompact)
                        .foregroundStyle(isDimmed
                                         ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                         : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                }
            }
        }

        // MARK: State

        private var isInstalled: Bool { game.isInstalled }

        /// The launch this game is living in, if it has one.
        private var launchOperation: GameOperation? { operationManager.launchOperation(for: game) }

        /// Asked for, and not on screen yet. Both phases before the game appears: a launch
        /// spends the first of them setting the container up, and Play has to stay spent for
        /// that whole time or a second press starts a second copy.
        private var isStarting: Bool {
            isRequestingLaunch || launchOperation.map { $0.launchPhase != .running } == true
        }

        /// Up. Pressing again would start a second copy.
        private var isRunning: Bool { launchOperation?.launchPhase == .running }

        /// Work that touches the game's files, which Play and Install both have to wait for.
        private var isBusy: Bool {
            operationManager.queue.contains { $0.game == game && $0.type.modifiesFiles }
        }
    }

    struct MenuView: View {
        @Binding var game: Game

        /// The host's flags, not this view's own.
        ///
        /// This used to hold both as `@State` and attach both sheets itself — so a card that
        /// already had a settings sheet and an uninstall sheet carried four presenters, and
        /// a grid of a hundred and thirty games carried five hundred. They are the same two
        /// sheets either way: whichever view shows the menu also shows them.
        @Binding var isSettingsPresented: Bool
        @Binding var isUninstallPresented: Bool

        /// Whether to build the commands at all.
        ///
        /// A card grid sets this from hover, so a hundred and thirty menus' worth of command
        /// views aren't constructed on every redraw of a list nobody is pointing at. Every
        /// one of these commands is also on the card's right-click menu, which is always
        /// populated, so nothing is unreachable while this is false.
        var isPopulated: Bool = true

        var body: some View {
            Menu {
                if isPopulated {
                    GameCard.Buttons.SettingsButton(game: $game, withLabel: true,
                                                    isGameSettingsSheetPresented: $isSettingsPresented)
                    GameCard.Buttons.UpdateButton(game: $game, withLabel: true)
                    GameCard.Buttons.FavouriteButton(game: $game, withLabel: true)
                    GameCard.Buttons.UninstallButton(game: $game, withLabel: true,
                                                  isUninstallSheetPresented: $isUninstallPresented)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .imageScale(.medium)
                    .frame(width: 22, height: 18)
                    .contentShape(.rect)
            }
        }
    }

    /// The same commands as ``MenuView``, for a right-click on a card.
    ///
    /// Separate because a context menu's contents are not in the view hierarchy, so sheets
    /// attached inside one never present — which is the real cause of the two "you must add
    /// the sheet below to whatever view you call this button in" notes further up this file.
    /// The presenting view owns the flags and attaches the sheets; this only sets them.
    struct ContextMenuItems: View {
        @Binding var game: Game
        @Binding var isSettingsPresented: Bool
        @Binding var isUninstallPresented: Bool

        var body: some View {
            Button(game.isFavourited ? "Unfavourite" : "Favourite", systemImage: "star") {
                game.isFavourited.toggle()
            }

            GameCard.Buttons.UpdateButton(game: $game, withLabel: true)
            GameCard.Buttons.VerificationButton(game: $game, withLabel: true)

            if case .installed(let location, _) = game.installationState {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([location])
                }
            }

            Divider()

            Button("Settings...", systemImage: "gear") { isSettingsPresented = true }

            // The component, not a second copy of it. A hardcoded button here is how the
            // right-click menu kept offering Uninstall for a game that was never installed
            // after `UninstallButton` learned not to.
            GameCard.Buttons.UninstallButton(game: $game, withLabel: true,
                                             isUninstallSheetPresented: $isUninstallPresented)
        }
    }

    // `ButtonsView` used to live here: a Play-or-Install button with its own copy of the
    // card menu beside it. Nothing in the app referenced it, and its menu was the last
    // caller that relied on `MenuView` carrying its own two sheets — so it is deleted
    // rather than updated.

    struct SubscriptedInfoView: View {
        @Binding var game: Game
        @Bindable var gameDataStore: GameDataStore = .shared

        var body: some View {
            if let storefront = game.storefront {
                PortalBadge(storefront.description, systemImage: storefront.symbolName, tint: storefront.tint)
            }

            if GameDataStore.shared.recent == game {
                PortalBadge(String(localized: "Recently played"))
            }
        }
    }

    struct TitleAndInformationView: View {
        @Binding var game: Game
        var font: Font = .title
        var withSubscriptedInfo: Bool = true

        var body: some View {
            HStack {
                Text(game.title)
                    // `.lineLimit(1)` in a column narrow enough that "Blades of Time"
                    // becomes "Blades o...", so the tooltip is the full name — and only the
                    // full name. The storefront's app name used to ride along here, and
                    // before that it was printed as a line of its own under the title,
                    // where a 32-character hex string wrapped to three lines and made every
                    // card taller in debug than the one that ships. It isn't worth a
                    // developer's screen space in either place; the id is in the logs, in
                    // the debugger, and in the storefront's own metadata.
                    .font(font)
                    .bold()
                    .truncationMode(.tail)
                    .lineLimit(1)
                    .help(game.title)

            }

            if withSubscriptedInfo {
                HStack {
                    GameCard.SubscriptedInfoView(game: $game)
                        .lineLimit(1)
                }
            }
        }
    }
}
// swiftlint:enable nesting

#Preview {
    LibraryView()
        .environmentObject(NetworkMonitor.shared)
}


// MARK: - Shared sheets

extension View {
    /// This game's settings, as a sheet.
    func gameSettingsSheet(game: Binding<Game>, isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            GameSettingsView(game: game, isPresented: isPresented)
                // Resizable, and tall enough for the container settings. At 720 × 420 the
                // form needed a thousand points, so the bottom bar sat on top of the rows
                // and the last four toggles laid out below the window.
                .sheetSurface(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 680)
        }
    }

    /// This game's uninstaller, as a sheet.
    ///
    /// Each storefront removes a game its own way, so the right sheet depends on the game's
    /// concrete type. Written once here rather than copied into every view that offers a
    /// Delete command.
    func gameUninstallSheet(game: Binding<Game>, isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            switch game.wrappedValue {
            case let epicGame as EpicGamesGame:
                EpicGamesGameUninstallationView(
                    game: .init(get: { epicGame }, set: { game.wrappedValue = $0 }),
                    isPresented: isPresented
                )
                .padding()
                .frame(width: 700, height: 380)
                .brandedSurface()
            case let gogGame as GOGGame:
                GOGGameUninstallationView(
                    game: .init(get: { gogGame }, set: { game.wrappedValue = $0 }),
                    isPresented: isPresented
                )
                .padding()
                .frame(width: 700, height: 380)
                .brandedSurface()
            case let localGame as LocalGame:
                LocalGameUninstallationView(
                    game: .init(get: { localGame }, set: { game.wrappedValue = $0 }),
                    isPresented: isPresented
                )
                .padding()
                .frame(width: 700, height: 380)
                .brandedSurface()
            default:
                EmptyView()
            }
        }
    }
}
