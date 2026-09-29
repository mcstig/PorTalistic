//
//  RuntimeRetentionRegressionTests.swift
//  PorTalisticTests
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SemanticVersion
import Testing

@testable import PorTalistic

/**
 Which Wine builds get deleted, and which never do.

 Every rule here is destructive when it goes wrong, and none of it is visible until someone
 has lost something. Deleting the runtime under a container takes a prefix with save games in
 it; deleting across families takes Wine Stable away because three DXMT builds arrived;
 deleting too many leaves no older build to fall back to when the newest one regresses, which
 is the entire reason more than one is kept.

 `RuntimeRetention.prunable` is a pure function so that all of it can be checked over
 constructed values rather than against a real `Runtimes/` directory.
 */
@Suite("Runtime retention")
struct RuntimeRetentionRegressionTests {
    // MARK: - Fixtures

    private func release(_ id: String, _ family: String?, _ version: SemanticVersion) -> RuntimeRelease {
        .init(id: id,
              name: id,
              version: version,
              downloadURL: .init(string: "https://github.com/mcstig/PorTalistic/releases/download/\(id)/\(id).tar.xz")!,
              sha256: String(repeating: "a", count: 64),
              payloadSubpath: id,
              executableSubpath: "bin/wine",
              summary: id,
              family: family)
    }

    private func runtime(_ releaseID: String,
                         version: SemanticVersion?,
                         origin: Runtime.Origin = .managed) -> Runtime {
        var runtime = Runtime(id: origin == .managed ? "managed:\(releaseID)" : releaseID,
                              name: releaseID,
                              executableURL: .init(filePath: "/tmp/\(releaseID)/bin/wine"),
                              origin: origin)
        runtime.version = version
        return runtime
    }

    /// A manifest carrying the given runtime entries and nothing else.
    private static func manifest(withRuntimes entries: String) throws -> CompatibilityManifest {
        let json = """
        { "formatVersion": 1, "runtimes": [\(entries)], "games": [] }
        """

        return try JSONDecoder().decode(CompatibilityManifest.self, from: Data(json.utf8))
    }

    /// Five builds of one lineage, newest last.
    private var dxmtCatalogue: [RuntimeRelease] {
        [
            release("wine-dxmt-11.24", "wine-dxmt", .init(11, 24, 0)),
            release("wine-dxmt-11.22", "wine-dxmt", .init(11, 22, 0)),
            release("wine-dxmt-11.20", "wine-dxmt", .init(11, 20, 0)),
            release("wine-dxmt-11.18", "wine-dxmt", .init(11, 18, 0)),
            release("wine-dxmt-11.16", "wine-dxmt", .init(11, 16, 0))
        ]
    }

    private var dxmtInstalled: [Runtime] {
        dxmtCatalogue.map { runtime($0.id, version: $0.version) }
    }

    // MARK: - How many are kept

    @Test("Three builds of a family survive, and they are the three newest")
    func keepsTheNewestThree() {
        let prunable = RuntimeRetention.prunable(among: dxmtInstalled,
                                                 pinnedRuntimeIDs: [],
                                                 catalogue: dxmtCatalogue)

        #expect(prunable.map(\.id).sorted() == ["managed:wine-dxmt-11.16", "managed:wine-dxmt-11.18"])
        #expect(RuntimeRetention.keptPerFamily == 3,
                "the number is the policy — if it moves, it moves here and in what the user is told")
    }

    @Test("Three or fewer builds are never touched")
    func keepsEverythingBelowTheLimit() {
        for count in 1...RuntimeRetention.keptPerFamily {
            let installed = Array(dxmtInstalled.prefix(count))
            let prunable = RuntimeRetention.prunable(among: installed,
                                                     pinnedRuntimeIDs: [],
                                                     catalogue: dxmtCatalogue)

            #expect(prunable.isEmpty, "\(count) build(s) of one family should all be kept")
        }
    }

    @Test("A sweep never empties a family")
    func neverEmptiesAFamily() {
        let installed = dxmtInstalled
        let prunable = RuntimeRetention.prunable(among: installed,
                                                 pinnedRuntimeIDs: [],
                                                 catalogue: dxmtCatalogue)

        #expect(installed.count - prunable.count >= RuntimeRetention.keptPerFamily)
    }

    // MARK: - Families don't bleed into each other

    @Test("Newer builds of one lineage never evict a different lineage")
    func doesNotPruneAcrossFamilies() {
        // The fault this exists for: three DXMT releases land, "keep the latest three" is
        // read globally, and Wine Stable — the fallback for everything DXMT can't run, and
        // the only build that can run the Steam client — is deleted for being old.
        let catalogue = dxmtCatalogue + [
            release("wine-stable-11.0", "wine-stable", .init(11, 0, 0)),
            release("wine-sikarugir-11.0", "wine-sikarugir", .init(11, 0, 0))
        ]

        let installed = dxmtInstalled + [
            runtime("wine-stable-11.0", version: .init(11, 0, 0)),
            runtime("wine-sikarugir-11.0", version: .init(11, 0, 0))
        ]

        let prunable = RuntimeRetention.prunable(among: installed,
                                                 pinnedRuntimeIDs: [],
                                                 catalogue: catalogue)

        #expect(!prunable.contains { $0.id == "managed:wine-stable-11.0" })
        #expect(!prunable.contains { $0.id == "managed:wine-sikarugir-11.0" })
    }

    @Test("A build declaring no family is its own family, so nothing prunes it")
    func unfamiliedBuildIsItsOwnFamily() {
        let catalogue = dxmtCatalogue + [release("some-other-build", nil, .init(9, 0, 0))]
        let installed = dxmtInstalled + [runtime("some-other-build", version: .init(9, 0, 0))]

        let prunable = RuntimeRetention.prunable(among: installed,
                                                 pinnedRuntimeIDs: [],
                                                 catalogue: catalogue)

        #expect(!prunable.contains { $0.id == "managed:some-other-build" })
    }

    @Test("A build dropped from the catalogue still sweeps with its lineage")
    func fallsBackToTheFamilyConvention() {
        // An entry is normally removed from the manifest once a newer one replaces it. If that
        // made the installed copy its own family, the builds most in need of sweeping would be
        // the ones kept forever.
        let catalogue = Array(dxmtCatalogue.prefix(3))
        let prunable = RuntimeRetention.prunable(among: dxmtInstalled,
                                                 pinnedRuntimeIDs: [],
                                                 catalogue: catalogue)

        #expect(prunable.map(\.id).sorted() == ["managed:wine-dxmt-11.16", "managed:wine-dxmt-11.18"])
    }

    @Test("Stripping a trailing version finds the lineage, and inventing one is refused")
    func familyByConvention() {
        #expect(RuntimeRetention.familyByConvention(of: "managed:wine-dxmt-11.16") == "wine-dxmt")
        #expect(RuntimeRetention.familyByConvention(of: "wine-stable-11.0_1") == "wine-stable-11.0_1")
        #expect(RuntimeRetention.familyByConvention(of: "wine-dxmt") == "wine-dxmt")
        #expect(RuntimeRetention.familyByConvention(of: "11.16") == "11.16")
    }

    // MARK: - What is never deleted

    @Test("A build a container was created against is kept whatever its age")
    func keepsPinnedRuntimes() {
        // Containers are one per runtime and a container is a Wine prefix: drive_c, the
        // registry, and whatever the game wrote into Documents. Deleting the runtime under one
        // leaves a prefix a newer Wine built being served by an older one, which Wine has no
        // downgrade path for.
        let prunable = RuntimeRetention.prunable(among: dxmtInstalled,
                                                 pinnedRuntimeIDs: ["managed:wine-dxmt-11.16"],
                                                 catalogue: dxmtCatalogue)

        #expect(prunable.map(\.id) == ["managed:wine-dxmt-11.18"])
    }

    @Test("Every old build being pinned means nothing is deleted")
    func pinnedEverythingPrunesNothing() {
        let prunable = RuntimeRetention.prunable(among: dxmtInstalled,
                                                 pinnedRuntimeIDs: Set(dxmtInstalled.map(\.id)),
                                                 catalogue: dxmtCatalogue)

        #expect(prunable.isEmpty)
    }

    @Test("The bundled engine and the user's own Wine installs are never candidates")
    func onlyTouchesWhatTheAppInstalled() {
        let installed = dxmtInstalled + [
            Runtime.bundled,
            runtime("external:/Applications/Whisky.app/bin/wine", version: .init(9, 0, 0), origin: .external)
        ]

        let prunable = RuntimeRetention.prunable(among: installed,
                                                 pinnedRuntimeIDs: [],
                                                 catalogue: dxmtCatalogue)

        #expect(prunable.allSatisfy { $0.origin == .managed })
        #expect(!prunable.contains { $0.id == Runtime.bundled.id })
    }

    @Test("A build whose version didn't parse is kept rather than assumed old")
    func keepsUnversionedBuilds() {
        let installed = dxmtInstalled + [runtime("wine-dxmt-unknown", version: nil)]
        let prunable = RuntimeRetention.prunable(among: installed,
                                                 pinnedRuntimeIDs: [],
                                                 catalogue: dxmtCatalogue)

        #expect(!prunable.contains { $0.id == "managed:wine-dxmt-unknown" })
    }

    // MARK: - When a newer build is fetched at all

    @Test("A newer build of the same lineage is an upgrade")
    func upgradeWithinFamily() {
        let newest = release("wine-dxmt-11.24", "wine-dxmt", .init(11, 24, 0))
        let serving = runtime("wine-dxmt-11.16", version: .init(11, 16, 0))

        #expect(RuntimeRetention.isUpgrade(newest, over: serving, catalogue: dxmtCatalogue))
    }

    @Test("A build of another lineage is not an upgrade, however new")
    func differentFamilyIsNotAnUpgrade() {
        let catalogue = dxmtCatalogue + [release("wine-stable-11.0", "wine-stable", .init(11, 0, 0))]
        let newest = release("wine-dxmt-11.24", "wine-dxmt", .init(11, 24, 0))
        let serving = runtime("wine-stable-11.0", version: .init(11, 0, 0))

        #expect(!RuntimeRetention.isUpgrade(newest, over: serving, catalogue: catalogue))
    }

    @Test("The bundled engine is never upgraded out from under a game")
    func bundledEngineIsNotUpgraded() {
        // Otherwise a library that runs perfectly well on the engine the app ships with gets a
        // several-hundred-megabyte download per game the first time a manifest lands.
        let newest = release("wine-dxmt-11.24", "wine-dxmt", .init(11, 24, 0))

        #expect(!RuntimeRetention.isUpgrade(newest, over: .bundled, catalogue: dxmtCatalogue))
    }

    @Test("The build already serving a game is not an upgrade over itself")
    func sameBuildIsNotAnUpgrade() {
        let newest = release("wine-dxmt-11.24", "wine-dxmt", .init(11, 24, 0))
        let serving = runtime("wine-dxmt-11.24", version: .init(11, 24, 0))

        #expect(!RuntimeRetention.isUpgrade(newest, over: serving, catalogue: dxmtCatalogue))
    }

    // MARK: - Preference order

    @Test("A newer build of a lineage is preferred over the one it supersedes")
    func newerBuildRanksAhead() throws {
        // Catalogue order is preference order and a manifest's new entries are appended, so a
        // newer build landed *behind* the one it replaces and was downloaded, installed, and
        // never selected. Two ids of an invented lineage, listed oldest first, so this says
        // the same thing whichever configuration it is built in.
        let manifest = try Self.manifest(withRuntimes: """
            {
              "id": "wine-testfamily-1.0",
              "name": "Older",
              "version": "1.0.0",
              "downloadURL": "https://github.com/mcstig/PorTalistic/releases/download/t/older.tar.xz",
              "sha256": "\(String(repeating: "b", count: 64))",
              "payloadSubpath": "older",
              "executableSubpath": "bin/wine",
              "summary": "Older.",
              "family": "wine-testfamily"
            },
            {
              "id": "wine-testfamily-2.0",
              "name": "Newer",
              "version": "2.0.0",
              "downloadURL": "https://github.com/mcstig/PorTalistic/releases/download/t/newer.tar.xz",
              "sha256": "\(String(repeating: "c", count: 64))",
              "payloadSubpath": "newer",
              "executableSubpath": "bin/wine",
              "summary": "Newer.",
              "family": "wine-testfamily"
            }
            """)

        let family = manifest.resolvedRuntimes().filter { $0.resolvedFamily == "wine-testfamily" }

        try #require(family.count == 2)
        #expect(family.map(\.id) == ["wine-testfamily-2.0", "wine-testfamily-1.0"],
                "within a family the catalogue has to read newest first, or the newer build is never chosen")
    }

    @Test("Reordering a family leaves the order between families alone")
    func familyOrderingIsLocal() throws {
        // The order *between* families is a deliberate preference — the bundled engine's path
        // first, DXMT ahead of wined3d for Direct3D 11 — so the fix for intra-family order
        // must not become a sort of the whole catalogue by version.
        let manifest = try Self.manifest(withRuntimes: """
            {
              "id": "wine-testfamily-9.0",
              "name": "Invented",
              "version": "9.0.0",
              "downloadURL": "https://github.com/mcstig/PorTalistic/releases/download/t/invented.tar.xz",
              "sha256": "\(String(repeating: "d", count: 64))",
              "payloadSubpath": "invented",
              "executableSubpath": "bin/wine",
              "summary": "Invented.",
              "family": "wine-testfamily"
            }
            """)

        func familyOrder(_ releases: [RuntimeRelease]) -> [String] {
            var seen: [String] = []
            for family in releases.map(\.resolvedFamily) where !seen.contains(family) {
                seen.append(family)
            }
            return seen
        }

        let shipped = familyOrder(RuntimeRelease.compiledIn)
        let resolved = familyOrder(manifest.resolvedRuntimes())

        #expect(resolved.filter(shipped.contains) == shipped,
                "the families the app shipped with have to keep the order they shipped in")
    }
    // MARK: - What a Direct3D 11 game is sent to

    @Test("Apple's D3DMetal is never chosen automatically, and stays reachable last")
    func appleD3DMetalRanksLast() {
        // `D3DMetal.framework` is Apple's, it arrives in the Game Porting Toolkit evaluation
        // environment, and it is present inside the bundled engine — so an automatic choice
        // landing on it makes a default out of something this project may not be allowed to
        // distribute. It draws better than wined3d and still has to lose.
        let dxmt = [runtime("wine-dxmt-11.16", version: .init(11, 16, 0))]
        let wined3d = [runtime("wine-stable-11.0", version: .init(11, 0, 0))]
        let apple = [Runtime.bundled]

        let order = Runtime.direct3DOnMetalOrder(dxmt: dxmt, wined3d: wined3d, appleD3DMetal: apple)

        #expect(order.map(\.id) == ["managed:wine-dxmt-11.16", "managed:wine-stable-11.0", Runtime.bundled.id])
        #expect(order.last?.id == Runtime.bundled.id,
                "Apple's implementation has to be last, not absent — it is the honest fallback when nothing else starts")
    }

    @Test("With no DXMT build, a Direct3D 11 game still prefers wined3d over Apple's layer")
    func wined3dBeatsAppleWhenDXMTIsMissing() {
        let order = Runtime.direct3DOnMetalOrder(dxmt: [],
                                                 wined3d: [runtime("wine-stable-11.0", version: .init(11, 0, 0))],
                                                 appleD3DMetal: [Runtime.bundled])

        #expect(order.first?.id == "managed:wine-stable-11.0")
    }
    // MARK: - When nothing can run a game

    @Test("A refusal names the capability nothing could provide")
    func refusalExplainsItself() throws {
        // "PorTalistic has no way to run Blades of Time." is the one thing the person already
        // knew, and it reads as "this game is not supported" when the truth is "the Wine build
        // that runs it has not been published yet". Those call for opposite reactions.
        let error = Provisioner.NoViableRuntimeError(
            title: "Blades of Time",
            unmet: RuntimeProfile.Requirements(thirtyTwoBit: true, nativeThirtyTwoBit: true).unmetDescriptions
        )

        let message = try #require(error.errorDescription)

        #expect(message.contains("Blades of Time"))
        #expect(message.contains("32-bit"), "the message has to name what was missing")
        #expect(error.recoverySuggestion?.isEmpty == false)
    }

    @Test("A preference is never reported as the reason a game refused to start")
    func preferencesAreNotUnmetRequirements() {
        // `preferredDirect3D` is a preference the ranking reads, not a demand a runtime has to
        // satisfy — naming it would send somebody hunting for a Wine build that was never the
        // problem.
        var requirements: RuntimeProfile.Requirements = .init()
        requirements.preferredDirect3D = .dxmt

        #expect(requirements.unmetDescriptions.isEmpty)
    }

    @Test("A game that asked for nothing unusual gets the plain message")
    func plainRefusalWhenNothingWasDemanded() throws {
        let error = Provisioner.NoViableRuntimeError(title: "Some Game")

        #expect(try #require(error.errorDescription).contains("no way to run"))
        #expect(error.recoverySuggestion == nil, "there is nothing useful to suggest without a named cause")
    }
}
