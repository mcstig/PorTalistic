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
    /// Shows a control only while the pointer is on its card, without taking it out of the
    /// view hierarchy.
    ///
    /// The distinction matters because a control that presents a sheet or an alert owns the
    /// `@State` behind it. Removing the control while its sheet is up destroys that state and
    /// the sheet closes itself — and a sheet covering the card is exactly what makes hover go
    /// false, so the control removes itself the instant it succeeds. Opacity and hit testing
    /// hide it; nothing unmounts it.
    /// Hit testing is gated so an invisible control can't swallow a click meant for the card
    /// underneath it. Accessibility is deliberately *not*: an AX press reaches an element
    /// directly, so leaving these visible to VoiceOver is what lets someone play or install a
    /// game from the grid at all — hover is not a gesture every user has.
    func revealedOnHover(_ isRevealed: Bool) -> some View {
        opacity(isRevealed ? 1 : 0)
            .allowsHitTesting(isRevealed)
    }

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

// MARK: - Buttons

/// Every button in the app, in three degrees of emphasis.
///
/// There were eight different button styles in use — `.borderedProminent` in nineteen
/// places, `.borderless` in nine, `.bordered`, `.accessoryBar`, `.plain` — which is why the
/// app looked assembled rather than designed, and why the hover state was invisible: the
/// system's hover on a bordered button is a two-percent change in a grey fill.
///
/// Here the pointer always gets an answer, and the answer is the same everywhere.
struct PortalButtonStyle: ButtonStyle {
    enum Emphasis {
        /// The one thing to do on this screen: the brand gradient. Play, Install, Continue.
        case prominent
        /// An ordinary action: solid violet.
        case standard
        /// An icon in a row or a toolbar, where a solid block of colour would be noise —
        /// no fill until the pointer arrives, and then a clear violet one.
        case quiet
    }

    var emphasis: Emphasis = .standard
    var isCompact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, emphasis: emphasis, isCompact: isCompact)
    }

    /// A `ButtonStyle` cannot hold state or read hover itself, so the body is a real view.
    ///
    /// Named `StyleBody` rather than `Body` because `ButtonStyle` declares an associated type
    /// by that name, and a nested `Body` is taken as the witness for it.
    private struct StyleBody: View {
        let configuration: Configuration
        let emphasis: Emphasis
        let isCompact: Bool

        @State private var isHovering: Bool = false
        @Environment(\.isEnabled) private var isEnabled

        /// Destructive buttons stay red. The instruction was "all buttons purple", and this
        /// is the one place worth arguing with: Delete and Sign Out reading exactly like
        /// Play is how somebody eventually removes a 27GB install by muscle memory.
        private var isDestructive: Bool { configuration.role == .destructive }

        private var baseColor: Color {
            isDestructive ? Theme.Palette.destructive : Theme.Palette.brand
        }

        private var highlightColor: Color {
            isDestructive ? Theme.Palette.destructiveHighlight : Theme.Palette.brandHighlight
        }

        private var shape: Capsule { .init(style: .continuous) }

        var body: some View {
            configuration.label
                .font(.system(isCompact ? .footnote : .body, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, isCompact ? Theme.Spacing.xsmall + 1 : Theme.Spacing.small)
                .background { background }
                .overlay {
                    if emphasis != .quiet {
                        shape.strokeBorder(.white.opacity(isEnabled ? 0.22 : 0.08), lineWidth: 0.8)
                    }
                }
                .contentShape(.capsule)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(Theme.Motion.hover, value: isHovering)
                .onHover { isHovering = $0 }
        }

        /// Icon-only buttons get square padding so they come out round rather than oval.
        private var horizontalPadding: CGFloat {
            switch emphasis {
            case .quiet:    isCompact ? Theme.Spacing.small - 2 : Theme.Spacing.small
            default:        isCompact ? Theme.Spacing.medium : Theme.Spacing.large
            }
        }

        private var foreground: Color {
            guard isEnabled else { return emphasis == .quiet ? .secondary : .white.opacity(0.55) }

            switch emphasis {
            case .prominent, .standard:
                return .white
            case .quiet:
                // White once there's a violet fill behind it; the ordinary foreground until
                // then, so a row of icons doesn't read as a row of links.
                return isHovering ? .white : .primary
            }
        }

        @ViewBuilder
        private var background: some View {
            switch emphasis {
            case .prominent:
                shape
                    .fill(Theme.Palette.portal)
                    .opacity(isEnabled ? 1 : 0.4)
                    .brightness(brightnessAdjustment)
            case .standard:
                shape
                    .fill(isHovering && isEnabled ? highlightColor : baseColor)
                    .opacity(isEnabled ? 1 : 0.4)
                    .brightness(configuration.isPressed ? -0.06 : 0)
            case .quiet:
                shape
                    .fill(baseColor.opacity(isHovering && isEnabled ? (configuration.isPressed ? 1 : 0.85) : 0))
            }
        }

        private var brightnessAdjustment: Double {
            if configuration.isPressed { return -0.07 }
            return isHovering && isEnabled ? 0.10 : 0
        }
    }
}

extension ButtonStyle where Self == PortalButtonStyle {
    /// The one thing to do on this screen.
    static var portalProminent: PortalButtonStyle { .init(emphasis: .prominent) }
    static var portalProminentCompact: PortalButtonStyle { .init(emphasis: .prominent, isCompact: true) }

    /// An ordinary action.
    static var portal: PortalButtonStyle { .init(emphasis: .standard) }
    static var portalCompact: PortalButtonStyle { .init(emphasis: .standard, isCompact: true) }

    /// An icon in a row, a toolbar, or beside a field.
    static var portalQuiet: PortalButtonStyle { .init(emphasis: .quiet) }
    static var portalQuietCompact: PortalButtonStyle { .init(emphasis: .quiet, isCompact: true) }
}

/// A row in a selectable rail — the storefront list in Import Game, and anywhere else a
/// short list of choices sits beside its content.
struct PortalRailButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, isSelected: isSelected)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let isSelected: Bool

        @State private var isHovering: Bool = false

        private var shape: RoundedRectangle { .init(cornerRadius: Theme.Radius.control, style: .continuous) }

        var body: some View {
            configuration.label
                .font(.system(.body, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected || isHovering ? .white : .primary)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.small - 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    shape.fill(Theme.Palette.brand.opacity(fillOpacity))
                }
                .contentShape(.rect)
                .animation(Theme.Motion.hover, value: isHovering)
                .onHover { isHovering = $0 }
        }

        private var fillOpacity: Double {
            if isSelected { return 1 }
            return isHovering ? (configuration.isPressed ? 0.9 : 0.35) : 0
        }
    }
}

// MARK: - Sheets

extension View {
    /// The app's own ground and button style: opaque, faintly violet, focus-independent.
    ///
    /// For a sheet, a secondary window, or any page that isn't part of the main window's
    /// scroll. Not only sheets, despite where it started.
    ///
    /// The style is set here rather than at each call site because the sheets are where the
    /// unstyled `Button`s live — Cancel, Done, Browse…, Sign Out, Refresh Library — and
    /// there are dozens of them. Set as the environment default, so any button that asks for
    /// something specific still gets it.
    func brandedSurface() -> some View {
        background(Theme.Palette.sheet)
            .buttonStyle(.portalCompact)
    }

    /// ``sheetBackground()`` plus a definite size.
    ///
    /// The size is not decoration. A sheet that leaves its dimensions to whatever its
    /// content asks for is at the mercy of what proposes that height — which is how the
    /// import sheet ended up rendering "Otherwise, browse for a thumbnail file:" as six
    /// wrapped lines in a seventy-point column, and how its GOG tab ended up laying out its
    /// contents sixteen hundred points above the top of the sheet.
    func sheetSurface(minWidth: CGFloat = 680,
                      idealWidth: CGFloat? = nil,
                      minHeight: CGFloat = 400,
                      idealHeight: CGFloat? = nil) -> some View {
        frame(minWidth: minWidth,
              idealWidth: idealWidth ?? minWidth,
              minHeight: minHeight,
              idealHeight: idealHeight ?? minHeight)
            .brandedSurface()
    }

    /// A `Form` that belongs to this app rather than to System Settings.
    ///
    /// `.formStyle(.grouped)` is the right *structure* — labelled rows, sections, the
    /// alignment macOS expects, and every `Toggle` and `Picker` in the app laid out the same
    /// way without each view having to say so. It is the wrong *ground*: it paints the
    /// system's grouped background, which is vibrant, takes a tint from the app's accent
    /// while the window is active and washes out when it isn't — the same flicker the sheets
    /// had before ``Theme/Palette/sheet``. So the structure is kept and the ground is
    /// dropped, and whatever the form sits on shows through.
    func portalForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }

    /// A panel of related controls inside a sheet or a page.
    func panelSurface(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return background(Theme.Palette.panel, in: shape)
            .hairlineBorder(shape)
    }
}

// MARK: - Game sheet header

/**
 The top of a sheet that acts on one game: its cover, what you're about to do, and the
 facts worth knowing before you do it.

 Written once because the three installation sheets and the three uninstallation sheets all
 had their own copy of it, and they had drifted: each drew
 `Text("Install \(game.description)")` — and `Game.description` is `"\(title)"`, quotation
 marks included — so the heading came out as `Install "Heroes of Might and Magic® 3:
 Complete"`, at `.title` weight, wrapping to two lines inside its own punctuation. The verb
 belongs in an eyebrow above the name, not in a sentence with it.
 */
struct GameSheetHeader<Content: View>: View {
    let game: Game

    /// "Install", "Uninstall" — shown above the name, not wrapped around it.
    let action: String

    /// Facts about what's about to happen: a download size, a platform.
    var badges: [PortalBadge] = []

    /// How much of the sheet the cover gets.
    ///
    /// An installation sheet is mostly about the game, so the cover leads. A settings sheet
    /// is mostly about a long list of controls, and a full-height cover there just pushes
    /// them off the bottom — which is exactly what the old one did.
    var coverWidth: CGFloat = 170

    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xlarge) {
            GameArtwork(game: game, url: game.verticalImageURL, cornerRadius: Theme.Radius.card)
                .aspectRatio(Theme.Grid.artworkAspectRatio, contentMode: .fit)
                .frame(width: coverWidth)

            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                    Text(action.uppercased())
                        .font(Theme.Text.heroEyebrow)
                        .tracking(1.2)
                        .foregroundStyle(.secondary)

                    Text(game.title)
                        .font(.system(.title2, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Theme.Spacing.small) {
                    if let storefront = game.storefront {
                        PortalBadge(storefront.description,
                                    systemImage: storefront.symbolName,
                                    tint: storefront.tint)
                    }

                    ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                        badge
                    }
                }

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
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

            // An empty string means icon-only — which is how a badge survives a 140-point
            // card, where "Epic Games" has room to render as "Epic Ga…".
            if !text.isEmpty {
                Text(text)
                    .lineLimit(1)
            }
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
