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
    }

    var capabilities: Capabilities {
        .init(direct3DOnMetal: direct3DOnMetalProvider,
              modernNetworking: providesModernNetworking)
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

    func satisfies(_ requirements: RuntimeProfile.Requirements) -> Bool {
        if requirements.direct3DOnMetal, capabilities.direct3DOnMetal == nil { return false }
        if requirements.modernNetworking, !capabilities.modernNetworking { return false }
        return true
    }

    /// The best installed runtime for a set of requirements, or `nil` if none can serve them.
    ///
    /// The ranking follows what this project has observed and what it is allowed to ship, not
    /// a version comparison:
    ///
    /// - Needs modern networking: the newest viable build, in catalogue order. Nothing else
    ///   will do — this is the requirement the bundled engine cannot meet at all.
    /// - Needs Direct3D on Metal: a DXMT build first, then Apple's D3DMetal. DXMT is the less
    ///   mature of the two, which is uncomfortable, but it is the one that can be shipped, so
    ///   preferring D3DMetal would mean building on something that has to be removed later.
    ///   The engine stays reachable behind it because DXMT depends on a single Wine build
    ///   that on some Macs cannot create a container at all, and a fallback that works beats
    ///   a principle that doesn't.
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
        let viable = (candidates ?? discoverAll())
            .filter { $0.isInstalled && $0.satisfies(requirements) }

        guard !viable.isEmpty else { return [] }

        if requirements.modernNetworking {
            return byCatalogueOrder(viable)
        }

        if requirements.direct3DOnMetal {
            let byDXMT = byCatalogueOrder(viable.filter { $0.capabilities.direct3DOnMetal == .dxmt })

            // Among Apple's implementations, prefer one this app didn't put there. A Game
            // Porting Toolkit or Whisky install is the user's own copy under their own
            // licence; the bundled engine is a copy the app fetched, which is the one with a
            // question mark over it.
            let d3dMetal = viable.filter { $0.capabilities.direct3DOnMetal == .appleD3DMetal }
            let byD3DMetal = d3dMetal.filter { $0.origin != .bundledEngine }
                + d3dMetal.filter { $0.origin == .bundledEngine }

            let placed = Set((byDXMT + byD3DMetal).map(\.id))
            let rest = byCatalogueOrder(viable.filter { !placed.contains($0.id) })

            return byDXMT + byD3DMetal + rest
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

        guard !requirements.modernNetworking else { return strict }

        let placed = Set(strict.map(\.id))
        let compromises = ranked(satisfying: .init(),
                                 from: all.filter { !placed.contains($0.id) })

        return strict + compromises
    }

    /// Catalogue order is preference order. Anything the catalogue doesn't mention keeps its
    /// own order, after everything it does.
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
              modernNetworking: version >= .init(9, 0, 0))
    }

    /// The first catalogue release that could serve these requirements once installed.
    ///
    /// Catalogue order is preference order, so first match is best match.
    static func release(satisfying requirements: RuntimeProfile.Requirements) -> RuntimeRelease? {
        catalogue.first { release in
            let capabilities = release.capabilities

            if requirements.direct3DOnMetal, capabilities.direct3DOnMetal == nil { return false }
            if requirements.modernNetworking, !capabilities.modernNetworking { return false }

            return true
        }
    }
}
