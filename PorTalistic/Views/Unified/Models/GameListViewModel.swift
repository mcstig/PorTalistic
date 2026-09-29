//
//  GameListViewModel.swift
//  Mythic
//
//  Created by Marcus Ziade on ~23/06/24.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import Combine
import OSLog

@Observable @MainActor final class GameListViewModel {
    static let shared: GameListViewModel = .init()

    var searchString: String = .init()
    var searchTokens: [SearchToken] = [] {
        didSet {
            let platforms: [SearchToken] = searchTokens.compactMap { if case .platform = $0 { $0 } else { nil } }
            let storefronts: [SearchToken] = searchTokens.compactMap { if case .storefront = $0 { $0 } else { nil } }
            let installations: [SearchToken] = searchTokens.filter { $0 == .installed || $0 == .notInstalled }
            
            if platforms.count > 1, let last = platforms.last {
                searchTokens.removeAll { if case .platform = $0 { $0 != last } else { false } }
            }
            if storefronts.count > 1, let last = storefronts.last {
                searchTokens.removeAll { if case .storefront = $0 { $0 != last } else { false } }
            }
            if installations.count > 1, let last = installations.last {
                searchTokens.removeAll { ($0 == .installed || $0 == .notInstalled) && $0 != last }
            }
        }
    }
    
    var sortedLibrary: [Game] { library(inStorefront: nil) }

    /// The library, filtered and ordered — one pass of each.
    ///
    /// Deliberately *not* implemented by pushing a `.storefront` search token: the tokens are
    /// the user's own filter, shared across the whole app, and having navigation quietly
    /// rewrite them means the sidebar and the filter menu fight each other.
    ///
    /// This was three chained `sorted(by:)` calls, then a `filter`, then a second `filter`
    /// for the storefront: five arrays, and the library sorted three times to produce one
    /// order. The last of those comparators read `Game.isOperating`, which scans the
    /// operation queue — so a sort did a linear search per comparison, and the whole thing
    /// depended on a queue that changes several times a second while anything is downloading.
    /// `GameListView` then asked for this three times per body pass.
    ///
    /// Filter first, because it is linear and the sort is not, and collect the operating
    /// games once before the sort rather than per comparison.
    func library(inStorefront storefront: Game.Storefront?,
                 titleOrder: TitleOrder = .ascending,
                 installedFirst: Bool = true) -> [Game] {
        // Installing, updating, repairing — work worth watching, and worth having at the top
        // while it happens. A *launch* is an operation too, and now that one lives as long as
        // the game does, including it here meant pressing Play tore the library apart and left
        // the game you were playing pinned to the front of it for the whole session.
        let operating: Set<Game.ID> = .init(
            GameOperationManager.shared.queue.lazy
                .filter { $0.isExecuting && $0.type.modifiesFiles }
                .map { $0.game.id }
        )

        // Annotated, and not by accident: `library` is a `Set`, so the unannotated `filter`
        // is `Set`'s, which hashes every game it keeps to build another set — for a
        // collection that is about to be sorted into an array anyway. The annotation picks
        // `Sequence.filter`, which is the array this returns.
        let matching: [Game] = GameDataStore.shared.library
            .filter { game in
                guard storefront == nil || game.storefront == storefront else { return false }

                let matchesText: Bool = searchString.isEmpty || game.title.localizedStandardContains(searchString)
                guard matchesText else { return false }

                return searchTokens.isEmpty || searchTokens.allSatisfy { token in
                    switch token {
                    case .platform(let platform):
                        // An installed game is the platform it was installed as; one that
                        // isn't is every platform it *offers*. Matching only the installed
                        // case meant these filters hid every uninstalled game in the library
                        // as well — a hundred and thirty of them — and filtering by a
                        // platform nothing happened to be installed as emptied the list.
                        if case .installed(_, let installedPlatform) = game.installationState {
                            return installedPlatform == platform
                        }

                        return game.getSupportedPlatforms()?.contains(platform) ?? false
                    case .storefront(let tokenStorefront):
                        return game.storefront == tokenStorefront
                    case .installed:
                        return game.isInstalled
                    case .notInstalled:
                        return !game.isInstalled
                    case .favourited:
                        return game.isFavourited
                    }
                }
            }

        return Self.ordered(matching, operating: operating, titleOrder: titleOrder, installedFirst: installedFirst)
    }

    /// The order the library is shown in: games being written to first, then — unless it has
    /// been turned off — installed games before the rest, and by name within each, A to Z or
    /// Z to A.
    ///
    /// One comparator, so the collection is walked once; as separate sorts, each pass had to
    /// undo some of the previous one's work. Pure and static, so the rule is tested without a
    /// library or an operation queue.
    nonisolated static func ordered(_ games: [Game],
                                    operating: Set<Game.ID>,
                                    titleOrder: TitleOrder,
                                    installedFirst: Bool) -> [Game] {
        games.sorted { lhs, rhs in
            let lhsOperating = operating.contains(lhs.id)
            let rhsOperating = operating.contains(rhs.id)
            if lhsOperating != rhsOperating { return lhsOperating }

            if installedFirst {
                let lhsInstalled = lhs.isInstalled
                let rhsInstalled = rhs.isInstalled
                if lhsInstalled != rhsInstalled { return lhsInstalled }
            }

            let comparison = Game.nameOrder(lhs, rhs)

            // The same name on two storefronts: always the same way round, rather than however
            // the sort happened to leave them, so the pair doesn't swap places on a refresh.
            if comparison == .orderedSame { return lhs.id < rhs.id }

            return (comparison == .orderedAscending) == (titleOrder == .ascending)
        }
    }

    var suggestedTokens: [SearchToken] {
        var suggestions: [SearchToken] = []
        
        let hasPlatform: Bool = searchTokens.contains { if case .platform = $0 { true } else { false } }
        let hasStorefront: Bool = searchTokens.contains { if case .storefront = $0 { true } else { false } }
        let hasInstallation: Bool = searchTokens.contains { $0 == .installed || $0 == .notInstalled }
        
        if !hasPlatform { suggestions.append(contentsOf: Game.Platform.allCases.map { .platform($0) }) }
        // `.available`, not `allCases`. Steam is behind a flag and has no games, so
        // suggesting it was offering a token whose only effect is to empty the library.
        if !hasStorefront { suggestions.append(contentsOf: Game.Storefront.available.map { .storefront($0) }) }
        if !hasInstallation { suggestions += [.installed, .notInstalled] }
        if !searchTokens.contains(.favourited) { suggestions.append(.favourited) }
        
        return suggestions
    }

    private let logger: Logger = .custom(category: "GameListViewModel")
    
    var isUpdatingLibrary: Bool = false

    /// Whether anything is narrowing the library right now.
    var isFiltering: Bool { !searchString.isEmpty || !searchTokens.isEmpty }

    /// Whether this shelf holds any games at all, filters ignored.
    ///
    /// The toolbar has to ask *this*, not whether the filtered result is empty. Gating the
    /// Layout picker, the card-size buttons and the Filters menu on `sortedLibrary.isEmpty`
    /// meant a filter that matched nothing removed the only controls that could undo it —
    /// so picking Steam, or macOS, left a blank library and no way back.
    func hasAnyGames(inStorefront storefront: Game.Storefront?) -> Bool {
        GameDataStore.shared.library.contains { storefront == nil || $0.storefront == storefront }
    }

    func clearFilters() {
        searchString = .init()
        searchTokens = .init()
    }
}

extension GameListViewModel {
    enum SearchToken: Identifiable, Hashable {
        case platform(Game.Platform)
        case storefront(Game.Storefront)
        case installed
        case notInstalled
        case favourited
        
        var id: String {
            switch self {
            case .platform(let platform):
                return "platform_\(platform.description)"
            case .storefront(let storefront):
                return "storefront_\(storefront.description)"
            case .installed:
                return "installed"
            case .notInstalled:
                return "notInstalled"
            case .favourited:
                return "favourited"
            }
        }
    }
    
    struct FilterOptions: OptionSet, Sendable {
        let rawValue: Int
        
        static let installed: FilterOptions = .init(rawValue: 1 << 0)
        static let favourited: FilterOptions = .init(rawValue: 1 << 1)
        
        static let all: FilterOptions = [.installed, .favourited]
    }

    enum Layout: String, CaseIterable, Sendable, Codable, Equatable {
        case grid = "Grid"
        case list = "List"
    }

    /// Which way round the library's names run: A to Z, or Z to A.
    ///
    /// Chosen from the Sort menu and kept under ``titleOrderStorageKey``; whether installed
    /// games come first is kept under ``installedFirstStorageKey``. Both are read by the list
    /// that draws the library and handed to ``library(inStorefront:titleOrder:installedFirst:)``.
    enum TitleOrder: String, CaseIterable, Sendable {
        case ascending
        case descending
    }

    nonisolated static let titleOrderStorageKey: String = "libraryTitleOrder"
    nonisolated static let installedFirstStorageKey: String = "libraryInstalledFirst"
}
