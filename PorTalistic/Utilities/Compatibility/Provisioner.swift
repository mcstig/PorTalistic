//
//  Provisioner.swift
//  Mythic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 Keeps the machine ready to run games, without anyone being asked to install anything.

 The pieces this drives already existed — ``Engine``, ``RuntimeInstaller``, ``Wine/DXMT``,
 ``Rosetta`` — but every one of them was wired to a button in Settings or a sheet in
 onboarding. Someone who just wanted to play a game had to first understand what a runtime
 was and guess which one they needed. This is the part that means they don't.

 # What it does, and what it deliberately doesn't

 **Lazy, with prefetch.** Runtimes are fetched when the library actually needs them, not all
 at once: the full catalogue is several gigabytes, most of which most people never use. But
 "when needed" is worked out from the games already *installed* and done in the background,
 so by the time anyone presses Play the answer is usually already on disk. A game merely owned
 and not installed downloads nothing.

 **It stays out of the way of running games.** A pass does nothing while any operation is in
 the queue. Replacing an engine underneath a running game, or competing with a download for
 bandwidth, is worse than being a few minutes late.

 **One thing it cannot do silently, and doesn't pretend to.** Rosetta 2 needs root to install
 and Apple's licence is the user's to accept, not ours. Every runtime here is x86_64, so on
 Apple Silicon this is unavoidable — but it is asked once, at the moment a game actually needs
 it, rather than in the user's face on first launch. Until then ``isRosettaRequired`` is the
 only thing standing between a game and starting, and it is the UI's job to offer it.
 */
@Observable @MainActor
final class Provisioner {
    static let shared: Provisioner = .init()

    /// `nonisolated` because the work this logs happens off the main actor — a `static let`
    /// on a `@MainActor` type is main-actor-isolated, and the detached passes can't reach it.
    nonisolated static let log: Logger = .custom(category: "Provisioner")

    private init() {}

    // MARK: - State

    enum Activity: Equatable {
        case idle
        case installingEngine(Double?)
        case installingRuntime(name: String, stage: RuntimeInstaller.Stage)
        case repairingRuntime(name: String)
        case installingDirect3DLayer(name: String)

        /// What to show while this is happening, or `nil` when there is nothing to say.
        var localizedDescription: String? {
            switch self {
            case .idle:
                nil
            case .installingEngine:
                String(localized: "Setting up the game engine…")
            case .installingRuntime(let name, let stage):
                "\(name) — \(stage.localizedDescription)"
            case .repairingRuntime(let name):
                String(localized: "Repairing \(name)…")
            case .installingDirect3DLayer(let name):
                String(localized: "Adding Direct3D support to \(name)…")
            }
        }
    }

    private(set) var activity: Activity = .idle

    /// The last thing that went wrong, kept so provisioning can fail quietly but not
    /// invisibly. Nothing here is fatal: a failed pass is retried on the next one.
    private(set) var lastFailure: String?

    /// Whether anything Mythic wants to run needs Rosetta 2 that isn't installed.
    ///
    /// Checked rather than cached: the user may install it themselves between passes, and a
    /// stale `true` would keep asking for something already there.
    var isRosettaRequired: Bool {
        #if arch(arm64)
        // Every runtime in the catalogue, and the bundled engine, are x86_64 builds.
        !Rosetta.exists
        #else
        false
        #endif
    }

    private var currentPass: Task<Void, Never>?

    // MARK: - Passes

    /// Start keeping up. Safe to call more than once.
    func start() {
        schedulePass()
    }

    /// Run a pass unless one is already running.
    ///
    /// Worth calling whenever the library changes: a newly installed game may want a runtime
    /// nothing else needed.
    func schedulePass() {
        guard currentPass == nil else { return }

        currentPass = Task { [weak self] in
            await self?.runPass()
            self?.currentPass = nil
        }
    }

    private func runPass() async {
        // Never while there is work outstanding. An engine swapped underneath a running game,
        // or a runtime download competing with a game download, is worse than waiting.
        guard GameOperationManager.shared.queue.isEmpty else {
            Self.log.debug("Skipping provisioning pass: operations in flight")
            return
        }

        await ensureEngine()
        await repairInstalledRuntimes()
        await ensureRuntimesForInstalledGames()

        activity = .idle
    }

    /// The engine has to exist before anything else is worth doing: it is the default runtime
    /// and the only one carrying Apple's D3DMetal.
    private func ensureEngine() async {
        guard !Engine.isInstalled else { return }

        Self.log.notice("Installing the engine")
        activity = .installingEngine(nil)

        do {
            for try await progress in Engine.install() {
                activity = .installingEngine(progress.progress.fractionCompleted)
            }

            Runtime.invalidateDiscoveryCache()
        } catch {
            fail("Couldn't set up the engine", error)
        }

        activity = .idle
    }

    /// Runtimes that installed but can't start.
    ///
    /// Wineskin-style builds expect a wrapper application to supply the Unix libraries they
    /// link against, so on their own they fail at `dyld` with a message naming neither the
    /// engine nor the wrapper. `RuntimeInstaller` fetches those libraries alongside — this is
    /// the case where that didn't finish, or where an install predates it.
    private func repairInstalledRuntimes() async {
        // Discovery globs several directories and stats every candidate; the support-library
        // check walks a runtime's Frameworks directory. Neither belongs on the main actor.
        let needingRepair: [Runtime] = await Task.detached {
            Runtime.discoverAll()
                .filter(\.isManagedByMythic)
                .filter(RuntimeInstaller.isMissingSupportLibraries)
        }.value

        for runtime in needingRepair {

            Self.log.notice("Repairing support libraries for \(runtime.id, privacy: .public)")
            activity = .repairingRuntime(name: runtime.name)

            do {
                try await RuntimeInstaller.repairSupportLibraries(for: runtime)
                Runtime.invalidateDiscoveryCache()
            } catch {
                fail("Couldn't repair \(runtime.name)", error)
            }
        }

        activity = .idle
    }

    /// Install whatever the installed games need and don't have.
    ///
    /// Only installed games. Someone with two hundred owned Epic games shouldn't wake up to
    /// two hundred games' worth of runtime downloads for the one they play.
    private func ensureRuntimesForInstalledGames() async {
        // Snapshot what the library says on the main actor, then leave it: everything after
        // this reads files.
        let installed: [GameFacts] = GameDataStore.shared.library.compactMap { GameFacts(game: $0) }

        let wanted: [String: RuntimeProfile.Requirements] = await Task.detached {
            var wanted: [String: RuntimeProfile.Requirements] = .init()
            let candidates = Runtime.discoverAll()

            for facts in installed {
                let requirements = Self.resolveProfile(for: facts).requirements

                // Already served by something on disk — nothing to fetch.
                guard Runtime.select(satisfying: requirements, from: candidates) == nil else { continue }
                guard let release = RuntimeRelease.release(satisfying: requirements) else {
                    Self.log.notice("Nothing in the catalogue can serve \(facts.title, privacy: .public)")
                    continue
                }

                wanted[release.id] = requirements
            }

            return wanted
        }.value

        let profilesByRelease = wanted

        for releaseID in profilesByRelease.keys {
            guard let release = RuntimeRelease.catalogue.first(where: { $0.id == releaseID }) else { continue }

            do {
                let runtime = try await install(release)

                if profilesByRelease[releaseID]?.direct3DOnMetal == true {
                    try await ensureDirect3DLayer(in: runtime)
                }
            } catch {
                fail("Couldn't install \(release.name)", error)
            }
        }

        activity = .idle
    }

    // MARK: - Launching

    struct RosettaRequiredError: LocalizedError {
        var errorDescription: String? {
            String(localized: "This game needs Rosetta 2, which hasn't been installed yet.")
        }

        var recoverySuggestion: String? {
            String(localized: "PorTalistic can install it for you — it needs your permission once, because it comes from Apple and requires an administrator.")
        }
    }

    struct NoViableRuntimeError: LocalizedError {
        let title: String

        var errorDescription: String? {
            String(localized: "PorTalistic has no way to run \(title).")
        }
    }

    /// The runtime a game should launch on, installing it first if it isn't there.
    ///
    /// Called on the launch path, so it does the one thing a background pass won't: block.
    /// If a game needs a runtime nobody has fetched yet, waiting for the download is the only
    /// alternative to refusing to start.
    func prepare(_ game: Game) async throws -> Runtime {
        let profile = await profile(for: game)

        if isRosettaRequired {
            throw RosettaRequiredError()
        }

        let requirements = profile.requirements

        if let runtime = await Task.detached(operation: { Runtime.select(satisfying: requirements) }).value {
            return runtime
        }

        guard let release = RuntimeRelease.release(satisfying: requirements) else {
            throw NoViableRuntimeError(title: game.title)
        }

        Self.log.notice("\(game.title, privacy: .public) needs \(release.id, privacy: .public); installing it now")

        let runtime = try await install(release)

        if profile.requirements.direct3DOnMetal {
            try await ensureDirect3DLayer(in: runtime)
        }

        guard let selected = await Task.detached(operation: { Runtime.select(satisfying: requirements) }).value else {
            // Installed, and still can't serve the game: better to say so than to launch onto
            // something that will fail in a way nobody can read.
            throw NoViableRuntimeError(title: game.title)
        }

        return selected
    }

    /// Install Rosetta, once the user has agreed.
    ///
    /// Separate from everything else here because it is the one step that is *not* automatic,
    /// and calling it is an answer to a question the user was asked.
    func installRosetta() async throws {
        try await Rosetta.install(agreeToSLA: true) { _ in }
    }

    // MARK: - Launching into the right container

    /**
     Everything a launch needs, and the way back afterwards.

     Containers are married to their runtime — Wine migrates a prefix forward on first run and
     has no downgrade path — so "the best runtime for this game" is really "the container
     belonging to the best runtime for this game". `Wine.transformProcess` already resolves a
     runtime from the container it is given, which means assigning the container *is* the
     mechanism; nothing else in the launch path has to know a runtime exists.
     */
    struct LaunchPlan: Sendable {
        /// The container the game should run in. Everything else in the launch path follows
        /// from this: `Wine.transformProcess` resolves the runtime from the container.
        let containerURL: URL

        /// Which runtime that container belongs to, and why this game got it — for the log
        /// now and for the game's settings sheet later.
        let runtimeName: String
        let reasons: [String]

        /// The settings that can only be applied to a launch, never to a container.
        ///
        /// `msync`, `avx2`, `dxvk`, `dxvkAsync` and `metalHUD` are read out of the container's
        /// persisted settings each time environment variables are assembled, so a per-game
        /// value has to be handed to that assembly — see
        /// ``Wine/assembleEnvironmentVariables(forContainerAtURL:container:overriding:)``.
        /// The other three are in the prefix's registry and ``apply(_:to:)`` has already
        /// written them, which is why this is the whole overlay rather than a filtered one:
        /// the registry half is simply ignored downstream, and a setting that later moves
        /// from one half to the other doesn't have to be remembered in two places.
        let settings: RuntimeProfile.SettingsOverride
    }

    /// How to put each container back, keyed by the container rather than by the launch.
    ///
    /// Keying on the container bounds this to the number of containers rather than the number
    /// of launches, and is what the entry means anyway: "this prefix has a game's settings in
    /// it". A second launch into the same container replaces the entry, which is correct —
    /// the settings to go back to are the container's own either way.
    private var pendingReverts: [URL: [@Sendable () async -> Void]] = .init()

    /// Choose the runtime, put the game in that runtime's container, and apply its settings.
    ///
    /// Returns only Sendable values on purpose. `Wine.Container` is a reference type with
    /// mutable state, and handing one to a launch running off the main actor is a data race
    /// the compiler is right to refuse — the alternative was declaring someone else's class
    /// `@unchecked Sendable` to get past it, which would have been a shortcut rather than an
    /// answer.
    func planLaunch(for game: Game) async throws -> LaunchPlan {
        let profile = await profile(for: game)
        let preferred = try await prepare(game)

        let (runtime, container) = try await usableContainer(for: profile.requirements,
                                                             preferring: preferred,
                                                             titled: game.title)

        if game.containerURL != container.url {
            Self.log.notice("Moving \(game.title, privacy: .public) to the \(container.name, privacy: .public) container")
            game.containerURL = container.url
            GameDataStore.shared.library.update(with: game)
        }

        pendingReverts[container.url] = await apply(profile.settings, to: container)

        var reasons = profile.reasons

        // Said out loud, because the game is now running on something other than what its
        // profile asked for and the page that explains how it runs would otherwise lie.
        if runtime.id != preferred.id {
            reasons.append(String(localized: """
                \(preferred.name) couldn't set up a Windows installation on this Mac,                 so this is running on \(runtime.name) instead.
                """))
        }

        return .init(containerURL: container.url,
                     runtimeName: runtime.name,
                     reasons: reasons,
                     settings: profile.settings)
    }

    /// The best runtime that can actually boot a prefix, and that prefix.
    ///
    /// Walks the ranking instead of trusting the top of it. `Runtime.isInstalled` means the
    /// files are on disk, not that Wine can start: DXMT's only build cannot create a
    /// container at all on some Macs, and this used to let `UnableToBootError` end the
    /// launch — so the machines the wined3d fallback existed for were exactly the machines
    /// that never reached it.
    private func usableContainer(for requirements: RuntimeProfile.Requirements,
                                 preferring preferred: Runtime,
                                 titled title: String) async throws -> (Runtime, Wine.Container) {
        var candidates = await Task.detached {
            Runtime.rankedWithCompromises(satisfying: requirements)
        }.value

        // `prepare` may have just installed something, and it decided; keep its answer first.
        candidates.removeAll { $0.id == preferred.id }
        candidates.insert(preferred, at: 0)

        var lastError: Error?

        for candidate in candidates {
            guard !Self.runtimesThatCannotBoot.contains(candidate.id) else { continue }

            do {
                return (candidate, try await container(for: candidate))
            } catch {
                Self.runtimesThatCannotBoot.insert(candidate.id)
                lastError = error

                Self.log.error("""
                    \(candidate.name, privacy: .public) couldn't create a container for                     \(title, privacy: .public), so it won't be tried again until the app                     restarts: \(error.localizedDescription, privacy: .public)
                    """)
            }
        }

        throw lastError ?? NoViableRuntimeError(title: title)
    }

    /// Runtimes that failed to create a container, for the life of the process.
    ///
    /// Remembered so that a first run across a whole library doesn't pay the same boot
    /// timeout once per game. Deliberately not persisted: a transient failure — a full disk,
    /// a `wineserver` that hadn't finished dying — shouldn't demote a build permanently and
    /// leave the user no way to say otherwise.
    private static var runtimesThatCannotBoot: Set<String> = .init()

    /// Put the container back the way the user left it.
    ///
    /// Call after the game exits. Skipping it is survivable rather than corrupting: the next
    /// launch applies its own game's effective settings before starting anything, so a revert
    /// lost to a crash is corrected rather than inherited.
    func revert(_ plan: LaunchPlan) async {
        guard let reverts = pendingReverts.removeValue(forKey: plan.containerURL) else { return }

        for revert in reverts { await revert() }
    }

    /// The container belonging to a runtime, created if it doesn't exist yet.
    ///
    /// One per runtime, shared by every game on it. Cheap on disk — three prefixes rather than
    /// one per game — at the cost that games on the same runtime share a registry, which is
    /// what ``apply(_:to:)`` exists to handle.
    func container(for runtime: Runtime) async throws -> Wine.Container {
        // `nil` is how a container says "the bundled engine", so that every prefix created
        // before runtimes existed still resolves.
        let wanted: String? = runtime.origin == .bundledEngine ? nil : runtime.id

        if let existing = Wine.containerObjects.first(where: { $0.settings.runtimeID == wanted }) {
            return existing
        }

        var settings: Wine.Container.Settings = .init()
        settings.runtimeID = wanted

        let name = availableContainerName(for: runtime, wanting: wanted)
        Self.log.notice("Creating a container for \(runtime.id, privacy: .public) as '\(name, privacy: .public)'")

        return try await Wine.createContainer(name: name, settings: settings)
    }

    /// A container name not already taken by a container belonging to a different runtime.
    ///
    /// `Wine.createContainer` returns the existing container when one is already at that
    /// path, which would silently hand back a prefix built by the wrong Wine.
    private func availableContainerName(for runtime: Runtime, wanting runtimeID: String?) -> String {
        let preferred = runtime.name

        func isTaken(_ name: String) -> Bool {
            guard let url = Wine.containersDirectory?.appending(path: name),
                  Wine.containerExists(at: url) else { return false }

            return (try? Wine.getContainerObject(at: url))?.settings.runtimeID != runtimeID
        }

        guard isTaken(preferred) else { return preferred }

        // Ids are validated to be safe as directory names, apart from the `managed:` prefix.
        let suffix = runtime.id.replacingOccurrences(of: ":", with: "-")
        return "\(preferred) (\(suffix))"
    }

    /// Apply a game's settings to the container it is about to run in, and hand back the way
    /// out.
    ///
    /// The *effective* value is written every time, not just the fields the game has an
    /// opinion about — `override ?? the container's own setting`. Writing only the differences
    /// would make a launch depend on which game ran last: containers are shared per runtime,
    /// and Prey wants Retina Mode off in the same prefix where Blades of Time wants it on. So
    /// each launch states the whole answer and the previous one stops mattering.
    ///
    /// Limited to the three settings that live in the container's registry. The other five —
    /// `msync`, `avx2`, `dxvk`, `dxvkAsync` and `metalHUD` — are read from the container's
    /// *persisted* settings when a launch assembles its environment, so applying them here
    /// would mean writing to the container and hoping to write back, and a crash mid-game
    /// would leave someone's container changed. They ride on ``LaunchPlan/settings`` instead,
    /// where nothing has to be put back.
    private func apply(_ overrides: RuntimeProfile.SettingsOverride,
                       to container: Wine.Container) async -> [@Sendable () async -> Void] {
        var reverts: [@Sendable () async -> Void] = .init()

        let url = container.url
        let settings = container.settings

        let retinaMode = overrides.retinaMode ?? settings.retinaMode
        if (try? await Wine.getRetinaMode(containerURL: url)) != retinaMode {
            try? await Wine.toggleRetinaMode(containerURL: url, toggle: retinaMode)
        }
        if overrides.retinaMode != nil, overrides.retinaMode != settings.retinaMode {
            reverts.append {
                try? await Wine.toggleRetinaMode(containerURL: url, toggle: settings.retinaMode)
            }
        }

        let commandStreamThread = overrides.commandStreamThread ?? settings.commandStreamThread
        if (try? await Wine.getCommandStreamThread(containerURL: url)) != commandStreamThread {
            try? await Wine.setCommandStreamThread(containerURL: url, enabled: commandStreamThread)
        }
        if overrides.commandStreamThread != nil, overrides.commandStreamThread != settings.commandStreamThread {
            reverts.append {
                try? await Wine.setCommandStreamThread(containerURL: url, enabled: settings.commandStreamThread)
            }
        }

        let windowsVersion = overrides.windowsVersion ?? settings.windowsVersion
        if (try? await Wine.getWindowsVersion(containerURL: url)) != windowsVersion {
            try? await Wine.setWindowsVersion(containerURL: url, version: windowsVersion)
        }
        if overrides.windowsVersion != nil, overrides.windowsVersion != settings.windowsVersion {
            reverts.append {
                try? await Wine.setWindowsVersion(containerURL: url, version: settings.windowsVersion)
            }
        }

        return reverts
    }

    // MARK: - Profiles

    /// Everything about a game that profile resolution needs, as plain values.
    ///
    /// `Game` is a main-actor-bound reference type and resolution reads executables off disk,
    /// so the two cannot meet. Snapshotting the handful of facts involved is simpler than
    /// making `Game` crossable, and makes it obvious that resolution can't observe a game
    /// changing underneath it.
    struct GameFacts: Sendable {
        let id: String
        let title: String
        let storefront: Game.Storefront?
        let location: URL

        @MainActor
        init?(game: Game) {
            guard case .installed(let location, let platform) = game.installationState,
                  platform == .windows else { return nil }

            self.id = game.id
            self.title = game.title
            self.storefront = game.storefront
            self.location = location
        }
    }

    /// The profile for a game, from its files where they exist.
    func profile(for game: Game) async -> RuntimeProfile {
        guard let facts = GameFacts(game: game) else {
            // Not installed, or not a Windows build: there is nothing on disk to read, but a
            // curated entry may still have something to say about it.
            let entry = CompatibilityDatabase.current.entry(for: game)
            return RuntimeProfile.resolve(executable: nil, databaseEntry: entry)
        }

        return await Task.detached { Self.resolveProfile(for: facts) }.value
    }

    /// Resolution proper, off any actor.
    nonisolated static func resolveProfile(for facts: GameFacts) -> RuntimeProfile {
        RuntimeProfile.resolve(
            executable: windowsExecutable(for: facts),
            databaseEntry: CompatibilityDatabase.current.entry(storefront: facts.storefront,
                                                               id: facts.id,
                                                               title: facts.title)
        )
    }

    /// The game's own Windows executable, for inspection.
    ///
    /// Each storefront knows where its games keep theirs and none of them agree: GOG has play
    /// tasks in a `goggame-<id>.info`, legendary records an executable per install, and a
    /// local game is whatever the user pointed at — which is why this is keyed on storefront
    /// rather than guessing at a filename.
    private nonisolated static func windowsExecutable(for facts: GameFacts) -> WindowsExecutable? {
        guard let storefront = facts.storefront else { return nil }

        let target: URL?

        switch storefront {
        case .gog:
            target = GOGDL.primaryLaunchTarget(forGameAt: facts.location,
                                               id: facts.id,
                                               platform: .windows)?.executable
        case .epicGames:
            target = (try? Legendary.getGameInstallationData(gameID: facts.id))
                .map { facts.location.appending(path: $0.executable.replacingOccurrences(of: "\\", with: "/")) }
        case .steam, .local:
            // Neither records an executable anywhere this can read yet, so they fall back to
            // the default profile rather than to a guess.
            target = nil
        }

        guard let target, FileManager.default.fileExists(atPath: target.path) else { return nil }

        return WindowsExecutable.inspectGame(primaryExecutable: target)
    }

    // MARK: - Steps

    private func install(_ release: RuntimeRelease) async throws -> Runtime {
        activity = .installingRuntime(name: release.name, stage: .downloading(nil))

        let runtime = try await RuntimeInstaller.install(release) { [weak self] stage in
            Task { @MainActor in
                self?.activity = .installingRuntime(name: release.name, stage: stage)
            }
        }

        Runtime.invalidateDiscoveryCache()
        activity = .idle

        return runtime
    }

    private func ensureDirect3DLayer(in runtime: Runtime) async throws {
        // The bundled engine carries Apple's D3DMetal, and a build that ships DXMT needs
        // nothing added. Only the third case — a Wine with the Metal escapes and no
        // implementation on top — is ours to fill in.
        guard runtime.origin != .bundledEngine,
              !Wine.DXMT.isShippedByRuntime(runtime),
              !Wine.DXMT.isInstalled(in: runtime) else { return }

        activity = .installingDirect3DLayer(name: runtime.name)
        defer { activity = .idle }

        try await Wine.DXMT.install(into: runtime)
        Runtime.invalidateDiscoveryCache()
    }

    private func fail(_ what: String, _ error: Error) {
        Self.log.error("\(what, privacy: .public): \(error.localizedDescription)")
        lastFailure = "\(what): \(error.localizedDescription)"
    }
}
