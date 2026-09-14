//
//  SupportView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 12/9/2023.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import AppKit
import SwordRPC

/**
 Where to go when something doesn't work.

 Rebuilt because the old version was five bare `Button`s in two `HStack`s separated by
 hand-drawn `Divider`s of an explicit height, every block pinned to `maxWidth: 400`, with
 `Spacer()`s at the top level of the view body where they had no container to push against.
 It also offered "Report an issue" and "Create a support ticket" as two separate buttons
 that opened the same URL.
 */
struct SupportView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Text("Support")
                        .font(Theme.Text.heroTitle)

                    Text("Have a look here before filing anything — most launch failures are a known one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                section(String(localized: "Read first"), systemImage: "book") {
                    SupportLinkRow(
                        title: String(localized: "Documentation"),
                        description: String(localized: "How \(Branding.name) works, and what it needs from your Mac."),
                        systemImage: "doc.text",
                        url: Branding.readmeURL
                    )

                    SupportLinkRow(
                        title: String(localized: "Discussions"),
                        description: String(localized: "Questions other people have already asked."),
                        systemImage: "bubble.left.and.bubble.right",
                        url: Branding.discussionsURL
                    )

                    SupportLinkRow(
                        title: String(localized: "Compatibility list"),
                        description: String(localized: "Which games run, and what they need to run well."),
                        systemImage: "checklist",
                        url: .init(string: "https://docs.google.com/spreadsheets/d/1W_1UexC1VOcbP2CHhoZBR5-8koH-ZPxJBDWntwH-tsc/")!
                    )
                }

                section(String(localized: "Still stuck"), systemImage: "lifepreserver") {
                    SupportLinkRow(
                        title: String(localized: "Report an issue"),
                        description: String(localized: "A game that won't start, or something in the app that's wrong."),
                        systemImage: "exclamationmark.bubble",
                        url: Branding.issuesURL
                    )

                    SupportLinkRow(
                        title: String(localized: "Source code"),
                        description: String(localized: "\(Branding.name) is open source, under the GPLv3."),
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        url: Branding.repositoryURL
                    )
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(Theme.Spacing.xlarge)
        }
        .navigationTitle("Support")
        .task(priority: .background) {
            discordRPC.setPresence({
                var presence = RichPresence()
                presence.details = "Looking for help"
                presence.state = "Viewing Support"
                presence.timestamps.start = .now
                presence.assets.largeImage = "macos_512x512_2x"
                return presence
            }())
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        systemImage: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label(title, systemImage: systemImage)
                .font(Theme.Text.sectionTitle)

            VStack(spacing: Theme.Spacing.small) {
                content()
            }
        }
    }
}

/// One place to go, as a row you can hit anywhere along.
private struct SupportLinkRow: View {
    let title: String
    let description: String
    let systemImage: String
    let url: URL

    @State private var isHovering: Bool = false

    private var shape: RoundedRectangle { .init(cornerRadius: Theme.Radius.card, style: .continuous) }

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: Theme.Spacing.large) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(isHovering ? .white : Theme.Palette.brand)
                    .frame(width: 34, height: 34)
                    .background {
                        Circle().fill(Theme.Palette.brand.opacity(isHovering ? 0.9 : 0.18))
                    }

                VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
                    Text(title)
                        .font(.system(.headline, weight: .semibold))

                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: Theme.Spacing.medium)

                Image(systemName: "arrow.up.forward")
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .background(Theme.Palette.panel, in: shape)
        .overlay {
            shape.strokeBorder(isHovering ? Theme.Palette.brand.opacity(0.6) : Theme.Palette.hairline,
                               lineWidth: 1)
        }
        .animation(Theme.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .help(url.absoluteString)
    }
}

public class SupportWindowController: NSWindowController {
    static var shared: SupportWindowController?

    convenience init() {
        let supportView = SupportView()
        let hosting = NSHostingController(rootView: supportView)

        let window = NSWindow(
            // 400×300 was enough for five bare buttons and not enough for anything else:
            // the rebuilt view scrolled inside it with two rows visible at a time.
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 660),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )

        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden

        window.contentMinSize = .init(width: 520, height: 420)

        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .sidebar
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 28),
            hosting.view.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        window.contentView = visualEffectView
        window.center()
        self.init(window: window)
    }

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let controller = SupportWindowController()
            shared = controller
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

#Preview {
    SupportView()
}
