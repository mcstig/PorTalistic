//
//  LibraryFilterRegressionTests.swift
//  PorTalisticTests
//
//  Created by Claude Opus 5 on 15/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Testing

@testable import PorTalistic

/**
 The filters over the library, and the way out of them.

 Picking Steam emptied the library — Steam is hidden and has no games — and the controls that
 could have undone it were gated on the filtered result being non-empty, so there was no way
 back. Filtering by macOS did the same thing for the same reason. The lesson is in
 ``GameListViewModel/hasAnyGames(inStorefront:)``: a filter control has to be judged against
 the unfiltered library, never against its own output.
 */
@Suite("Library filters")
@MainActor
struct LibraryFilterRegressionTests {
    @Test("Steam is not offered as a filter while Steam is hidden")
    func steamIsNotOffered() {
        #expect(Steam.isEnabled == false,
                "this test describes the hidden case — rewrite it when Steam comes back")
        #expect(Game.Storefront.available.contains(.steam) == false,
                "a token whose only possible effect is to empty the library")
        #expect(Game.Storefront.allCases.contains(.steam),
                "the case itself stays, so games already stored keep decoding")

        let model: GameListViewModel = .init()
        #expect(model.suggestedTokens.contains(.storefront(.steam)) == false)
    }

    @Test("Every offered storefront token is one the user can act on")
    func offeredTokensAreUsable() {
        let model: GameListViewModel = .init()

        for token in model.suggestedTokens {
            guard case .storefront(let storefront) = token else { continue }
            #expect(storefront.isAvailable)
        }
    }

    @Test("Filters can always be cleared")
    func filtersCanBeCleared() {
        let model: GameListViewModel = .init()
        #expect(model.isFiltering == false)

        model.searchTokens = [.storefront(.gog)]
        #expect(model.isFiltering)

        model.clearFilters()
        #expect(model.isFiltering == false)
        #expect(model.searchTokens.isEmpty)
        #expect(model.searchString.isEmpty)
    }

    @Test("Typed text counts as filtering")
    func searchTextCountsAsFiltering() {
        let model: GameListViewModel = .init()

        model.searchString = "prey"
        #expect(model.isFiltering, "otherwise the Clear Filters control hides while a search is narrowing the list")

        model.clearFilters()
        #expect(model.isFiltering == false)
    }

    @Test("Whether a shelf holds games is not a question about the filter")
    func hasAnyGamesIgnoresFilters() {
        // This is the actual fix. `hasAnyGames` gates the toolbar; asking the *filtered*
        // library instead is what removed the Filters menu at the one moment it was needed.
        let model: GameListViewModel = .init()
        let unfiltered = model.hasAnyGames(inStorefront: nil)

        model.searchString = "no game is called this: \(UUID().uuidString)"
        model.searchTokens = [.storefront(.steam), .platform(.macOS)]

        #expect(model.library(inStorefront: nil).isEmpty, "the filter really does match nothing")
        #expect(model.hasAnyGames(inStorefront: nil) == unfiltered)
    }

    @Test("Only one filter of each kind applies at a time")
    func filtersOfTheSameKindReplaceEachOther() {
        let model: GameListViewModel = .init()

        model.searchTokens = [.platform(.windows), .platform(.macOS)]
        #expect(model.searchTokens == [.platform(.macOS)])

        model.searchTokens = [.storefront(.gog), .storefront(.epicGames)]
        #expect(model.searchTokens == [.storefront(.epicGames)])

        model.searchTokens = [.installed, .notInstalled]
        #expect(model.searchTokens == [.notInstalled],
                "installed and not-installed at once is a filter that can only match nothing")
    }

    @Test("Filters of different kinds stack")
    func filtersOfDifferentKindsStack() {
        let model: GameListViewModel = .init()

        model.searchTokens = [.storefront(.gog), .platform(.windows), .installed, .favourited]
        #expect(model.searchTokens.count == 4)
    }
}

/**
 The order the library is shown in.

 Asked for as A to Z and Z to A, with installed games first unless that is switched off. Before
 that the library had one order and it was not quite alphabetical: names were compared with
 `<`, which compares code points, so a name starting with a lowercase letter came after every
 capitalised one and "Game 10" came before "Game 2".
 */
@Suite("Library order")
@MainActor
struct LibraryOrderTests {
    private func game(_ title: String, installed: Bool = true, id: String? = nil) -> Game {
        LocalGame(id: id ?? title,
                  title: title,
                  installationState: installed
                    ? .installed(location: .temporaryDirectory.appending(path: "PorTalisticTests-Order"), platform: .windows)
                    : .uninstalled)
    }

    private func ordered(_ games: [Game],
                         operating: Set<Game.ID> = [],
                         _ titleOrder: GameListViewModel.TitleOrder = .ascending,
                         installedFirst: Bool = true) -> [String] {
        GameListViewModel.ordered(games, operating: operating, titleOrder: titleOrder, installedFirst: installedFirst)
            .map(\.title)
    }

    private var mixedCase: [Game] {
        ["zelda", "Game 10", "Alan Wake", "Game 2", "alpha"].map { game($0) }
    }

    @Test("A to Z reads names the way a person does")
    func aToZ() {
        // Case doesn't matter and numbers count — Finder's order.
        #expect(ordered(mixedCase) == ["Alan Wake", "alpha", "Game 2", "Game 10", "zelda"])
    }

    @Test("Z to A is the same order the other way round")
    func zToA() {
        #expect(ordered(mixedCase, .descending) == ["zelda", "Game 10", "Game 2", "alpha", "Alan Wake"])
    }

    @Test("Installed games come first, each group in order, unless that is switched off")
    func installedFirst() {
        let games = [game("Blades of Time", installed: false),
                     game("Prey"),
                     game("Alan Wake", installed: false),
                     game("Horizon Chase Turbo")]

        #expect(ordered(games) == ["Horizon Chase Turbo", "Prey", "Alan Wake", "Blades of Time"])
        #expect(ordered(games, .descending) == ["Prey", "Horizon Chase Turbo", "Blades of Time", "Alan Wake"])
        #expect(ordered(games, installedFirst: false) == ["Alan Wake", "Blades of Time", "Horizon Chase Turbo", "Prey"])
    }

    @Test("A game being downloaded stays at the top, whatever the order")
    func workInProgressComesFirst() {
        let games = [game("Alan Wake"), game("Zelda", installed: false)]

        #expect(ordered(games, operating: ["Zelda"]) == ["Zelda", "Alan Wake"])
        #expect(ordered(games, operating: ["Zelda"], .descending, installedFirst: false) == ["Zelda", "Alan Wake"])
    }

    @Test("The same name on two storefronts always comes out the same way round")
    func sameNameIsDeterministic() {
        let epic = game("Prey", id: "epic-prey")
        let gog = game("Prey", id: "gog-prey")

        let one = GameListViewModel.ordered([gog, epic], operating: [], titleOrder: .ascending, installedFirst: true)
        let other = GameListViewModel.ordered([epic, gog], operating: [], titleOrder: .ascending, installedFirst: true)

        #expect(one.map(\.id) == other.map(\.id))
    }
}
