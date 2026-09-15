//
//  GOGWebAuthView.swift
//  Mythic
//
//  Created by Claude (Cowork) on 13/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import WebKit
import OSLog

/// GOG's sign-in page, in a window, watched for the moment it succeeds.
///
/// The shape mirrors ``EpicWebAuthView`` deliberately — one sign-in experience, not two — but
/// the interception is simpler. Epic renders its authorisation code into a JSON page, so that
/// view has to read the document body back out. GOG never renders anything: it redirects to
/// `embed.gog.com/on_login_success?code=…`, so the code only ever exists in a URL of a page
/// that is still loading, and the navigation delegate is the only place it can be caught.
struct GOGWebAuthView: View {
    @ObservedObject var viewModel: GOGWebAuthViewModel

    @Bindable var gameDataStore: GameDataStore = .shared

    @State private var isWorking: Bool = false
    @State private var isSignInErrorPresented: Bool = false
    @State private var signInError: Error?

    var body: some View {
        GOGInterceptorWebView(
            completion: { code in handle(authorizationCode: code) },
            failure: {
                signInError = GOG.SignInError()
                isSignInErrorPresented = true
            }
        )
        .blur(radius: isWorking ? 30 : 0)
        .alert(isPresented: $isSignInErrorPresented) {
            .init(
                title: Text("Unable to sign in to GOG."),
                message: Text(signInError?.localizedDescription ?? String(localized: "An unknown error occurred.")),
                dismissButton: .default(Text("OK"))
            )
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private func handle(authorizationCode code: String) {
        guard !isWorking else { return }
        isWorking = true

        Task {
            do {
                try await GOG.signIn(authorizationCode: code)
                viewModel.signInSuccess = true
                viewModel.closeSignInWindow()
                try? await gameDataStore.refreshFromStorefronts(.gog)
            } catch {
                signInError = error
                isSignInErrorPresented = true
            }

            withAnimation { isWorking = false }
        }
    }
}

final class GOGWebAuthViewModel: NSObject, ObservableObject, NSWindowDelegate, @unchecked Sendable {
    static let shared = GOGWebAuthViewModel()
    @Published var signInSuccess = false

    private var signInWindow: NSWindow?

    private override init() {
        super.init()
    }

    @MainActor
    func showSignInWindow() {
        guard !GOG.isSignedIn else {
            Logger.app.warning("Already signed in to GOG, skipping sign-in window")
            return
        }

        if let window = signInWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 750, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.identifier = .init("gog-signin")
        window.title = String(localized: "Sign in to GOG")
        window.contentView = NSHostingView(rootView: GOGWebAuthView(viewModel: self))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        signInWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func closeSignInWindow() {
        signInWindow?.orderOut(nil)
        signInWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in closeSignInWindow() }
    }
}

private struct GOGInterceptorWebView: NSViewRepresentable {
    @CodableAppStorage("gogWebDataStore") var gogWebDataStore: UUID = .init()

    let completion: (String) -> Void
    let failure: () -> Void

    /// Main-actor isolated because `WKNavigationDelegate` is: without it the delegate methods
    /// below only *nearly* match their requirements and WebKit never calls them, which is a
    /// warning rather than an error and so exactly the kind of thing that gets shipped.
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        /// Held strongly: `uiDelegate` is weak, and nothing else would keep this alive.
        let windowOpener: WebViewWindowOpener = .init()

        let completion: (String) -> Void
        let failure: () -> Void

        /// Kept alive for the life of the web view — see ``observe(_:)``.
        var urlObservation: NSKeyValueObservation?

        private var hasFinished = false

        init(completion: @escaping (String) -> Void, failure: @escaping () -> Void) {
            self.completion = completion
            self.failure = failure
        }

        /// Watch every way WebKit will tell us where it is.
        ///
        /// The first version of this only implemented `decidePolicyFor navigationAction`, and
        /// it never fired: GOG's last hop is a *server* redirect, which WebKit reports through
        /// `didReceiveServerRedirectForProvisionalNavigation` rather than as a new navigation
        /// action to approve. The authorisation code went past unread, the blank
        /// `on_login_success` page loaded — it genuinely has no content — and the window sat
        /// there looking broken.
        ///
        /// So rather than pick the one correct callback, watch `url` itself and treat the
        /// delegate methods as extra chances. ``handle(_:)`` only acts once.
        func observe(_ webView: WKWebView) {
            urlObservation = webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                // WebKit changes `url` on the main thread, so this is already there — but the
                // observation closure is `@Sendable` and has to be told.
                MainActor.assumeIsolated { self?.handle(view.url) }
            }
        }

        func handle(_ url: URL?) {
            guard !hasFinished, let url else { return }

            if let code = GOG.authorizationCode(from: url) {
                hasFinished = true
                urlObservation = nil
                completion(code)
                return
            }

            // Landing here without a code means GOG finished the flow and declined to issue
            // one. Nothing more is coming, and a blank page is the worst way to say so.
            if url.host == "embed.gog.com", url.path.hasPrefix("/on_login_success") {
                hasFinished = true
                urlObservation = nil
                failure()
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  GOG.authorizationCode(from: url) != nil else {
                decisionHandler(.allow)
                return
            }

            // The redirect has done its job the moment it's read; letting it load just shows
            // a blank embed page behind a window that's about to close.
            decisionHandler(.cancel)
            handle(url)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            handle(webView.url)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            handle(webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            handle(webView.url)
        }
    }

    func makeCoordinator() -> Coordinator { .init(completion: completion, failure: failure) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Its own cookie jar, so signing out of GOG here doesn't sign the user out of GOG in
        // Safari, and so a stale session can be dropped without touching anything else.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: gogWebDataStore)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        // Without this, GOG's "sign in with" buttons — which open a window — do nothing at
        // all, silently. Email and password never needed it, which is why nobody noticed.
        webView.uiDelegate = context.coordinator.windowOpener

        context.coordinator.observe(webView)
        webView.load(URLRequest(url: GOG.authorizationURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.urlObservation = nil
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
    }
}
