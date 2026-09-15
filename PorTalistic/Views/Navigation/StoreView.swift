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
 Epic's store, in a web view.

 - Note: signing in here is *not* the same as signing in to the launcher. Accounts shows the
   `legendary` token, which is what reads your library; this page needs ordinary website
   cookies. They share a `WKWebsiteDataStore` — see ``Legendary/webDataStoreIdentifier`` —
   so a sign-in in either place is visible to the other, but the launcher's sign-in goes
   through `legendary.gl/epiclogin`, which returns an authorization code and never
   establishes a store session. Being signed in to one and not the other is expected.
 */
struct StoreView: View {
    private static let home: URL = .init(string: "https://store.epicgames.com/")!

    @State private var controller: WebViewController = .init()
    @State private var loadError: Error?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("Can't reach the Epic Games Store.", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError.localizedDescription)
                } actions: {
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        self.loadError = nil
                        controller.reload()
                    }
                    .buttonStyle(.portalProminent)
                }
            } else {
                WebView(url: Self.home,
                        datastore: .init(forIdentifier: Legendary.webDataStoreIdentifier),
                        controller: controller,
                        error: $loadError)
            }
        }
        .navigationTitle("Store")
        .standardTitleBar()

        .task(priority: .background) {
            discordRPC.setPresence({
                var presence: RichPresence = .init()
                presence.details = "Currently browsing the Epic Games Store"
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
                    NSWorkspace.shared.open(controller.currentURL ?? Self.home)
                }
                .help("Open this page in your usual browser")
            }
        }
    }
}

#Preview {
    NavigationStack {
        StoreView()
    }
    .frame(width: 900, height: 600)
}
