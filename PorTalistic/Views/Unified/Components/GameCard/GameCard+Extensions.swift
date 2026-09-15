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
        struct Prominent {
            struct PlayButton: View {
                @Binding var game: Game
                var withLabel: Bool = false
                var isCompact: Bool = false

                @Bindable private var operationManager: GameOperationManager = .shared

                @State private var isLaunchErrorAlertPresented = false
                @State private var launchError: Error?

                @State private var isEngineInstallationViewPresented: Bool = false
                @State private var engineInstallationError: Error?
                @State private var engineInstallationSuccess: Bool = false

                var body: some View {
                    Button {
                        Task(priority: .userInitiated) {
                            do {
                                try await game.launch()
                            } catch {
                                launchError = error
                                isLaunchErrorAlertPresented = true
                            }
                        }
                    } label: {
                        Group {
                            if withLabel {
                                Label("Play", systemImage: "play")
                            } else {
                                Image(systemName: "play")
                            }
                        }
                        .symbolVariant(.fill)
                    }
                    // Was a white capsule with black text, hard-coded on both counts: the
                    // one control in the app that couldn't be tinted and couldn't be read in
                    // light mode. The brand pill is defined once, in `Surfaces.swift`.
                    .buttonStyle(PortalButtonStyle(emphasis: .prominent, isCompact: isCompact))
                    .disabled(operationManager.queue.contains(where: { $0.game == game && $0.type.modifiesFiles }))
                    // FIXME: .disabled(game.checkIfGameIsRunning())
                    .help("Play \"\(game.title)\"")

                    .alert(isPresented: $isLaunchErrorAlertPresented) {
                        if launchError is Engine.NotInstalledError {
                            return Alert(
                                title: Text("Mythic Engine is not installed."),
                                message: Text("""
                                    Mythic Engine is required to launch this game.
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
            }

            struct InstallButton: View {
                @Binding var game: Game
                var withLabel: Bool = false
                var isCompact: Bool = false

                @EnvironmentObject var networkMonitor: NetworkMonitor
                @Bindable private var operationManager: GameOperationManager = .shared

                @State private var isInstallSheetPresented = false

                /// Why the button won't respond, for the tooltip — a disabled control that
                /// can't say why is indistinguishable from a broken one.
                private var unavailabilityReason: String? {
                    if operationManager.queue.contains(where: { $0.game == game && $0.type == .install }) {
                        return String(localized: "\(game.description) is already queued to install.")
                    }

                    if !networkMonitor.isReachable(for: game.storefront) {
                        return String(localized: "\(Branding.name) can't reach \(game.storefront?.description ?? String(localized: "this storefront")) right now.")
                    }

                    if game.storefront == .local {
                        return String(localized: "\(game.description) was added from a folder, so there's nothing to download.")
                    }

                    return nil
                }

                var body: some View {
                    Button {
                        isInstallSheetPresented = true
                    } label: {
                        if withLabel {
                            Label("Install", systemImage: "arrow.down.to.line")
                        } else {
                            Image(systemName: "arrow.down.to.line")
                        }
                    }
                    .buttonStyle(PortalButtonStyle(emphasis: .prominent, isCompact: isCompact))
                    // Epic's reachability check gates Epic. A GOG game has no business being
                    // ungrabbable because epicgames.com didn't answer.
                    .disabled(!networkMonitor.isReachable(for: game.storefront))
                    .disabled(game.storefront == .local)
                    .disabled(operationManager.queue.contains(where: { $0.game == game && $0.type == .install }))
                    .help(unavailabilityReason ?? String(localized: "Install \(game.description)"))

                    .sheet(isPresented: $isInstallSheetPresented) {
                        switch game {
                        case let epicGame as EpicGamesGame:
                            EpicGamesGameInstallationView(
                                game: .init(get: { epicGame },
                                            set: { game = $0 }),
                                isPresented: $isInstallSheetPresented
                            )
                            .padding()
                            .frame(width: 700, height: 380)
                            .brandedSurface()
                        case let gogGame as GOGGame:
                            GOGGameInstallationView(
                                game: .init(get: { gogGame },
                                            set: { game = $0 }),
                                isPresented: $isInstallSheetPresented
                            )
                            .padding()
                            .frame(width: 700, height: 380)
                            .brandedSurface()
                        default: EmptyView()
                        }
                    }
                }
            }
        }

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

        struct DeleteButton: View {
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
                        Label("Delete", systemImage: "xmark.bin")
                    } else {
                        Image(systemName: "xmark.bin")
                            .padding(2)
                    }
                }
                .disabled(operationManager.queue.contains(where: { $0.game == game && $0.type == .uninstall }))
                // FIXME: .disabled(game.checkIfGameIsRunning())
                .help("Delete \"\(game.title)\"")
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
                    GameCard.Buttons.DeleteButton(game: $game, withLabel: true,
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
            Button("Delete...", systemImage: "xmark.bin") { isUninstallPresented = true }
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
