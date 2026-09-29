//
//  RenderPathRegressionTests.swift
//  PorTalisticTests
//
//  Created by Claude Opus 5 on 15/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Observation
import SwiftUI
import Testing

@testable import PorTalistic

/**
 What the views that exist once per game are allowed to store.

 Scrolling a full-screen library was measured at three hundred `GameCard` bodies a second
 against three `GameArtwork` bodies, for the same thirty visible cards. The difference was
 not the artwork: `Binding` is not equatable, so a view that stores one can never be skipped,
 and SwiftUI had to re-run every card's body on every layout pass. `@AppStorage` is the same
 shape of mistake at a different scale — each one is a defaults observer, and every one of
 them wakes on any write, including the library encoding itself.

 Checked by reflection rather than by reading the file, because the property has to be gone
 from the type, not merely commented out.
 */
@Suite("Render path")
@MainActor
struct RenderPathRegressionTests {
    /// Stored properties whose type makes the view unskippable.
    ///
    /// A non-optional `Binding` is the fault. An optional one left `nil` — `GameArtwork`'s
    /// `isArtworkPresent`, for callers that want to be told when real art appears — costs
    /// nothing while nobody passes it, so it is not what this is looking for.
    private func unskippableStorage(in view: some View) -> [String] {
        Mirror(reflecting: view).children.compactMap { (child) -> String? in
            let type = String(describing: Swift.type(of: child.value))
            guard type.hasPrefix("Binding<") || type.hasPrefix("AppStorage<") else { return nil }

            return "\(child.label ?? "?"): \(type)"
        }
    }

    @Test("The card that exists once per game stores nothing that stops it being skipped")
    func gameCardIsSkippable() {
        let game: LocalGame = .init(id: "render-path", title: "Render Path", installationState: .uninstalled)
        let found = unskippableStorage(in: GameCard(game: game, hover: .init()))

        #expect(found.isEmpty, """
            GameCard stores \(found.joined(separator: ", ")). A card that stores a Binding \
            re-runs its body on every layout pass of the enclosing grid — three hundred a \
            second during a scroll — and an @AppStorage in a card is one defaults observer \
            per card. Pass the value in from the grid instead; `Game` is a class, so a \
            binding to it buys nothing.
            """)
    }

    @Test("The row that exists once per game stores nothing that stops it being skipped")
    func listGameCardIsSkippable() {
        let game: LocalGame = .init(id: "render-path", title: "Render Path", installationState: .uninstalled)
        let found = unskippableStorage(in: ListGameCard(game: game, hover: .init()))

        #expect(found.isEmpty, "ListGameCard stores \(found.joined(separator: ", "))")
    }

    @Test("Artwork takes plain values")
    func artworkIsSkippable() {
        let game: LocalGame = .init(id: "render-path", title: "Render Path", installationState: .uninstalled)
        let found = unskippableStorage(in: GameArtwork(game: game, url: nil, orientation: .horizontal))

        #expect(found.isEmpty, "GameArtwork stores \(found.joined(separator: ", "))")
    }

    @Test("Hover is one identifier for a whole grid")
    func hoverStateNamesOneCard() {
        // `.onHover` in a lazy grid does not reliably deliver the exit event, so a card that
        // scrolls out from under a stationary pointer keeps its own hover state forever —
        // which looked like a random card in the library sitting there with its Play button
        // showing while the pointer was in the sidebar. One identifier can only name one.
        let hover: CardHoverState = .init()

        #expect(hover.gameID == nil)
        #expect(hover.isScrolling == false)

        hover.gameID = "first"
        hover.gameID = "second"

        #expect(hover.gameID == "second")
    }

    @Test("A hover that changes nothing redraws nothing")
    func redundantHoverWritesAreNotAnnounced() {
        // `@Observable` announces every write, including one that changes nothing, and every
        // card on screen reads the hovered id — so clearing an id that was already clear, which
        // happened at the start of every scroll, redrew every card at once.
        let hover: CardHoverState = .init()
        let announced: Announcements = .init()

        withObservationTracking { _ = hover.gameID } onChange: { announced.count += 1 }
        hover.clear()
        hover.pointer(isOver: false, gameID: "a card the pointer never reached")
        #expect(announced.count == 0)

        hover.pointer(isOver: true, gameID: "card")
        #expect(announced.count == 1)
        #expect(hover.gameID == "card")

        withObservationTracking { _ = hover.gameID } onChange: { announced.count += 1 }
        hover.pointer(isOver: true, gameID: "card")
        #expect(announced.count == 1, "the pointer arriving again on the card it is already on")

        hover.pointer(isOver: false, gameID: "card")
        #expect(announced.count == 2)
        #expect(hover.gameID == nil)
    }
}

/// Counts change notifications. A class so the `@Sendable` change handler can reach it.
private final class Announcements: @unchecked Sendable {
    var count: Int = 0
}
