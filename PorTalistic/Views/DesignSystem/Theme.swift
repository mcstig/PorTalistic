//
//  Theme.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI

/**
 The measurements and colours the interface is built out of.

 Collected rather than inlined because the old look came apart in exactly the way that
 scattered constants come apart: a corner radius of 20 on a 200-point card and on a
 1400-point hero, `.title` on a title that had eight characters of room, and a hard-coded
 white on artwork that might be missing. One set of tokens, chosen once, is what makes a
 window look designed instead of assembled.
 */
enum Theme {
    /// A 4-point rhythm. Sizes in between exist only where a control's own metrics demand it.
    enum Spacing {
        static let hairline: CGFloat = 1
        static let tiny: CGFloat = 2
        static let xsmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xlarge: CGFloat = 24
        static let xxlarge: CGFloat = 32
        static let section: CGFloat = 40
    }

    /// Radii by the size of the thing being rounded, not one value used everywhere.
    ///
    /// A radius reads as a proportion of the shape it's on: 20 points is a soft, friendly
    /// corner on a hero and a bulbous one on a 24-point badge. macOS rounds with
    /// `.continuous` curvature throughout, so everything here does too.
    enum Radius {
        static let badge: CGFloat = 6
        static let control: CGFloat = 9
        static let tile: CGFloat = 12
        static let card: CGFloat = 16
        static let panel: CGFloat = 20
        static let hero: CGFloat = 28
    }

    enum Palette {
        /// The brand violet, read from the asset rather than through `Color.accentColor`.
        ///
        /// `.accentColor` follows the *system* accent, so the app's own prominent buttons
        /// came out whatever colour the user had picked in System Settings — salmon, on the
        /// machine this was built on. An identity that changes colour behind your back isn't
        /// one, so brand surfaces take the asset directly and the app tints its controls to
        /// match.
        static let brand: Color = .init("AccentColor")

        /// The far side of the portal. Only ever seen next to ``brand``, in a gradient.
        static let brandSecondary: Color = .init(red: 0.16, green: 0.78, blue: 0.95)

        /// The app's one gradient. Used for identity, never for large areas of chrome.
        static let portal: LinearGradient = .init(
            colors: [brand, brandSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// The system separator, which already knows what to do in light and dark and at
        /// increased contrast. Hand-rolled `white.opacity(0.1)` borders do not.
        static let hairline: Color = .init(nsColor: .separatorColor)

        /// Background for content that sits on the window, one step up from it.
        static let surface: Color = .init(nsColor: .controlBackgroundColor)

        /// The floor behind everything.
        static let canvas: Color = .init(nsColor: .windowBackgroundColor)
    }

    /// Type roles, so a card title is one decision rather than a guess per call site.
    enum Text {
        static let heroTitle: Font = .system(size: 38, weight: .bold)
        static let heroEyebrow: Font = .system(.caption, weight: .semibold)
        static let sectionTitle: Font = .system(.title3, weight: .bold)
        static let cardTitle: Font = .system(.subheadline, weight: .semibold)
        static let cardSubtitle: Font = .system(.caption)
        static let badge: Font = .system(.caption2, weight: .medium)
        static let rowTitle: Font = .system(.headline, weight: .semibold)
    }

    enum Motion {
        /// Hover and reveal. Short enough not to lag the pointer, long enough to be seen.
        static let hover: Animation = .easeOut(duration: 0.16)
        /// Layout changes the user asked for — switching layout, expanding a section.
        static let layout: Animation = .easeInOut(duration: 0.24)
    }

    /// Grid metrics for the library.
    enum Grid {
        /// Artwork is 3:4 because that is the shape of every storefront's portrait cover.
        static let artworkAspectRatio: CGFloat = 3.0 / 4.0
        /// Room under the artwork for two lines of title and a line of badges.
        static let captionHeight: CGFloat = 52
        static let spacing: CGFloat = Spacing.large
        /// The width a card is given on a shelf, where the row scrolls instead of wrapping.
        static let shelfCardWidth: CGFloat = 150
    }
}

extension ShapeStyle where Self == Color {
    /// Shorthand for the brand violet at call sites that read better without the namespace.
    static var brand: Color { Theme.Palette.brand }
}
