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
            schedulePersist()
        }
    }

    /// Coalesces saving the library into one write per quarter-second.
    ///
    /// A save encodes every game in the library, and a refresh calls `library.update(with:)`
    /// once per game — so refreshing a hundred-game library encoded that library a hundred
    /// times. Each write also posts a `UserDefaults` change notification, which every
    /// `@AppStorage` in the app wakes up to check, so the cost was not only the encoding.
    private var persistTask: Task<Void, Never>?

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }

            try? UserDefaults.standard.encodeAndSet(self.library.map({ AnyGame($0) }), forKey: "games")
        }
    }

    /// Fold catalogue entries — games the account owns that are not on disk — into `library`.
    ///
    /// Merged rather than replaced. `Set.update(with:)` swaps the whole object out, and
    /// `Game`'s `==` is by id alone, so a freshly built catalogue entry silently took the place
    /// of the library's own: the favourite, the last-played date, custom artwork, launch
    /// arguments, the container and every settings override were reset on every refresh, for
    /// every game not currently installed. The installed loop had always merged; this one had
    /// not, and the asymmetry was the fault.
    ///
    /// The installation state is *assigned* rather than merged, which is the one place the two
    /// loops should differ. `Game.mergeRules` keeps the greater of the two states, which is
    /// right where a catalogue entry must not demote a game legendary says is installed, and
    /// wrong here — legendary no longer listing a game is precisely how an uninstall gets
    /// noticed.
    ///
    /// Lifted out of `refreshFromStorefronts` so the regression suite can run it: the fault is
    /// invisible unless the loop actually executes, and everything around it needs legendary on
    /// the other end.
    ///
    /// - Warning: this cannot currently throw, and that is an accident rather than a design.
    ///   The only throwing call is `merge(with:requiring:)`, and `.identicalIgnoredKeys` is
    ///   inert: `Mirror` reports an `@Observable` class's stored properties under their
    ///   underscored names, so the check finds no child called `title` and skips it, and
    ///   `storefront` is computed so it has no stored property at all. Only `id` is really
    ///   compared, and both loops find their counterpart *by* id. Whoever fixes that check has
    ///   to make a failed merge per-game — log it and carry on — because a `throw` from in here
    ///   escapes to `refreshFromStorefronts`' `do`, abandons the rest of the Epic refresh, and
    ///   is then swallowed by the `try?` at the call site. One game with a `®` in one of its
    ///   two titles would quietly stop the library updating at all.
    static func absorb(catalogue: [Game], into library: inout Set<Game>) throws {
        for game in catalogue {
            guard let existing = library.first(where: { $0 == game }) else {
                library.update(with: game)
                continue
            }

            try existing.merge(with: game, requiring: .identicalIgnoredKeys)
            existing.installationState = game.installationState
            library.update(with: existing)
        }
    }

    /// Which games are on disk, for noticing when a refresh changed that.
    private var installedGameIDs: Set<String> {
        Set(library.compactMap { game -> String? in
            guard case .installed = game.installationState else { return nil }
            return game.id
        })
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

    /// - Parameter probingExternalVolumes: Whether the refresh may reach for game files that
    ///   aren't on the startup disk. False by default, because doing so makes macOS ask for
    ///   permission to the drive — every launch, for a question nobody asked. The
    ///   Force-refresh button passes true: the user pressed it, so the prompt is an answer
    ///   to something rather than an interruption.
    /// - Parameter forcingRemoteFetch: Bypass a storefront tool's *own* cache and re-ask the
    ///   storefront. Off by default, because the launch refresh and the timer run often and
    ///   the extra round trip is wasted on them.
    ///
    ///   On for exactly one caller: leaving a store page. `legendary list` without
    ///   `--force-refresh` answers from `metadata/`, so a game bought two minutes ago is not
    ///   in the list it returns — the app refreshed, honestly reported what legendary told it,
    ///   and the purchase was invisible until something else forced the cache.
    func refreshFromStorefronts(_ storefronts: Game.Storefront...,
                                probingExternalVolumes: Bool = false,
                                forcingRemoteFetch: Bool = false) async throws {
        GameListViewModel.shared.isUpdatingLibrary = true
        defer {
            GameListViewModel.shared.isUpdatingLibrary = false
        }

        // A game can arrive on disk without an operation — imported, or found by legendary —
        // and the queue emptying is what asks for a provisioning pass otherwise. Only when
        // the installed set actually moved: this runs on a timer, and a pass reads every
        // installed game's executable.
        let installedBefore = installedGameIDs
        defer {
            if installedGameIDs != installedBefore {
                Provisioner.shared.requestPass(because: "a library refresh changed which games are installed")
            }
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
                        try await Legendary.refreshLibraryMetadata(forceRefresh: forcingRemoteFetch)
                    } catch {
                        log.warning("Couldn't refresh the Epic catalogue, using cached data: \(error.localizedDescription)")
                    }
                }

                let installables = try Legendary.getInstallableGames()
                let installed = try Legendary.getInstalledGames()
                
                // Owned, but not on disk.
                //
                // Nothing between here and the `library.subtract` below may `await`. Both
                // lists were read a few lines up, and this whole region is the only thing
                // keeping a second refresh — the one at launch, the one on the five-minute
                // timer, the one after an install — from writing a stale snapshot over a fresh
                // one. `GameDataStore` being `@MainActor` makes the region atomic *only*
                // because there is no suspension point in it.
                try Self.absorb(catalogue: installables.filter { game in
                    !installed.contains(where: { $0 == game })
                }, into: &library)
                
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

                // Whether each installed game has an update, worked out once here.
                //
                // The answer costs a directory listing and two JSON decodes, and
                // `Game.isUpdateAvailable` is read synchronously three times per card while
                // the library is being drawn — so it is collected now and read from the memo
                // afterwards, the same arrangement GOG already uses below.
                let installedEpicIDs = library.compactMap { game -> String? in
                    guard game.storefront == .epicGames, case .installed = game.installationState else { return nil }
                    return game.id
                }

                await withTaskGroup(of: Void.self) { group in
                    for id in installedEpicIDs {
                        group.addTask { await Legendary.refreshUpdateAvailability(forGameID: id) }
                    }
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
            for game in library.compactMap({ $0 as? GOGGame })
            where GOGDL.reconcileInstallationState(of: game,
                                                   probingExternalVolumes: probingExternalVolumes) {
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
