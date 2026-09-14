//
//  Surfaces.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI

/**
 The one place that knows there are two macOS design languages to draw for.

 The app supports macOS 14 and later, and Liquid Glass arrived in macOS 26. Before this
 file, that fact was spread across eighteen `#available(macOS 26.0, *)` checks inlined in
 views — which is why the interface looked like a macOS 14 interface with glass stickered
 onto whichever parts someone had got around to: the two branches drifted, the older one was
 nobody's design, and no single change could improve both.

 Here, every surface is asked for by role — a floating control, a panel, a card — and this
 file decides how that role is drawn on the running system. Liquid Glass where it exists; a
 material with a top-lit edge where it doesn't, which is the detail that makes the fallback
 read as glass rather than as a grey box.
 */

// MARK: - Roles

extension View {
    /// A control or panel that floats over content — artwork, a scrolling list, a hero.
    ///
    /// - Parameter interactive: pass `true` for something the pointer acts on, which on
    ///   macOS 26 lets the glass respond to the pointer as a control rather than sit inert.
    func floatingSurface<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(FloatingSurface(shape: shape, interactive: interactive))
    }

    /// ``floatingSurface(in:interactive:)`` on a continuously-rounded rectangle.
    func floatingSurface(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        floatingSurface(in: .rect(cornerRadius: cornerRadius, style: .continuous),
                        interactive: interactive)
    }

    /// ``floatingSurface(in:interactive:)`` on a capsule — the shape of every pill control here.
    func floatingCapsule(interactive: Bool = false) -> some View {
        floatingSurface(in: .capsule, interactive: interactive)
    }

    /// Content that sits *on* the window rather than over other content: a card in a grid,
    /// a row in a list, a panel of settings. Opaque, bordered, and optionally lifted.
    func cardSurface(cornerRadius: CGFloat = Theme.Radius.card, elevated: Bool = true) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, elevated: elevated))
    }

    /// A hairline border, in the system's separator colour so it survives dark mode and
    /// increased contrast.
    func hairlineBorder<S: InsettableShape>(_ shape: S) -> some View {
        overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: Theme.Spacing.hairline))
    }

    /// Darkens the bottom of artwork so text laid over it stays readable.
    ///
    /// Unconditional, and this is the point: the old cards flipped their foreground to white
    /// only once an image had loaded, so a title was black-on-grey, then white-on-art, and
    /// illegible in the moment between. A scrim that is always there means the text colour
    /// never has to be a question.
    func artworkScrim(height: CGFloat? = nil, opacity: CGFloat = 0.88) -> some View {
        overlay(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(opacity * 0.45), location: 0.55),
                    .init(color: .black.opacity(opacity), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }

    /// Dissolves the bottom edge of full-bleed artwork into whatever is behind it.
    ///
    /// Apply to the artwork *and its scrim*, not to the artwork alone, or the scrim keeps
    /// painting a dark band over the page below. A mask rather than a final gradient stop in
    /// the page's own colour: `NSColor.windowBackgroundColor` is not opaque in a window like
    /// this one, so blending into it let the brightest part of a cover — the glare across
    /// the bottom of Blades of Time's — show back through as a band.
    func artworkFadesOut(over fraction: CGFloat = 0.06) -> some View {
        mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 1 - fraction),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

extension View {
    /// Lets artwork run up under the window's title bar without the title and its background
    /// reappearing over the top.
    ///
    /// The toolbar returning on every view reload inside a `NavigationSplitView` is an old
    /// bug worked around here rather than in each view that happens to start with a picture.
    /// Undoes ``artworkUnderTitleBar()`` for a view that does *not* start with a picture.
    ///
    /// Toolbar visibility set in one `NavigationStack` destination leaks to its siblings, so
    /// once Home has hidden the title bar's background every other shelf inherits it and its
    /// content scrolls up behind bare toolbar buttons. Stating the ordinary case explicitly
    /// is the only reliable way to get it back.
    func standardTitleBar() -> some View {
        Group {
            if #available(macOS 15.0, *) {
                self.toolbarBackgroundVisibility(.automatic)
            } else {
                self.toolbarBackground(.automatic)
            }
        }
    }

    func artworkUnderTitleBar() -> some View {
        Group {
            if #available(macOS 15.0, *) {
                self
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden)
            } else {
                self
                    .toolbarBackground(.hidden)
            }
        }
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Implementations

private struct FloatingSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool

    /// Draws the pre-macOS-26 surfaces on a machine that has Liquid Glass.
    ///
    /// The app supports macOS 14, so half of this file never runs on the machine it is
    /// developed on — which is running Tahoe. A fallback nobody can look at is a fallback
    /// that ships broken, so Settings ▸ View offers a switch for it in debug builds.
    @AppStorage("forceLegacyAppearance") private var forcesLegacyAppearance: Bool = false

    private var usesLegacyAppearance: Bool {
#if DEBUG
        forcesLegacyAppearance
#else
        false
#endif
    }

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *), !usesLegacyAppearance {
                content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    // The edge is what sells it. Glass on macOS 26 is lit from above, so the
                    // top of its border is bright and the bottom nearly vanishes; a uniform
                    // stroke instead reads as a drawn outline, which is the single biggest
                    // giveaway of a hand-made material.
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.38), .white.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                    )
                    .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
            }
        }
    }
}

private struct CardSurface: ViewModifier {
    let cornerRadius: CGFloat
    let elevated: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle { .init(cornerRadius: cornerRadius, style: .continuous) }

    func body(content: Content) -> some View {
        content
            .background(Theme.Palette.surface, in: shape)
            .hairlineBorder(shape)
            .shadow(
                color: .black.opacity(elevated ? (colorScheme == .dark ? 0.34 : 0.10) : 0),
                radius: elevated ? 10 : 0,
                y: elevated ? 3 : 0
            )
    }
}

// MARK: - Prominent button

/// The app's one prominent button: brand-tinted, capsule, and the same on every system.
///
/// Replaces a hard-coded white pill with black text, which was the Play button's previous
/// look and the one thing on screen that could not be themed, tinted, or read in light mode.
struct PortalProminentButtonStyle: ButtonStyle {
    var isCompact: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(isCompact ? .footnote : .body, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, isCompact ? Theme.Spacing.medium : Theme.Spacing.large)
            .padding(.vertical, isCompact ? Theme.Spacing.xsmall + 1 : Theme.Spacing.small)
            .background {
                Capsule(style: .continuous)
                    .fill(Theme.Palette.portal)
                    .opacity(isEnabled ? 1 : 0.4)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.8)
            }
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PortalProminentButtonStyle {
    static var portalProminent: PortalProminentButtonStyle { .init() }
    static var portalProminentCompact: PortalProminentButtonStyle { .init(isCompact: true) }
}

// MARK: - Badge

/// A small label for a fact about a game: its storefront, its state, its graphics backend.
///
/// Replaces `SubscriptedTextView`'s stroked rectangle, which had no fill and so disappeared
/// against artwork, and whose `.caption` text in a card's leftover width rendered "Recent"
/// as "Re...".
struct PortalBadge: View {
    let text: String
    var systemImage: String?
    var tint: Color?

    init(_ text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xsmall - 1) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }

            Text(text)
                .lineLimit(1)
        }
        .font(Theme.Text.badge)
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, Theme.Spacing.small - 2)
        .padding(.vertical, Theme.Spacing.tiny)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                .fill((tint ?? .secondary).opacity(0.14))
        }
        .help(text)
    }
}

#Preview("Surfaces") {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        HStack {
            Button("Play", systemImage: "play.fill") {}
                .buttonStyle(.portalProminent)

            Button("Install", systemImage: "arrow.down.to.line") {}
                .buttonStyle(.portalProminentCompact)
        }

        HStack {
            PortalBadge("GOG", systemImage: "building.columns")
            PortalBadge("Installed", tint: .green)
            PortalBadge("DXMT", systemImage: "cpu", tint: Theme.Palette.brandSecondary)
        }

        Text("Floating over artwork")
            .padding()
            .floatingSurface(cornerRadius: Theme.Radius.panel)

        Text("On the window")
            .padding()
            .cardSurface()
    }
    .padding(Theme.Spacing.xlarge)
    .frame(width: 420)
}
