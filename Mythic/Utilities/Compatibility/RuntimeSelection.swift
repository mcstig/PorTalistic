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
    /// What a runtime can do, in the terms a profile asks about.
    struct Capabilities: Hashable {
        var direct3DOnMetal: Bool
        var modernNetworking: Bool
    }

    var capabilities: Capabilities {
        .init(direct3DOnMetal: providesDirect3DOnMetal,
              modernNetworking: providesModernNetworking)
    }

    /// Direct3D 10 or newer, translated to Metal.
    ///
    /// Two implementations, and which one a build has is not a version question. The bundled
    /// engine is Game Porting Toolkit derived and carries Apple's D3DMetal. Everything else
    /// needs DXMT.
    ///
    /// But DXMT being *present* is not the same as DXMT working, and the difference is not
    /// academic: on this machine DXMT is installed into Wine Stable 11, a build with no Metal
    /// escape interface, where it half-works in the worst possible way — device creation
    /// succeeds, everything looks right, and every swap chain fails with `EGL_BAD_ALLOC`. An
    /// earlier version of this answered yes for that runtime, which would have sent Direct3D
    /// 11 games to it in preference to the engine that can actually draw them.
    ///
    /// So installed DXMT only counts on a build known to expose the escapes. A build that
    /// *ships* DXMT is taken at its word, since shipping it is the claim.
    private var providesDirect3DOnMetal: Bool {
        if origin == .bundledEngine { return true }
        if Wine.DXMT.isShippedByRuntime(self) { return true }

        return Wine.DXMT.isInstalled(in: self)
            && RuntimeRelease.matching(self)?.exposesMetalEscapes == true
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
        if requirements.direct3DOnMetal, !capabilities.direct3DOnMetal { return false }
        if requirements.modernNetworking, !capabilities.modernNetworking { return false }
        return true
    }

    /// The best installed runtime for a set of requirements, or `nil` if none can serve them.
    ///
    /// The ranking follows what this project has actually observed, not a version comparison:
    ///
    /// - Needs modern networking: the newest viable build, in catalogue order. Nothing else
    ///   will do — this is the requirement the bundled engine cannot meet at all.
    /// - Needs Direct3D on Metal and not networking: the bundled engine. Its D3DMetal is
    ///   Apple's own and is the most exercised path here; DXMT is the alternative and is the
    ///   one that on some Macs cannot create a container at all.
    /// - Neither: the bundled engine, for the same reason.
    ///
    /// Note what this does *not* do: prefer the newest version. Two builds of Wine 11 are not
    /// interchangeable when one exposes the entry points DXMT needs and the other doesn't,
    /// and "newest" would have sent every Direct3D 11 game to a runtime with no way to draw.
    static func select(satisfying requirements: RuntimeProfile.Requirements,
                       from candidates: [Runtime]? = nil) -> Runtime? {
        let viable = (candidates ?? discoverAll())
            .filter { $0.isInstalled && $0.satisfies(requirements) }

        guard !viable.isEmpty else { return nil }

        if requirements.modernNetworking {
            for release in RuntimeRelease.catalogue {
                if let match = viable.first(where: { $0.id == "managed:\(release.id)" }) {
                    return match
                }
            }

            return viable.first
        }

        return viable.first(where: { $0.origin == .bundledEngine }) ?? viable.first
    }
}

extension RuntimeRelease {
    /// What this build will be able to do once installed.
    ///
    /// `direct3DOnMetal` is a claim about the *build*, not about what is on disk: it says DXMT
    /// can be installed into it, which Mythic then has to actually do. See
    /// ``exposesMetalEscapes``.
    var capabilities: Runtime.Capabilities {
        .init(direct3DOnMetal: exposesMetalEscapes,
              modernNetworking: version >= .init(9, 0, 0))
    }

    /// The first catalogue release that could serve these requirements once installed.
    ///
    /// Catalogue order is preference order, so first match is best match.
    static func release(satisfying requirements: RuntimeProfile.Requirements) -> RuntimeRelease? {
        catalogue.first { release in
            let capabilities = release.capabilities

            if requirements.direct3DOnMetal, !capabilities.direct3DOnMetal { return false }
            if requirements.modernNetworking, !capabilities.modernNetworking { return false }

            return true
        }
    }
}
