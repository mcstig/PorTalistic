//
//  WebDataStore.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 24/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import Foundation
import OSLog
import WebKit

/**
 The one live `WKWebsiteDataStore` per identifier, held for as long as the app runs.

 # The fault this exists for

 `WKWebsiteDataStore(forIdentifier:)` was being called inside a view's `body` — in the store
 page and in both sign-in windows. That reads as harmless, because the identifier is stable
 and the store is persistent. It is not, for two reasons that compound:

 - `body` runs on every redraw, so each pass built *another* store object for the same
   identifier.
 - Nothing retained any of them. Navigating away from the store destroyed the view, the web
   view and the data store together.

 WebKit writes cookies back lazily. A store released before it flushes takes the cookies it
 was holding with it — so the sequence was: sign in, cookies live in memory, navigate to the
 library, the store is deallocated without flushing, come back, a fresh store reads disk and
 finds nothing. Signed out, every time, having just signed in. Buying a game and returning to
 the store page is exactly that sequence.

 Holding one store per identifier for the process's lifetime is the whole fix. It is also what
 makes a sign-in in one window visible in another: two objects for one identifier are two
 caches over the same files, and which one has the newest cookies depends on which flushed
 last.

 - Important: nothing should call `WKWebsiteDataStore(forIdentifier:)` directly. An invariant
   check enforces that, because the failure it causes looks like a website's problem rather
   than like ours.
 */
@MainActor
enum WebDataStore {
    static let log: Logger = .custom(category: "WebDataStore")

    private static var stores: [UUID: WKWebsiteDataStore] = .init()

    /// The persistent store for this identifier, created once.
    static func persistent(for identifier: UUID) -> WKWebsiteDataStore {
        if let existing = stores[identifier] { return existing }

        let store: WKWebsiteDataStore = .init(forIdentifier: identifier)
        stores[identifier] = store

        log.notice("Opened the web data store \(identifier.uuidString, privacy: .public)")
        return store
    }

    /// Ask WebKit to write what it is holding.
    ///
    /// Belt and braces on top of holding the store: the store surviving means WebKit *can*
    /// flush, not that it has. Called when a page that may have signed somebody in goes away.
    static func flush(_ identifier: UUID) {
        guard let store = stores[identifier] else { return }

        // Fetching the records is the documented way to make WebKit reconcile its in-memory
        // state with disk; there is no public "flush now".
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { _ in }
    }
}
