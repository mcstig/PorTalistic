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
        GOGInterceptorWebView { code in
            handle(authorizationCode: code)
        }
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        let completion: (String) -> Void
        private var hasCompleted = false

        init(completion: @escaping (String) -> Void) {
            self.completion = completion
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  let code = GOG.authorizationCode(from: url) else {
                decisionHandler(.allow)
                return
            }

            // The redirect has done its job the moment we've read it; letting it load just
            // shows the user a blank embed page behind the window we're about to close.
            decisionHandler(.cancel)

            guard !hasCompleted else { return }
            hasCompleted = true
            completion(code)
        }
    }

    func makeCoordinator() -> Coordinator { .init(completion: completion) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Its own cookie jar, so signing out of GOG here doesn't sign the user out of GOG in
        // Safari, and so a stale session can be dropped without touching anything else.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: gogWebDataStore)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: GOG.authorizationURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
    }
}
