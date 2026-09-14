//
//  GameDataStore.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 2/12/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Combine
import OSLog

// TODO: eventually, migrate to SwiftData.
@Observable @MainActor final class GameDataStore {
    static let shared: GameDataStore = .init()
    let log: Logger = .custom(category: "GameDataStore")
    
    private let gamesObserver: CodableUserDefaultsObserver<[AnyGame]>
    private var isUpdatingFromObserver = false
    
    var library: Set<Game> = .init() {
        didSet {
            guard !isUpdatingFromObserver else { return }
            try? UserDefaults.standard.encodeAndSet(library.map({ AnyGame($0) }), forKey: "games")
        }
    }

    @MainActor private init() {
        // initialise observer
        gamesObserver = .init(key: "games",
                              defaultValue: [])
        
        // load library on initialisation
        library = Set(gamesObserver.value.map({ $0.base }))
        
        // observe external changes
        gamesObserver.$value
            .sink { [weak self] newGames in
                guard let self else { return }
                let newLibrary = Set(newGames.map({ $0.base }))
                
                guard newLibrary != self.library else { return }
                self.log.debug("Games key changed in UserDefaults, updating library")
                
                self.isUpdatingFromObserver = true
                defer { self.isUpdatingFromObserver = false }
                self.library = newLibrary
            }
            .store(in: &cancellables)
    }
    
    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = .init()

    var recent: Game? {
        guard !library.allSatisfy({ $0.lastLaunched == nil }) else { return nil }

        return library.max {
            $0.lastLaunched ?? .distantPast < $1.lastLaunched ?? .distantPast
        }
    }

    func refreshFromStorefronts(_ storefronts: Game.Storefront...) async throws {
        GameListViewModel.shared.isUpdatingLibrary = true
        defer {
            GameListViewModel.shared.isUpdatingLibrary = false
        }
        
        // if variadics are empty, default to all cases
        let storefronts = storefronts.isEmpty ? Game.Storefront.allCases : storefronts as [Game.Storefront]
        
        // legendary (epic games)
        if storefronts.contains(.epicGames) {
            do {
                // Pull the catalogue down first. `getInstallableGames()` only reads
                // legendary's on-disk cache, so skipping this leaves a signed-in account
                // with a permanently empty library.
                // A refresh failure (offline, Epic down) is not fatal: fall through and
                // show whatever was cached last time.
                if Legendary.isSignedIn {
                    do {
                        try await Legendary.refreshLibraryMetadata()
                    } catch {
                        log.warning("Couldn't refresh the Epic catalogue, using cached data: \(error.localizedDescription)")
                    }
                }

                let installables = try Legendary.getInstallableGames()
                let installed = try Legendary.getInstalledGames()
                
                // add installables that aren't installed
                for game in installables where !installed.contains(where: { $0 == game }) {
                    library.update(with: game)
                }
                
                // installed: merge instead of overwrite
                for fetchedGame in installed {
                    if let existing = library.first(where: { $0 == fetchedGame }) {
                        try existing.merge(with: fetchedGame, requiring: .identicalIgnoredKeys)
                        library.update(with: existing)
                    } else {
                        library.update(with: fetchedGame)
                    }
                }

                // Add-ons that an earlier version filed as games are still in here, because a
                // refresh only adds and updates. Take them out — but only the ones that
                // aren't installed. Being wrong about what to show is untidy; being wrong
                // about what to remove looks like Mythic lost someone's game.
                let addOnIDs = Legendary.addOnGameIDs()
                let staleAddOns = library.filter { game in
                    guard game.storefront == .epicGames, addOnIDs.contains(game.id) else { return false }
                    guard case .uninstalled = game.installationState else { return false }
                    return true
                }

                if !staleAddOns.isEmpty {
                    log.notice("Removing \(staleAddOns.count, privacy: .public) Epic add-on(s) previously filed as games")
                    library.subtract(staleAddOns)
                }
            } catch {
                log.error("Unable to refresh game data from Epic Games: \(error.localizedDescription)")
                throw error
            }
        }
        
        // gog
        //
        // Owned, not installed: GOG answers what the account has, and whether any of it is on
        // disk is Mythic's own bookkeeping. So the fetched games are merged into what's
        // already known rather than replacing it, or an installed game would be demoted to
        // uninstalled on every refresh.
        if storefronts.contains(.gog), GOG.isSignedIn {
            do {
                for fetchedGame in try await GOG.getInstallableGames() {
                    if let existing = library.first(where: { $0 == fetchedGame }) {
                        try existing.merge(with: fetchedGame, requiring: .identicalIgnoredKeys)
                        library.update(with: existing)
                    } else {
                        library.update(with: fetchedGame)
                    }
                }
            } catch {
                // Not fatal, and not worth failing the whole refresh over: Epic's games are
                // already in by this point and an expired GOG session shouldn't hide them.
                log.error("Unable to refresh game data from GOG: \(error.localizedDescription)")
            }

            // GOG says what's owned, not what's installed — that's Mythic's own bookkeeping,
            // and bookkeeping drifts. A game deleted in Finder still reads as installed; a
            // library entry lost to a failed write orphans a download that's sitting right
            // there. gogdl's install record is the third opinion that settles both.
            var reconciled = false
            for game in library.compactMap({ $0 as? GOGGame }) where GOGDL.reconcileInstallationState(of: game) {
                reconciled = true
                library.update(with: game)
            }

            if reconciled {
                log.notice("Brought GOG installation states back in step with what's on disk")
            }

            // Whether an installed GOG game has a newer build is a question only GOG can
            // answer, and `Game.isUpdateAvailable` is read synchronously while cards are
            // drawn — so the answers are collected here, once per refresh, and read from the
            // memo afterwards.
            let installedGOGGames = library.compactMap { game -> GOGGame? in
                guard let gogGame = game as? GOGGame, case .installed = game.installationState else { return nil }
                return gogGame
            }

            await withTaskGroup(of: Void.self) { group in
                for game in installedGOGGames {
                    group.addTask { _ = await GOGDL.refreshUpdateAvailability(for: game) }
                }
            }
        }

        // steam
        if storefronts.contains(.steam), Steam.isClientInstalled {
            do {
                let installed = try await Steam.importInstalledGames()

                for fetchedGame in installed {
                    if let existing = library.first(where: { $0 == fetchedGame }) {
                        try existing.merge(with: fetchedGame, requiring: .identicalIgnoredKeys)
                        library.update(with: existing)
                    } else {
                        library.update(with: fetchedGame)
                    }
                }
            } catch {
                log.error("Unable to refresh game data from Steam: \(error.localizedDescription)")
                throw error
            }
        }

        // TODO: others
        // if storefronts.contains(...) { ... }
    }
}
