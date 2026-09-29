//
//  StoreView.swift
//  PorTalistic
//
//  Created by vapidinfinity (esi) on 10/9/2023.
//  Rebuilt by Claude Opus 5 on 15/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI
import SwordRPC
import WebKit

/**
 A storefront's own web store, in a web view.

 One view for every store rather than one per storefront: the page, its name and its cookie
 jar all come from ``Game/Storefront``, so adding GOG was adding three lines there rather than
 a second copy of this file — and the sidebar, the title and the Discord presence cannot end up
 disagreeing about what a store is called.

 - Note: signing in here is *not* the same as signing in to the launcher. Accounts shows the
   storefront's API token, which is what reads your library; this page needs ordinary website
   cookies. They share a `WKWebsiteDataStore` — see ``Legendary/webDataStoreIdentifier`` and
   ``GOG/webDataStoreIdentifier`` — so a sign-in in either place is visible to the other, but
   Epic's launcher sign-in goes through `legendary.gl/epiclogin`, which returns an
   authorization code and never establishes a store session. Being signed in to one and not
   the other is expected.
 */
struct StoreView: View {
    let storefront: Game.Storefront

    private var home: URL? { storefront.storeURL }
    private var name: String { storefront.storeName ?? storefront.description }

    @State private var controller: WebViewController = .init()
    @State private var loadError: Error?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("Can't reach the \(name).", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError.localizedDescription)
                } actions: {
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        self.loadError = nil
                        controller.reload()
                    }
                    .buttonStyle(.portalProminent)
                }
            } else if let home, let identifier = storefront.webDataStoreIdentifier {
                WebView(url: home,
                        datastore: WebDataStore.persistent(for: identifier),
                        controller: controller,
                        error: $loadError)
                    // Two things happen on the way out, and both exist because leaving the
                    // store page is the only moment the app can know something might have
                    // changed on the account.
                    //
                    // The store outlives this view now, but WebKit still writes cookies back
                    // lazily, so it is asked to reconcile before the page is torn down. And
                    // the library is refreshed, because a game bought here appeared nowhere
                    // until the next launch: nothing in the app watches a storefront for
                    // purchases, and a web page cannot tell us one happened.
                    .onDisappear {
                        WebDataStore.flush(identifier)

                        Task(priority: .utility) {
                            // `forcingRemoteFetch` matters here and nowhere else: a plain
                            // refresh asks legendary, and legendary answers from its own
                            // cache — which does not have the game bought a minute ago.
                            try? await GameDataStore.shared.refreshFromStorefronts(
                                storefront, forcingRemoteFetch: true
                            )
                        }
                    }
            } else {
                // Only reachable if a storefront gains a sidebar row without gaining a page.
                // `Storefront.withStores` is what stops that, and this is what it looks like
                // if it ever stops stopping it.
                ContentUnavailableView("No store page for \(storefront.description).",
                                       systemImage: "bag.badge.questionmark")
            }
        }
        .navigationTitle(name)
        .standardTitleBar()

        .task(priority: .background) {
            discordRPC.setPresence({
                var presence: RichPresence = .init()
                presence.details = "Currently browsing the \(name)"
                presence.state = "Looking for games to purchase"
                presence.timestamps.start = .now
                presence.assets.largeImage = "macos_512x512_2x"

                return presence
            }())
        }

        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // These used to be `private var canGoBack = false` on the view and a
                // `URLRequest(url: "javascript:history.back()")` on press: permanently
                // disabled, and pressing them loaded a URL `WKWebView` refuses. They work
                // now, because the web view reports its own state back through
                // `WebViewController`.
                Button("Back", systemImage: "chevron.backward") {
                    controller.goBack()
                }
                .disabled(!controller.canGoBack)

                Button("Forward", systemImage: "chevron.forward") {
                    controller.goForward()
                }
                .disabled(!controller.canGoForward)

                Button("Reload", systemImage: "arrow.clockwise") {
                    controller.reload()
                }
            }

            ToolbarItem(placement: .automatic) {
                Button("Open in Browser", systemImage: "arrow.up.forward") {
                    guard let target = controller.currentURL ?? home else { return }
                    NSWorkspace.shared.open(target)
                }
                .help("Open this page in your usual browser")
            }
        }
    }
}

#Preview("Epic") {
    NavigationStack {
        StoreView(storefront: .epicGames)
    }
    .frame(width: 900, height: 600)
}

#Preview("GOG") {
    NavigationStack {
        StoreView(storefront: .gog)
    }
    .frame(width: 900, height: 600)
}
