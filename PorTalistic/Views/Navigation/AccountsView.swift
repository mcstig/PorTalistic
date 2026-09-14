//
//  AccountsView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 12/3/2024.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import SwordRPC

struct AccountsView: View {
    @ObservedObject private var epicWebAuthViewModel: EpicWebAuthViewModel = .shared
    @ObservedObject private var gogWebAuthViewModel: GOGWebAuthViewModel = .shared

    @State private var isEpicSignOutConfirmationAlertPresented: Bool = false
    @State private var epicSignOutError: Error?
    @State private var isEpicSignOutErrorAlertPresented: Bool = false
    @State private var isEpicAccountCardRefreshed = false

    @State private var gogUsername: String? = GOG.cachedUsername
    @State private var isGOGSignOutConfirmationAlertPresented: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Label("Storefronts", systemImage: "person.2")
                    .font(Theme.Text.sectionTitle)

                Text("Sign in to see the games you own and to install them. Signing out leaves your installed games where they are.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, Theme.Spacing.small)

            LazyVGrid(columns: [.init(.adaptive(minimum: 320), spacing: Theme.Spacing.large)],
                      spacing: Theme.Spacing.large) {
                AccountCard(
                    signedInUser: .constant(try? Legendary.retrieveUser()),
                    image: Game.Storefront.epicGames.accountImage,
                    storefront: .epicGames,
                    signInAction: {
                        Task { @MainActor in
                            epicWebAuthViewModel.showSignInWindow()
                        }
                    },
                    signOutAction: {
                        isEpicSignOutConfirmationAlertPresented = true
                    }
                )
                .padding(Theme.Spacing.large)
                .panelSurface()
                .alert(
                    "Are you sure you want to sign out of Epic Games?",
                    isPresented: $isEpicSignOutConfirmationAlertPresented
                ) {
                    Button(role: .destructive) {
                        Task {
                            do {
                                try await Legendary.signOut()
                                isEpicAccountCardRefreshed.toggle()
                                // FIXME: no way to propogate error
                                // below is the code to do it
                                /*
                                .alert(
                                    "Unable to sign out of Epic Games.",
                                    isPresented: $isEpicSignOutErrorAlertPresented,
                                    presenting: epicSignOutError
                                ) { _ in
                                    Button(role: .close) {

                                    } label: {
                                        Text("OK")
                                    }
                                } message: { error in
                                    Text(error.localizedDescription)
                                }
                                */
                            } catch {
                                epicSignOutError = error
                                isEpicSignOutErrorAlertPresented = true
                            }
                        }
                    } label: {
                        Text("Sign Out")
                    }
                }
                .id(isEpicAccountCardRefreshed)

                AccountCard(
                    signedInUser: $gogUsername,
                    image: Game.Storefront.gog.accountImage,
                    storefront: .gog,
                    signInAction: {
                        Task { @MainActor in
                            Game.Storefront.gog.presentSignIn()
                        }
                    },
                    signOutAction: {
                        isGOGSignOutConfirmationAlertPresented = true
                    }
                )
                .padding(Theme.Spacing.large)
                .panelSurface()
                .alert(
                    "Are you sure you want to sign out of GOG?",
                    isPresented: $isGOGSignOutConfirmationAlertPresented
                ) {
                    Button(role: .destructive) {
                        try? GOG.signOut()
                        gogUsername = nil
                    } label: {
                        Text("Sign Out")
                    }
                } message: {
                    Text("Your installed games stay where they are; you'll need to sign in again to install or update them.")
                }
            }
            }
            .padding(Theme.Spacing.xlarge)
        }
        // The sign-in windows are their own, so this has to notice on its own that an
        // account arrived rather than being told.
        .onChange(of: gogWebAuthViewModel.signInSuccess) {
            Task { gogUsername = await GOG.refreshUsername() }
        }
        .onChange(of: epicWebAuthViewModel.signInSuccess) {
            isEpicAccountCardRefreshed.toggle()
        }
        .task { gogUsername = await GOG.refreshUsername() }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("Accounts")
        .standardTitleBar()
        .task(priority: .background) {
            discordRPC.setPresence({
                var presence: RichPresence = .init()
                presence.details = "Currently in the accounts section."
                presence.state = "Checking out all their accounts"
                presence.timestamps.start = .now
                presence.assets.largeImage = "macos_512x512_2x"

                return presence
            }())
        }
    }
}

extension AccountsView {
    struct AccountCard: View {
        @Binding var signedInUser: String?

        var image: Image
        var storefront: Game.Storefront
        var signInAction: () -> Void
        var signOutAction: () -> Void

        @State private var isHoveringOverSignOutButton: Bool = false
        // @State private var isSignOutConfirmationAlertPresented: Bool = false

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                HStack(spacing: Theme.Spacing.medium) {
                    image
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .padding(Theme.Spacing.small)
                        .background {
                            Circle().fill(storefront.tint.opacity(0.85))
                        }

                    VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
                        Text(storefront.description)
                            .font(.system(.title3, weight: .bold))

                        if let signedInUser {
                            Text(signedInUser)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 0)

                    // A badge rather than a sentence: the state is the thing worth seeing
                    // from across the window, and "Not signed in" as body text beside a
                    // title read as a caption.
                    PortalBadge(signedInUser != nil
                                ? String(localized: "Signed in")
                                : String(localized: "Signed out"),
                                systemImage: signedInUser != nil ? "checkmark.circle" : "person.slash",
                                tint: signedInUser != nil ? .green : .secondary)
                }

                Group {
                    if signedInUser != nil {
                        Button("Sign Out", systemImage: "person.slash", role: .destructive, action: signOutAction)
                            .buttonStyle(.portalCompact)
                        /* FIXME: ☹️☹️ swiftui will not let me do this, stupid hierarchy stupid swiftui rules
                         FIXME: for now, it's called in AccountsView
                            .alert(
                                "Are you sure you want to sign out of Epic Games?",
                                isPresented: $isEpicSignOutConfirmationAlertPresented
                            ) {
                                Button(role: .destructive) {
                                    signOutAction()
                                } label: {
                                    Text("Sign Out")
                                }
                            }
                         */
                    } else {
                        Button("Sign In", systemImage: "person", action: signInAction)
                            .buttonStyle(.portalProminentCompact)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Storefront accounts

/// What a storefront needs from an account, in one place.
///
/// This used to be scattered: `AccountsView` knew how to sign in to Epic, `GameImportView`
/// knew how to sign in to either, and the library knew nothing at all — so a signed-out
/// storefront looked identical to an empty one, and the only route to a sign-in button was
/// Import Game and then switching storefront. Anything that needs to ask "are we signed in,
/// and how would someone fix that" now asks here.
extension Game.Storefront {
    /// Whether signing in is even a concept for this storefront.
    var usesAccount: Bool {
        switch self {
        case .epicGames, .gog: true
        case .steam, .local: false
        }
    }

    var isSignedIn: Bool {
        switch self {
        case .epicGames: Legendary.isSignedIn
        case .gog: GOG.isSignedIn
        case .steam, .local: true
        }
    }

    /// The account's name, when the storefront will tell us one.
    var signedInUsername: String? {
        switch self {
        case .epicGames: try? Legendary.retrieveUser()
        case .gog: GOG.cachedUsername
        case .steam, .local: nil
        }
    }

    /// The storefront's own symbol, which is what the sidebar and every badge already use.
    ///
    /// Epic's was the `EGFaceless` asset — a dark glyph, which on a dark tinted circle
    /// rendered as a faint dash.
    var accountImage: Image { .init(systemName: symbolName) }

    @MainActor func presentSignIn() {
        switch self {
        case .epicGames: EpicWebAuthViewModel.shared.showSignInWindow()
        case .gog: GOGWebAuthViewModel.shared.showSignInWindow()
        case .steam, .local: break
        }
    }
}

/// Says, in the library itself, that a storefront is signed out — and offers to fix it.
///
/// Previously the only hint was an error buried in a game's install sheet, which named the
/// problem and gave no way to act on it. A library that can't be loaded should say so where
/// the library is.
struct StorefrontSignInBanner: View {
    let storefront: Game.Storefront

    // Not to read a value from, but to be re-evaluated when one of them reports a sign-in:
    // the sign-in happens in its own window, so nothing else would tell this view to redraw.
    @ObservedObject private var epicWebAuth: EpicWebAuthViewModel = .shared
    @ObservedObject private var gogWebAuth: GOGWebAuthViewModel = .shared

    private var isVisible: Bool { storefront.usesAccount && !storefront.isSignedIn }

    var body: some View {
        // Deliberately not a `Group`: a Group is transparent and passes its modifiers to its
        // children, so when the condition is false there is nothing to attach them to. The
        // first version of this kept its answer in `@State` filled by a `.task` on a Group,
        // and the task never ran — the banner was correct and invisible.
        VStack(spacing: 0) {
            if isVisible {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("You're not signed in to \(storefront.description).")
                            .font(.headline)

                        Text("Sign in to see the games you own, and to install them.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Sign In", systemImage: "person") {
                        storefront.presentSignIn()
                    }
                    .buttonStyle(.portalProminent)
                }
                .padding(Theme.Spacing.large)
                .panelSurface()
                .padding([.horizontal, .top])
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: isVisible)
    }
}

#Preview {
    AccountsView()
}
