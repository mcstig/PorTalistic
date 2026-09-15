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
    func library(inStorefront storefront: Game.Storefront?) -> [Game] {
        let operating: Set<Game.ID> = .init(
            GameOperationManager.shared.queue.lazy
                .filter { $0.isExecuting }
                .map { $0.game.id }
        )

        return GameDataStore.shared.library
            .filter { game in
                guard storefront == nil || game.storefront == storefront else { return false }

                let matchesText: Bool = searchString.isEmpty || game.title.localizedStandardContains(searchString)
                guard matchesText else { return false }

                return searchTokens.isEmpty || searchTokens.allSatisfy { token in
                    switch token {
                    case .platform(let platform):
                        guard case .installed(_, let gamePlatform) = game.installationState else { return false }
                        return gamePlatform == platform
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
            .sorted { lhs, rhs in
                // Busy first, then installed, then by name. Written as one comparator so the
                // collection is walked once; as separate sorts, each pass had to undo some
                // of the previous one's work to get here.
                let lhsOperating = operating.contains(lhs.id)
                let rhsOperating = operating.contains(rhs.id)
                if lhsOperating != rhsOperating { return lhsOperating }

                let lhsInstalled = lhs.isInstalled
                let rhsInstalled = rhs.isInstalled
                if lhsInstalled != rhsInstalled { return lhsInstalled }

                return lhs.title < rhs.title
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

    private var sortOptions: [SortOptions] = [.favorite, .installed, .title]
    private let logger: Logger = .custom(category: "GameListViewModel")
    
    var isUpdatingLibrary: Bool = false

    /// Whether anything is narrowing the library right now.
    var isFiltering: Bool { !searchString.isEmpty || !searchTokens.isEmpty }

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

    enum SortOptions: CaseIterable, Sendable {
        case favorite
        case installed
        case title
    }
}
