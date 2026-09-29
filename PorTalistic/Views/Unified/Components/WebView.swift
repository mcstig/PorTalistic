//
//  WebView.swift
//  PorTalistic
//
// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI
import WebKit
import OSLog

/**
 A web page, embedded.

 Three things were missing, and together they made the Store unusable rather than merely
 plain:

 - **No `uiDelegate`.** A `WKWebView` without one silently drops every `window.open()` and
   `target="_blank"` navigation. Epic's sign-in opens one, so pressing Sign in on the store
   page did nothing the page could recover from — it reported "Uh oh, something went wrong."
 - **`WKWebView`'s default user agent**, which does not name a browser. Epic's identity
   service answers that with the same generic error.
 - **`canGoBack` / `canGoForward` were plain `var`s** on the struct, assigned from the
   coordinator — writing to a copy, so they never propagated. The Store's back and forward
   buttons were permanently disabled, and pressed `URLRequest(url: "javascript:history.back()")`,
   which `WKWebView` refuses to load. Both buttons were decorative.
 */
struct WebView: NSViewRepresentable {
    var url: URL
    var datastore: WKWebsiteDataStore = .default()

    /// Drives the page from outside — the toolbar's back, forward and reload.
    var controller: WebViewController?

    @Binding var error: Error?

    nonisolated static let log: Logger = .custom(category: "WebView")

    func makeNSView(context: Context) -> WKWebView {
        let configuration: WKWebViewConfiguration = .init()
        configuration.websiteDataStore = datastore

        // Appended to WebKit's own user agent rather than replacing it, which produces a
        // genuine Safari-shaped string without this having to invent — and then maintain —
        // a whole one.
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

        let webView: WKWebView = .init(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator.windowOpener
        webView.allowsBackForwardNavigationGestures = true

        controller?.attach(webView)
        webView.load(.init(url: url))

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        controller?.attach(nsView)

        // Only when the caller has actually pointed somewhere else. Comparing against the
        // live URL would reload the page every time the user navigated within the site.
        if context.coordinator.requestedURL != url {
            context.coordinator.requestedURL = url
            nsView.load(.init(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        .init(self)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        var requestedURL: URL?

        /// Held strongly: `uiDelegate` is weak, and nothing else would keep this alive.
        let windowOpener: WebViewWindowOpener = .init()

        init(_ parent: WebView) {
            self.parent = parent
            self.requestedURL = parent.url
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            // `NSURLErrorCancelled` is what a redirect chain reports when it supersedes
            // itself, and it happens constantly during an OAuth hop. Showing it would put an
            // error on screen in the middle of a sign-in that is working.
            guard (error as NSError).code != NSURLErrorCancelled else { return }

            WebView.log.error("\(error.localizedDescription, privacy: .public)")
            parent.error = error
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.error = nil
            parent.controller?.update(from: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.controller?.update(from: webView)
        }
    }
}

/// Opens the windows a page asks for, and closes them when it asks.
///
/// Attach one as a `WKWebView`'s `uiDelegate`. A web view without a `uiDelegate` silently
/// drops every `window.open()` and `target="_blank"` navigation, and tells the page nothing
/// about it — so a sign-in that opens its login in a new window just stops, and the site is
/// left to guess. Epic's guess is "Uh oh, something went wrong."
final class WebViewWindowOpener: NSObject, WKUIDelegate, NSWindowDelegate {
    /// Windows the page opened, keyed by the web view inside each.
    ///
    /// Retained here because `isReleasedWhenClosed` is off: WebKit can still talk to the web
    /// view after the page has closed its window.
    private var windows: [ObjectIdentifier: NSWindow] = .init()

    /// The page each popup was opened *from*, weakly.
    ///
    /// Kept so that a popup closing can reload the page underneath it. A sign-in that happens
    /// in a popup leaves the opener rendered exactly as it was before — Epic's store then
    /// shows a Sign In button over a session that is perfectly signed in, and the giveaway is
    /// that buying the game works anyway. Nothing tells a single-page app its cookies changed
    /// while it wasn't looking; the close of the window it opened is the signal.
    private var openers: [ObjectIdentifier: WeakWebView] = .init()

    private struct WeakWebView {
        weak var value: WKWebView?
    }

    nonisolated static let log: Logger = .custom(category: "webViewWindows")

    /// Gives a page that asks for a window an actual window.
    ///
    /// Loading the would-be popup's URL in the opening web view instead is the tempting
    /// shortcut, and it is wrong: it severs `window.opener`, which is exactly how every
    /// social sign-in posts its result back. The flow would hang on a page that looks
    /// finished.
    ///
    /// The configuration must be the one WebKit handed over — a fresh one would put the
    /// window in another process, with another cookie jar, and the sign-in would not count.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup: WKWebView = .init(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        popup.autoresizingMask = [.width, .height]

        // Deliberately no `navigationDelegate`: the opening view's belongs to the view that
        // owns it, and a redirect in here must not put an error over that page or rewrite
        // its back and forward buttons.

        let size: NSSize = .init(width: windowFeatures.width?.doubleValue ?? 520,
                                 height: windowFeatures.height?.doubleValue ?? 720)

        let window: NSWindow = .init(contentRect: .init(origin: .zero, size: size),
                                     styleMask: [.titled, .closable, .resizable],
                                     backing: .buffered,
                                     defer: false)
        window.title = navigationAction.request.url?.host ?? Branding.name
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        windows[.init(popup)] = window
        openers[.init(popup)] = .init(value: webView)
        Self.log.notice("Opened a window for \(window.title, privacy: .public).")

        return popup
    }

    /// Closes a window the page opened, when the page closes it — which is how an OAuth hop
    /// signs off, and reloads the page that opened it.
    ///
    /// The reload is the fix for a signed-in store still showing Sign In. A popup that closes
    /// itself has almost always just finished something the opener cares about — a sign-in, a
    /// purchase, an age gate — and the opener has no way to find out: its cookies changed
    /// underneath it and no navigation happened. Reloading is cheap, and being wrong about it
    /// costs a page refresh nobody notices.
    func webViewDidClose(_ webView: WKWebView) {
        finish(.init(webView))
    }

    /// The same thing, when the *person* closes the window rather than the page.
    ///
    /// Half the reason this exists: a sign-in finished in a popup that the user then dismisses
    /// by hand never calls `webViewDidClose`, so without this the opener would be reloaded for
    /// a flow that closed itself and not for one somebody closed — the same stale Sign In
    /// button, reachable a different way.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = windows.first(where: { $0.value === window })?.key else { return }

        finish(key)
    }

    /// Forget a popup and reload whatever opened it. Safe to call twice: the page closing its
    /// own window triggers `windowWillClose` straight afterwards, and the second pass finds
    /// nothing left to do.
    private func finish(_ key: ObjectIdentifier) {
        let window = windows.removeValue(forKey: key)
        let opener = openers.removeValue(forKey: key)?.value

        window?.delegate = nil
        window?.close()

        if let opener {
            Self.log.notice("A window closed; reloading the page that opened it.")
            opener.reload()
        }
    }
}

/// A handle on an embedded page, for a toolbar that needs to drive it.
@MainActor
@Observable
final class WebViewController {
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false
    private(set) var currentURL: URL?

    /// Weak: the web view belongs to the view hierarchy, not to this.
    private weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    fileprivate func attach(_ webView: WKWebView) {
        guard self.webView !== webView else { return }
        self.webView = webView
        update(from: webView)
    }

    fileprivate func update(from webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
    }
}

#Preview {
    WebView(url: .init(string: "https://example.com")!, error: .constant(nil))
}
