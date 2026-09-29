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
    ///
    /// And only games on the startup disk. Working out what a game needs means reading its
    /// executable — for a GOG game, `goggame-<id>.info` inside its own folder — and reading a
    /// file on an external drive is what makes macOS put up "PorTalistic would like to access
    /// files on a removable volume". This runs at every launch, so a library with one game on
    /// an external SSD asked for that drive every single time the app opened, before anyone
    /// had asked for anything.
    ///
    /// Nothing is lost by skipping them: this is a head start, not a requirement.
    /// ``planLaunch(for:)`` resolves the same profile and installs the same runtime when the
    /// game is actually started — which is the moment the drive has to be read anyway, and
    /// the moment a prompt about it makes sense.
    private func ensureRuntimesForInstalledGames() async {
        // Snapshot what the library says on the main actor, then leave it: everything after
        // this reads files.
        let installed: [GameFacts] = GameDataStore.shared.library
            .compactMap { GameFacts(game: $0) }
            .filter { !$0.location.isOnAnExternalVolume }

        let wanted: [String: RuntimeProfile.Requirements] = await Task.detached {
            var wanted: [String: RuntimeProfile.Requirements] = .init()
            let candidates = Runtime.discoverAll()

            for facts in installed {
                let requirements = Self.resolveProfile(for: facts).requirements

                guard let release = RuntimeRelease.release(satisfying: requirements) else {
                    Self.log.notice("Nothing in the catalogue can serve \(facts.title, privacy: .public)")
                    continue
                }

                // Something on disk may already serve this game, and usually does. Fetching
                // anyway is right in exactly one case: the catalogue's answer is a newer build
                // of the same lineage, which is an upgrade rather than a second opinion.
                //
                // The narrowness is the point. "Fetch whenever the catalogue prefers something
                // else" would hand a library that runs fine on the bundled engine a download
                // per game, and `RuntimeRetention.isUpgrade(_:over:)` answers false for
                // anything that isn't a managed build of the same family.
                if let serving = Runtime.select(satisfying: requirements, from: candidates) {
                    guard RuntimeRetention.isUpgrade(release, over: serving) else { continue }

                    Self.log.notice("\(facts.title, privacy: .public) runs on \(serving.id, privacy: .public); \(release.id, privacy: .public) is newer in the same family")
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

    /// Nothing installed, and nothing in the catalogue, can meet what this game needs.
    ///
    /// The message used to be "PorTalistic has no way to run \(title).", which is the one thing
    /// the person already knew. It reads as "this game is not supported", and the truth is
    /// almost always "the Wine build that would run it has not been published yet" — and those
    /// call for completely different reactions.
    struct NoViableRuntimeError: LocalizedError {
        let title: String

        /// What could not be provided. Empty when the game asked for nothing unusual, which
        /// means something else is wrong and saying more would be a guess.
        var unmet: [String] = []

        var errorDescription: String? {
            guard !unmet.isEmpty else {
                return String(localized: "PorTalistic has no way to run \(title).")
            }

            return String(localized: "\(title) needs \(unmet.formatted(.list(type: .and))), and no Wine build PorTalistic can install provides that.")
        }

        var recoverySuggestion: String? {
            guard !unmet.isEmpty else { return nil }

            return String(localized: "This is a missing Wine build rather than an unsupported game. A future update to PorTalistic's runtime list may add one.")
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

        // Before choosing: a build we'd *prefer* for Direct3D on Metal may be installed and
        // simply not have the layer yet.
        //
        // This has to come first, not as a fallback. `Runtime.select` asks what a runtime can
        // do right now, and for Direct3D on Metal that means DXMT is already inside it — so a
        // Wine that is ready for DXMT and hasn't received it doesn't appear in the ranking at
        // all. `ensureDirect3DLayer` only ever ran on the install that fetched a runtime, so a
        // build that arrived any other way never got one, and the game quietly went to
        // whatever else could serve it: Apple's D3DMetal on the user's own Game Porting
        // Toolkit, which is exactly the implementation this project can't ship and shouldn't
        // be choosing by default.
        if requirements.direct3DOnMetal {
            await installDirect3DLayerIntoPreferredHost()
        }

        if let runtime = await Task.detached(operation: { Runtime.select(satisfying: requirements) }).value {
            return runtime
        }

        guard let release = RuntimeRelease.release(satisfying: requirements) else {
            throw NoViableRuntimeError(title: game.title, unmet: requirements.unmetDescriptions)
        }

        Self.log.notice("\(game.title, privacy: .public) needs \(release.id, privacy: .public); installing it now")

        let runtime = try await install(release)

        if profile.requirements.direct3DOnMetal {
            try await ensureDirect3DLayer(in: runtime)
        }

        guard let selected = await Task.detached(operation: { Runtime.select(satisfying: requirements) }).value else {
            // Installed, and still can't serve the game: better to say so than to launch onto
            // something that will fail in a way nobody can read.
            throw NoViableRuntimeError(title: game.title, unmet: requirements.unmetDescriptions)
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

        /// Which build, as a key rather than a name. `runtimeName` is for people.
        let runtimeID: String

        /// `settings` with the container's own value filled in wherever the overlay was
        /// silent — the configuration the game will actually see.
        ///
        /// Needed because `RecoveryPlanner` skips a rung whose value is already in effect, and
        /// "in effect" is a property of the container, not of the overlay. Judging it from the
        /// overlay alone spends a rung setting Retina Mode to the value it already had.
        let effectiveSettings: RuntimeProfile.SettingsOverride

        /// The verbs the profile asked for, so a report says what was installed.
        let winetricks: [String]

        /// What the game was judged to need, for the rungs that only apply to some games.
        let requirements: RuntimeProfile.Requirements

        /// Where that build's binaries live.
        ///
        /// Carried rather than looked up again from the container: `Wine.runtime(forContainerAtURL:)`
        /// falls back to the bundled engine when a container's settings can't be read, and the
        /// end of a launch asks "is anything of this build still running" — a question the
        /// wrong build answers `false` to, which is the failure it exists to prevent.
        let runtimeBinaryDirectory: URL

        /// The Direct3D implementation the game will actually render through.
        ///
        /// The runtime it ended up on, not the one its profile asked for: a machine without
        /// the build a profile wanted gets something else, and the recovery ladder must not
        /// spend a launch moving a game to the implementation it is already using.
        let graphicsBackend: RuntimeProfile.GraphicsBackend?

        /// Who this was for. `Sendable`, unlike `Game`, which is why the post-mortem takes
        /// these rather than the library's own object — see the note on this type.
        let facts: GameFacts?
    }

    /// Choose the runtime, put the game in that runtime's container, and apply its settings.
    ///
    /// Returns only Sendable values on purpose. `Wine.Container` is a reference type with
    /// mutable state, and handing one to a launch running off the main actor is a data race
    /// the compiler is right to refuse — the alternative was declaring someone else's class
    /// `@unchecked Sendable` to get past it, which would have been a shortcut rather than an
    /// answer.
    func planLaunch(for game: Game) async throws -> LaunchPlan {
        // What the recovery loop decided after the *last* launch: this is the one that puts it
        // in place. Said on the game's page while it happens, because applying it is the slow
        // part of pressing Play and "Starting" on its own doesn't say what is being waited for.
        let operation = Game.operationManager.launchOperation(for: game)
        operation?.pendingConfigurationChange = GameFacts(game: game)
            .flatMap(Self.recoveryRecord(for:))?
            .attempts.last?.changed

        // On the way out however it goes: a launch that failed to prepare is not still
        // preparing, and the phase is what keeps Play spent while this runs.
        defer { operation?.noteConfigurationApplied() }

        let profile = await profile(for: game)
        let preferred = try await prepare(game)

        // Force Quit is asked about between steps, because none of the steps asks for itself:
        // each one is a wait on something outside this process. Pressed during "Applying new
        // configuration", it used to let every remaining step run and then start the game.
        try Task.checkCancellation()

        let (runtime, container) = try await usableContainer(for: profile.requirements,
                                                             preferring: preferred,
                                                             titled: game.title)

        try await stopIfForceQuit(killing: container.url)

        if game.containerURL != container.url {
            Self.log.notice("Moving \(game.title, privacy: .public) to the \(container.name, privacy: .public) container")
            game.containerURL = container.url
            GameDataStore.shared.library.update(with: game)
        }

        // Before the settings, because a verb installs the DLLs that the overrides applied
        // below are about to promise are there.
        await Wine.installWinetricksVerbsIfMissing(profile.winetricks, inContainerAtURL: container.url)

        try await stopIfForceQuit(killing: container.url)

        await apply(profile.settings, to: container)

        try await stopIfForceQuit(killing: container.url)

        var reasons = profile.reasons

        // Said out loud, because the game is now running on something other than what its
        // profile asked for and the page that explains how it runs would otherwise lie.
        if runtime.id != preferred.id {
            reasons.append(String(localized: """
                \(preferred.name) couldn't set up a Windows installation on this Mac, \
                so this is running on \(runtime.name) instead.
                """))
        }

        let effective = Self.effectiveSettings(profile.settings, in: container.settings)

        return .init(containerURL: container.url,
                     runtimeName: runtime.name,
                     reasons: reasons,
                     settings: profile.settings,
                     runtimeID: runtime.id,
                     effectiveSettings: effective,
                     winetricks: profile.winetricks,
                     requirements: profile.requirements,
                     runtimeBinaryDirectory: runtime.executableURL.deletingLastPathComponent(),
                     graphicsBackend: Self.backend(of: runtime, given: effective),
                     facts: GameFacts(game: game))
    }

    /// What a game on this runtime renders Direct3D through.
    ///
    /// Asked of the runtime rather than of the profile, because those are different claims: a
    /// profile asks for DXMT and a Mac without a DXMT build gets wined3d instead. Only the
    /// answer to "what did this launch actually use" is worth anything afterwards.
    nonisolated static func backend(of runtime: Runtime,
                                    given effective: RuntimeProfile.SettingsOverride) -> RuntimeProfile.GraphicsBackend? {
        switch runtime.capabilities.direct3DOnMetal {
        case .dxmt:             return .dxmt
        case .appleD3DMetal:    return .direct3DMetal
        case .none:             return effective.dxvk == true ? .dxvk : .wined3d
        }
    }

    /// Ends a launch that has been force-quit, taking down whatever it had already started in
    /// its container — a winetricks verb installing, a prefix booting — rather than leaving it
    /// running for a game nobody is going to play.
    private func stopIfForceQuit(killing containerURL: URL) async throws {
        guard Task.isCancelled else { return }

        await Wine.forceQuit(containerAt: containerURL)
        throw CancellationError()
    }

    /// A game's overlay with the container's own values filled in where it is silent.
    ///
    /// Only the settings a container actually stores. The rest — the DLL overrides above all —
    /// have no container-level value to fall back to, so they stay exactly as the profile left
    /// them.
    nonisolated static func effectiveSettings(_ overlay: RuntimeProfile.SettingsOverride,
                                              in container: Wine.Container.Settings) -> RuntimeProfile.SettingsOverride {
        var effective = overlay

        effective.dxvk = overlay.dxvk ?? container.dxvk
        effective.dxvkAsync = overlay.dxvkAsync ?? container.dxvkAsync
        effective.retinaMode = overlay.retinaMode ?? container.retinaMode
        effective.msync = overlay.msync ?? container.msync
        effective.metalHUD = overlay.metalHUD ?? container.metalHUD
        effective.avx2 = overlay.avx2 ?? container.avx2
        effective.captureDisplaysForFullscreen = overlay.captureDisplaysForFullscreen
            ?? container.captureDisplaysForFullscreen
        effective.commandStreamThread = overlay.commandStreamThread ?? container.commandStreamThread
        effective.windowsVersion = overlay.windowsVersion ?? container.windowsVersion

        return effective
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

    /// Apply a game's settings to the container it is about to run in.
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
    /// would leave someone's container changed. They ride on ``LaunchPlan/settings`` instead.
    ///
    /// **Nothing is put back afterwards, on purpose.** This used to hand back a list of
    /// reverts that ran once the launch process exited, so that a container's stored settings
    /// and its registry agreed again between games. Two things were wrong with that. The
    /// paragraph above already makes it unnecessary — the next launch states its own whole
    /// answer, so leftovers cannot be inherited. And it was actively destructive, because on
    /// the Epic path there is no moment that means "the game exited": `legendary` spawns Wine
    /// detached from itself and returns, so the revert landed *while the game was still
    /// starting*. Horizon Chase Turbo had Retina Mode turned off for it, queried the desktop
    /// and made itself a 2048×1330 window to match — and then the revert turned Retina Mode
    /// back on underneath it, so `winemac.drv` began presenting that window at 2× and it
    /// covered exactly one quarter of the screen. It then saved the now-Retina 4096×2660
    /// desktop into its own settings, and asked for that next time too.
    ///
    /// The fingerprint, worth recognising: a window **exactly half the screen on each axis**,
    /// drawing its content correctly rather than into a corner, **that fills the screen as
    /// soon as it is minimised and restored** — because that is what makes macOS lay the
    /// window out again against the scale factor the display actually has now. A registry
    /// write under a live game is not a tidy-up.
    private func apply(_ overrides: RuntimeProfile.SettingsOverride,
                       to container: Wine.Container) async {
        let url = container.url
        let settings = container.settings

        // Both halves, not just the flag.
        //
        // `toggleRetinaMode` writes RetinaMode *and* the DPI that has to accompany it, and
        // this used to run only when the flag disagreed. So a container created while the
        // default was Retina-on kept LogPixels at 192 after the flag went off — a 1× desktop
        // advertised as 2× — and nothing corrected it, because the flag already matched.
        //
        // Worth being exact about, because this was twice blamed for the small window and was
        // not the cause either time. The desktop a game is handed is decided by RetinaMode; a
        // DPI that disagrees with it misinforms DPI-aware code but does not resize anything.
        // What actually shrank Horizon Chase Turbo's window was being given a Retina desktop
        // at all — see the note on this function about why nothing is put back afterwards.
        let retinaMode = overrides.retinaMode ?? settings.retinaMode
        let expectedScaling = Wine.Container.Settings.displayScaling(forRetinaMode: retinaMode)

        // Read before the comparison: `||` takes its right operand as an autoclosure, which
        // cannot be `await`ed.
        let currentRetinaMode = try? await Wine.getRetinaMode(containerURL: url)
        let currentScaling = try? await Wine.getDisplayScaling(containerURL: url)

        if currentRetinaMode != retinaMode || currentScaling != expectedScaling {
            try? await Wine.toggleRetinaMode(containerURL: url, toggle: retinaMode)
        }

        // Between settings, for a Force Quit: each is a registry read and perhaps a write, each of
        // those is Wine starting in the prefix, and none of them looks for a cancellation. Pressed
        // during "Applying new configuration", every remaining setting used to be written first.
        // What follows this in `planLaunch(for:)` is what ends the launch, and stopping partway
        // leaves nothing to undo: the next launch writes the whole answer again, as above.
        guard !Task.isCancelled else { return }

        let captureDisplays = overrides.captureDisplaysForFullscreen ?? settings.captureDisplaysForFullscreen
        if (try? await Wine.getCaptureDisplaysForFullscreen(containerURL: url)) != captureDisplays {
            try? await Wine.setCaptureDisplaysForFullscreen(containerURL: url, enabled: captureDisplays)
        }

        guard !Task.isCancelled else { return }

        let commandStreamThread = overrides.commandStreamThread ?? settings.commandStreamThread
        if (try? await Wine.getCommandStreamThread(containerURL: url)) != commandStreamThread {
            try? await Wine.setCommandStreamThread(containerURL: url, enabled: commandStreamThread)
        }

        guard !Task.isCancelled else { return }

        let windowsVersion = overrides.windowsVersion ?? settings.windowsVersion
        if (try? await Wine.getWindowsVersion(containerURL: url)) != windowsVersion {
            try? await Wine.setWindowsVersion(containerURL: url, version: windowsVersion)
        }
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

        init(id: String, title: String, storefront: Game.Storefront?, location: URL) {
            self.id = id
            self.title = title
            self.storefront = storefront
            self.location = location
        }

        @MainActor
        init?(game: Game) {
            // Anything but a native macOS build. `platform == .windows` was too strict: a
            // game whose recorded platform never got filled in is still a Windows game with
            // an executable worth reading, and skipping it meant the profile fell all the
            // way back to "PorTalistic hasn't read this game's files yet" for games that
            // were plainly running under Wine.
            guard case .installed(let location, let platform) = game.installationState,
                  platform != .macOS else { return nil }

            self.id = game.id
            self.title = game.title
            self.storefront = game.storefront
            self.location = location
        }
    }

    /// The profile for a game, from its files where they exist.
    ///
    /// The game's own settings are part of the answer, not a layer applied afterwards: with
    /// ``Game/isSettingsAutomatic`` off, what the user set wins over anything read from the
    /// executable or the curated database, and the profile says `.userOverride` so the
    /// interface can show whose decision it was. With it on the override is not consulted at
    /// all — it is kept, so turning automatic off again returns what was there before.
    func profile(for game: Game) async -> RuntimeProfile {
        let override: RuntimeProfile.SettingsOverride? = game.isSettingsAutomatic
            ? nil
            : game.settingsOverride

        guard let facts = GameFacts(game: game) else {
            // Not installed, or not a Windows build: there is nothing on disk to read, but a
            // curated entry may still have something to say about it.
            let entry = CompatibilityDatabase.current.entry(for: game)
            return RuntimeProfile.resolve(executable: nil, databaseEntry: entry, userOverride: override)
        }

        return await Task.detached { Self.resolveProfile(for: facts, userOverride: override) }.value
    }

    /// Resolution proper, off any actor.
    nonisolated static func resolveProfile(for facts: GameFacts,
                                           userOverride: RuntimeProfile.SettingsOverride? = nil) -> RuntimeProfile {
        RuntimeProfile.resolve(
            executable: windowsExecutable(for: facts),
            databaseEntry: compatibilityEntry(for: facts),
            userOverride: userOverride,
            hasExhaustedRecovery: recoveryRecord(for: facts)?.hasExhaustedOptions == true
        )
    }

    /// What the recovery loop has learned about this game, if anything.
    nonisolated static func recoveryRecord(for facts: GameFacts) -> RecoveryJournal.GameRecord? {
        RecoveryJournal.key(for: facts).flatMap { RecoveryJournal.current.games[$0] }
    }

    /// What is known about this game, curated and learned, as one entry.
    ///
    /// Three layers, and the order is the whole policy. A setting the person chose by hand wins
    /// outright — that happens above this, in `RuntimeProfile.resolve`. Below that, a curated
    /// entry beats what the app worked out for itself, because somebody read the logs to write
    /// it. And below that, what the app learned by watching this game crash, which keeps every
    /// field the curated entry doesn't mention.
    nonisolated static func compatibilityEntry(for facts: GameFacts) -> CompatibilityDatabase.Entry? {
        let curated = CompatibilityDatabase.current.entry(storefront: facts.storefront,
                                                          id: facts.id,
                                                          title: facts.title)

        guard let learned = recoveryRecord(for: facts)?.learned else { return curated }

        guard let curated else { return learned }

        return learned.overlaid(with: curated)
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

    /// Puts DXMT into the best installed build that can host it and hasn't got it.
    ///
    /// Catalogue order, not discovery order, because catalogue order is preference order —
    /// picking whichever directory sorted first would install the layer into a build we'd
    /// rather not use and leave the one we would.
    ///
    /// Failure is deliberately swallowed: this is an improvement on what selection would
    /// otherwise pick, not a precondition for it. A download that doesn't happen leaves the
    /// launch exactly where it would have been without this.
    private func installDirect3DLayerIntoPreferredHost() async {
        let hosts = await Task.detached {
            let installed = Runtime.discoverAll()

            return RuntimeRelease.catalogue
                .filter(\.exposesMetalEscapes)
                .compactMap { release in installed.first { $0.id == "managed:\(release.id)" } }
                .filter { !Wine.DXMT.isShippedByRuntime($0) && !Wine.DXMT.isInstalled(in: $0) }
        }.value

        guard let host = hosts.first else { return }

        Self.log.notice("\(host.name, privacy: .public) can host Direct3D 11 on Metal and hasn't got it; installing it now")

        do {
            try await ensureDirect3DLayer(in: host)
        } catch {
            fail("Couldn't install Direct3D 11 on Metal into \(host.name)", error)
        }
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
