//
//  RuntimeSelection.swift
//  Mythic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SemanticVersion

/**
 Matching ``RuntimeProfile/Requirements`` to an actual Wine build.

 Kept apart from both sides on purpose. `RuntimeProfile` says what a *game* needs and knows
 nothing about what is installed; `Runtime` says what is on the machine and nothing about
 games. This is the only place the two meet, which is what lets a profile stay valid when the
 set of installed runtimes changes underneath it.
 */
extension Runtime {
    /// Who provides Direct3D 10-or-newer on Metal, which is not the same question as whether
    /// anyone does.
    ///
    /// There are two implementations and they differ in a way that has nothing to do with
    /// graphics: one can be shipped and one cannot. Apple's Game Porting Toolkit licence
    /// restricts distribution of its proprietary components — `D3DMetal.framework` among
    /// them — to non-commercial purposes, and this is a Patreon-funded product. So a build
    /// carrying Apple's implementation is usable on a machine that already has it and is not
    /// something Mythic can hand to anybody.
    enum Direct3DOnMetal: Hashable {
        /// DXMT. Open source, and therefore the one this project can actually rely on.
        case dxmt
        /// Apple's D3DMetal, by way of the Game Porting Toolkit derived engine. More mature
        /// than DXMT and the reason the engine exists — but not distributable, so it is a
        /// fallback for machines that already have it rather than the plan.
        case appleD3DMetal
    }

    /// What a runtime can do, in the terms a profile asks about.
    struct Capabilities: Hashable {
        var direct3DOnMetal: Direct3DOnMetal?
        var modernNetworking: Bool
        var nativeThirtyTwoBit: Bool
    }

    var capabilities: Capabilities {
        .init(direct3DOnMetal: direct3DOnMetalProvider,
              modernNetworking: providesModernNetworking,
              nativeThirtyTwoBit: providesNativeThirtyTwoBit)
    }

    /// Which implementation of Direct3D-on-Metal this build has, if either.
    ///
    /// DXMT is checked first, so a runtime that has both answers `.dxmt` — which is the
    /// answer that keeps Mythic shippable.
    ///
    /// DXMT being *present* is not DXMT working, and the difference is not academic: on this
    /// machine DXMT is installed into Wine Stable 11, a build with no Metal escape interface,
    /// where it half-works in the worst possible way — device creation succeeds, everything
    /// looks right, and every swap chain fails with `EGL_BAD_ALLOC`. So installed DXMT only
    /// counts on a build known to expose the escapes. A build that *ships* DXMT is taken at
    /// its word, since shipping it is the claim.
    private var direct3DOnMetalProvider: Direct3DOnMetal? {
        if Wine.DXMT.isShippedByRuntime(self) { return .dxmt }

        if Wine.DXMT.isInstalled(in: self),
           RuntimeRelease.matching(self)?.exposesMetalEscapes == true {
            return .dxmt
        }

        // Apple's implementation, wherever it came from — the bundled engine, a user's own
        // Game Porting Toolkit install, or Whisky's Wine library, all three of which carry it
        // on this machine. Mythic never installs it; it only notices.
        if Wine.D3DMetal.isPresent(in: self) { return .appleD3DMetal }

        return nil
    }

    /// A socket layer that holds up under load, which the bundled Wine 7.7 does not.
    ///
    /// An unreadable version counts as *not* having it. That is the conservative direction:
    /// the cost of wrongly believing an unknown build has modern networking is a game that
    /// fails in the exact way this requirement exists to avoid, while the cost of wrongly
    /// believing it doesn't is that Mythic prefers a build it knows about.
    private var providesModernNetworking: Bool {
        guard let version else { return false }
        return version >= .init(9, 0, 0)
    }

    /// Whether this build has a real i386 architecture rather than 32-on-64.
    ///
    /// Taken from the catalogue, and `false` for anything not in it — including the bundled
    /// engine, which is CrossOver-derived and is 32-on-64 by construction. Conservative in the
    /// same direction as ``providesModernNetworking``: wrongly believing an unknown build has
    /// real 32-bit support puts a game back on the thing this requirement exists to avoid,
    /// while wrongly believing it doesn't only means preferring a build we know about.
    private var providesNativeThirtyTwoBit: Bool {
        RuntimeRelease.matching(self)?.hasNativeThirtyTwoBit == true
    }

    /// Which Direct3D implementations this Mac can actually give a game right now.
    ///
    /// Asked before anything offers to move a game to one. Reads every installed build, so it
    /// belongs off the main actor and nowhere near a view.
    static func installedBackends() -> Set<RuntimeProfile.GraphicsBackend> {
        let installed = discoverAll().filter(\.isInstalled)

        return Set(RuntimeProfile.GraphicsBackend.allCases.filter { backend in
            installed.contains { $0.provides(backend) }
        })
    }

    /// Whether this build renders Direct3D through `backend`.
    ///
    /// Answered from what the build *has*. What a profile asked for and what a runtime can do
    /// are different facts, and this path has been wrong about that before: a game was moved
    /// to "DXMT" while already on it, and another was told it would render through Vulkan on a
    /// Wine with no Vulkan in it.
    func provides(_ backend: RuntimeProfile.GraphicsBackend) -> Bool {
        switch backend {
        case .dxmt:             capabilities.direct3DOnMetal == .dxmt
        case .direct3DMetal:    capabilities.direct3DOnMetal == .appleD3DMetal
        // Wine's own Direct3D is what a build without either of those falls back to, so
        // "provides wined3d" is "has neither" — which is also why it is never a demand: it is
        // the floor, not a feature.
        case .wined3d:          capabilities.direct3DOnMetal == nil
        // Nothing here records whether a build has Vulkan, and the one that ships DXMT says it
        // hasn't in every transcript it writes: `err:vulkan:vulkan_init_once Wine was built
        // without Vulkan support`. Until that is a capability, claiming to provide DXVK would
        // send a game to a build that cannot render at all, so nothing claims it.
        case .dxvk:             false
        }
    }

    func satisfies(_ requirements: RuntimeProfile.Requirements) -> Bool {
        if requirements.direct3DOnMetal, capabilities.direct3DOnMetal == nil { return false }
        if requirements.modernNetworking, !capabilities.modernNetworking { return false }
        if requirements.nativeThirtyTwoBit, !capabilities.nativeThirtyTwoBit { return false }
        return true
    }

    /// The best installed runtime for a set of requirements, or `nil` if none can serve them.
    ///
    /// The ranking follows what this project has observed and what it is allowed to ship, not
    /// a version comparison:
    ///
    /// - Needs modern networking: the newest viable build, in catalogue order. Nothing else
    ///   will do — this is the requirement the bundled engine cannot meet at all.
    /// - Needs Direct3D on Metal: a DXMT build, then wined3d, and Apple's D3DMetal **last**.
    ///   D3DMetal is the more mature of the two and is still ranked below a path that draws
    ///   badly, which needs saying plainly: `D3DMetal.framework` is Apple's, it arrives in
    ///   the Game Porting Toolkit evaluation environment, and it is in the bundled engine —
    ///   so every automatic choice that lands on it is this project shipping a default built
    ///   on something it may not be allowed to distribute. Last rather than removed, because
    ///   a Mac that already has the Game Porting Toolkit can still use it, and because it is
    ///   the honest fallback when nothing else will start. What changes is that nothing
    ///   *chooses* it.
    /// - Neither: the bundled engine, as the most exercised path for everything that goes
    ///   through wined3d.
    ///
    /// Note what this does *not* do: prefer the newest version. Two builds of Wine 11 are not
    /// interchangeable when one exposes the entry points DXMT needs and the other doesn't,
    /// and "newest" would have sent every Direct3D 11 game to a runtime with no way to draw.
    static func select(satisfying requirements: RuntimeProfile.Requirements,
                       from candidates: [Runtime]? = nil) -> Runtime? {
        ranked(satisfying: requirements, from: candidates).first
    }

    /**
     Every runtime that can serve these requirements, best first.

     One answer was not enough. A runtime that is *installed* is not necessarily a runtime
     that can *boot a prefix*: DXMT's only build cannot create a container at all on some
     Macs — that is written into its own catalogue entry — and the launch path took the top
     of the ranking, got `UnableToBootError`, and stopped. Which meant the machines the
     fallback existed for were precisely the machines that never reached it.

     So the ranking is the whole list, and nothing below the top is dropped. A Direct3D 11
     game that ends up on wined3d runs badly, and badly beats a build that won't start.
     */
    static func ranked(satisfying requirements: RuntimeProfile.Requirements,
                       from candidates: [Runtime]? = nil) -> [Runtime] {
        preferring(requirements.preferredDirect3D,
                   in: rankedIgnoringPreference(satisfying: requirements, from: candidates))
    }

    /// The ranking with the builds that provide `backend` moved to the front.
    ///
    /// A partition, so everything keeps its relative order and nothing is dropped: a game
    /// asking for an implementation no installed build has still gets exactly the ranking it
    /// would have had.
    ///
    /// This is the one place a preference outranks the project's own order — including the
    /// rule that nothing *chooses* Apple's D3DMetal. That rule is about what the app reaches
    /// for by default, and this is a game that has been sent there deliberately: by a curated
    /// entry, or by the recovery ladder after it failed everywhere else, which is the case the
    /// ranking's own note calls "the honest fallback when nothing else will start".
    ///
    /// `provides` is a parameter with a default because everything else in this file reads the
    /// filesystem, and the ordering — the part carrying the policy — is then the part no test
    /// can hold. The same reason ``direct3DOnMetalOrder(dxmt:wined3d:appleD3DMetal:)`` is its
    /// own function.
    static func preferring(_ backend: RuntimeProfile.GraphicsBackend?,
                           in ranking: [Runtime],
                           provides: (Runtime, RuntimeProfile.GraphicsBackend) -> Bool = { $0.provides($1) }) -> [Runtime] {
        guard let backend else { return ranking }

        return ranking.filter { provides($0, backend) } + ranking.filter { !provides($0, backend) }
    }

    private static func rankedIgnoringPreference(satisfying requirements: RuntimeProfile.Requirements,
                                                 from candidates: [Runtime]? = nil) -> [Runtime] {
        let viable = (candidates ?? discoverAll())
            .filter { $0.isInstalled && $0.satisfies(requirements) }

        guard !viable.isEmpty else { return [] }

        if requirements.modernNetworking {
            return byCatalogueOrder(viable)
        }

        if requirements.direct3DOnMetal {
            let byDXMT = byCatalogueOrder(viable.filter { $0.capabilities.direct3DOnMetal == .dxmt })

            // Among Apple's implementations, a copy the user installed themselves comes ahead
            // of the one the app fetched. Their Game Porting Toolkit or Whisky install is
            // theirs under their own acceptance of Apple's terms; the bundled engine is a copy
            // this app caused to be downloaded, and it is the one with the question mark over
            // it.
            let d3dMetal = viable.filter { $0.capabilities.direct3DOnMetal == .appleD3DMetal }
            let byD3DMetal = d3dMetal.filter { $0.origin != .bundledEngine }
                + d3dMetal.filter { $0.origin == .bundledEngine }

            let placed = Set((byDXMT + byD3DMetal).map(\.id))
            let rest = byCatalogueOrder(viable.filter { !placed.contains($0.id) })

            return direct3DOnMetalOrder(dxmt: byDXMT, wined3d: rest, appleD3DMetal: byD3DMetal)
        }

        // The bundled engine first: the most exercised path for everything that goes through
        // wined3d. The others stay reachable behind it for the same reason as above.
        return viable.filter { $0.origin == .bundledEngine }
            + byCatalogueOrder(viable.filter { $0.origin != .bundledEngine })
    }

    /**
     The strict ranking, and then everything else that could still start the game.

     ``ranked(satisfying:from:)`` only offers runtimes that *satisfy* the profile, which is
     the right answer to "what should this game run on" and the wrong answer to "what now?".
     When the one build that satisfies it cannot boot a prefix, the alternative isn't another
     satisfying build — there isn't one — it is a worse one.

     `direct3DOnMetal` tolerates that: a Direct3D 11 game on wined3d runs badly, and badly
     beats not starting at all. `modernNetworking` does not. The bundled engine cannot do it
     at all, and a game that needs it would fail later, further in, and less legibly than a
     refusal here.

     - Note: this is what makes the fallback in `Runtime.select`'s own documentation true.
       It said "the engine stays reachable behind it", and it wasn't: ``satisfies(_:)``
       filtered every non-DXMT runtime out before the ranking was built, so the list had one
       entry and there was nothing behind anything. Horizon Chase Turbo found that out.
     */
    static func rankedWithCompromises(satisfying requirements: RuntimeProfile.Requirements,
                                      from candidates: [Runtime]? = nil) -> [Runtime] {
        let all = candidates ?? discoverAll()
        let strict = ranked(satisfying: requirements, from: all)

        // No compromises for either of these. The compromise list is led by the bundled
        // engine, and for both requirements the bundled engine is the specific thing being
        // ruled out — falling back to it means failing later, further in, and less legibly
        // than a refusal here.
        guard !requirements.modernNetworking, !requirements.nativeThirtyTwoBit else { return strict }

        let placed = Set(strict.map(\.id))

        // The preference travels into the compromises as well. A game sent to an
        // implementation is sent there whether or not the build carrying it also satisfies
        // everything else the game asked for.
        let compromises = ranked(satisfying: .init(preferredDirect3D: requirements.preferredDirect3D),
                                 from: all.filter { !placed.contains($0.id) })

        return strict + compromises
    }

    /// Catalogue order is preference order. Anything the catalogue doesn't mention keeps its
    /// own order, after everything it does.
    /// Which Direct3D-on-Metal path a game is sent to, in order.
    ///
    /// D3DMetal last, behind wined3d. It draws better than wined3d and still loses, and that
    /// needs saying plainly rather than being buried in a filter: `D3DMetal.framework` is
    /// Apple's, it arrives in the Game Porting Toolkit evaluation environment, and it is
    /// present inside the bundled engine — so every automatic choice landing on it is this
    /// project making a default out of something it may not be allowed to distribute. A
    /// default nobody is sure of is not a default.
    ///
    /// Last rather than removed: a Mac that already has the Game Porting Toolkit can still
    /// reach it, and it is the honest final fallback when nothing else will start. What
    /// changed is that nothing *chooses* it.
    ///
    /// Its own function because the ranking around it reads the filesystem — `isInstalled` and
    /// `capabilities` both do — so the ordering is the only part of that decision a test can
    /// hold, and it is the part that carries the policy.
    static func direct3DOnMetalOrder(dxmt: [Runtime],
                                     wined3d: [Runtime],
                                     appleD3DMetal: [Runtime]) -> [Runtime] {
        dxmt + wined3d + appleD3DMetal
    }

    private static func byCatalogueOrder(_ runtimes: [Runtime]) -> [Runtime] {
        var remaining = runtimes
        var ordered: [Runtime] = []

        for release in RuntimeRelease.catalogue {
            if let index = remaining.firstIndex(where: { $0.id == "managed:\(release.id)" }) {
                ordered.append(remaining.remove(at: index))
            }
        }

        return ordered + remaining
    }

    /// Catalogue order is preference order, so first match wins.
    private static func preferredByCatalogue(among runtimes: [Runtime]) -> Runtime? {
        for release in RuntimeRelease.catalogue {
            if let match = runtimes.first(where: { $0.id == "managed:\(release.id)" }) {
                return match
            }
        }

        return nil
    }
}

extension RuntimeRelease {
    /// What this build will be able to do once installed.
    ///
    /// `direct3DOnMetal` is a claim about the *build*, not about what is on disk: it says DXMT
    /// can be installed into it, which Mythic then has to actually do. See
    /// ``exposesMetalEscapes``.
    var capabilities: Runtime.Capabilities {
        .init(direct3DOnMetal: exposesMetalEscapes ? .dxmt : nil,
              modernNetworking: version >= .init(9, 0, 0),
              nativeThirtyTwoBit: hasNativeThirtyTwoBit)
    }

    /// The first catalogue release that could serve these requirements once installed.
    ///
    /// Catalogue order is preference order, so first match is best match.
    static func release(satisfying requirements: RuntimeProfile.Requirements) -> RuntimeRelease? {
        catalogue.first { release in
            let capabilities = release.capabilities

            if requirements.direct3DOnMetal, capabilities.direct3DOnMetal == nil { return false }
            if requirements.modernNetworking, !capabilities.modernNetworking { return false }
            if requirements.nativeThirtyTwoBit, !capabilities.nativeThirtyTwoBit { return false }

            return true
        }
    }
}
