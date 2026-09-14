//
//  Theme.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI
import AppKit

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

        /// ``brand``, lightened — what a control does under the pointer.
        static let brandHighlight: Color = .init(red: 0.51, green: 0.33, blue: 0.98)

        /// For a control whose action destroys something. Deliberately *not* violet: a
        /// Delete button that looks exactly like a Play button is a design that will
        /// eventually cost somebody a 27GB install.
        static let destructive: Color = .init(red: 0.90, green: 0.29, blue: 0.35)
        static let destructiveHighlight: Color = .init(red: 0.95, green: 0.42, blue: 0.47)

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
        ///
        /// - Warning: not opaque. `NSColor.windowBackgroundColor` in a window like this one
        ///   is a vibrant colour, so anything drawn *over* artwork with it lets the artwork
        ///   through. Use ``sheet`` for a surface that has to be solid.
        static let canvas: Color = .init(nsColor: .windowBackgroundColor)

        /// The ground under a sheet: opaque, faintly violet, and the same whether the window
        /// is focused or not.
        ///
        /// Sheets used to take the system's own material, which on macOS 26 picks up the
        /// app's tint while the window is active and desaturates to grey the moment it
        /// isn't — so the installation sheet changed colour when you clicked away from the
        /// app, and again on its way out. A fixed colour keeps the violet and stops the
        /// texture from reporting on the window's focus.
        static let sheet: Color = dynamic(dark: .init(red: 0.086, green: 0.075, blue: 0.118, alpha: 1),
                                          light: .init(red: 0.957, green: 0.949, blue: 0.976, alpha: 1))

        /// A panel *inside* a sheet — one step up from ``sheet``.
        static let panel: Color = dynamic(dark: .init(red: 0.137, green: 0.122, blue: 0.180, alpha: 1),
                                          light: .init(red: 1, green: 1, blue: 1, alpha: 1))

        /// A colour that resolves itself per appearance without going through a material.
        private static func dynamic(dark: NSColor, light: NSColor) -> Color {
            .init(nsColor: .init(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
        }
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
        static let spacing: CGFloat = Spacing.large

        /// The width a card is given at ``GameCardSize/regular``, before scaling.
        static let baseCardWidth: CGFloat = 200

        /// The same, on a shelf, where the row scrolls instead of wrapping so a card can be
        /// smaller without leaving the grid ragged.
        static let baseShelfCardWidth: CGFloat = 150
    }
}

/// How big the game cards are, in three steps of 30%.
///
/// Replaces a `Slider` over a raw point width from 200 to 400, labelled "Gamecard Size" and
/// subtitled "Default is 1 tick." — which gave nine indistinguishable positions, none of them
/// named, and no way to tell which one you were on.
enum GameCardSize: String, CaseIterable, Codable, Identifiable {
    case small
    case regular
    case large

    var id: String { rawValue }

    /// Stored as a name rather than as its multiplier: a `Double` raw value has to come back
    /// out of `UserDefaults` bit-identical to match a case, and 0.7 is not a number worth
    /// betting an interface on.
    var multiplier: CGFloat {
        switch self {
        case .small:    0.7
        case .regular:  1.0
        case .large:    1.3
        }
    }

    var description: String {
        switch self {
        case .small:    String(localized: "Small")
        case .regular:  String(localized: "Medium")
        case .large:    String(localized: "Large")
        }
    }

    var cardWidth: CGFloat { (Theme.Grid.baseCardWidth * multiplier).rounded() }
    var shelfCardWidth: CGFloat { (Theme.Grid.baseShelfCardWidth * multiplier).rounded() }

    /// The next size up or down, or `nil` at either end — which is what disables the buttons.
    func stepped(by offset: Int) -> GameCardSize? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return nil }
        let target = index + offset
        guard all.indices.contains(target) else { return nil }
        return all[target]
    }

    /// A key of its own rather than reusing `gameCardSize`, which holds a `Double` from the
    /// slider this replaces.
    static let storageKey: String = "gameCardSizeStep"
}

extension ShapeStyle where Self == Color {
    /// Shorthand for the brand violet at call sites that read better without the namespace.
    static var brand: Color { Theme.Palette.brand }
}
