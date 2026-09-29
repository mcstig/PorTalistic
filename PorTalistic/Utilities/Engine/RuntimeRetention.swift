//
//  RuntimeRetention.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog
import SemanticVersion

/**
 How many builds of one Wine lineage are kept, and which of them may be deleted.

 A new Wine version arrives as a new id rather than as new bytes behind an old one — see
 `CompatibilityManifest`'s second rule — so without a retention policy every version ever
 published accumulates on disk, each one a full Wine tree. With too aggressive a one, a
 regression in the newest build leaves nothing to fall back to.

 Three per family is the answer to both. It is a deliberate number and not a tuning knob:
 the reason for keeping more than one is that the newest build may be worse than the one
 before it, and the reason for keeping fewer than everything is that these are hundreds of
 megabytes each.

 # What is never deleted

 - **Anything the app didn't install.** The bundled engine, and a Game Porting Toolkit,
   CrossOver or Whisky install belonging to the user. `RuntimeInstaller.remove(_:)` refuses
   these too; this refuses them first, so the refusal is never load-bearing.
 - **A build with a container.** Containers are one per runtime, and a container is a Wine
   prefix — `drive_c`, the registry, and whatever save games the game wrote into
   `Documents`. Deleting the runtime under one leaves a prefix built by a newer Wine being
   served by an older one, which Wine has no downgrade path for, and the app would quietly
   fall back to the bundled engine to do it (see `Wine.runtime(forContainerAt:)`). So a
   build the user has actually launched a game on stays until they remove that container
   themselves. In practice that makes this a sweep of builds that were *fetched* and never
   used, which is exactly what upgrading produces.
 - **A build whose version can't be read.** Ordering decides what gets deleted, and a build
   whose `--version` didn't parse cannot be ordered. It is kept and reported rather than
   sorted to the bottom, because "unparseable" is a property of the binary, not an age.
 */
enum RuntimeRetention {
    static let log: Logger = .custom(category: "RuntimeRetention")

    /// Builds of one family kept on disk.
    ///
    /// One source, because the number appears in the sweep, in the tests and in what the user
    /// is told — three copies of it would drift.
    static let keptPerFamily: Int = 3

    // MARK: - The decision

    /// Which installed builds may be deleted, newest kept.
    ///
    /// Pure, and separated from the deletion for that reason: every rule above is a thing to
    /// get wrong once and never notice, so all of them are decided over plain values a test
    /// can construct.
    ///
    /// - Parameters:
    ///   - installed: every runtime on the machine, as ``Runtime/discoverAll()`` reports them.
    ///   - pinnedRuntimeIDs: the `runtimeID` of every container that exists. A build named
    ///     here is kept whatever its age.
    ///   - catalogue: where family and version come from when the build is still listed.
    static func prunable(among installed: [Runtime],
                         pinnedRuntimeIDs: Set<String>,
                         catalogue: [RuntimeRelease] = RuntimeRelease.catalogue) -> [Runtime] {
        struct Managed {
            let runtime: Runtime
            let version: SemanticVersion
        }

        var byFamily: [String: [Managed]] = .init()

        for runtime in installed where runtime.origin == .managed {
            let release = catalogue.first { "managed:\($0.id)" == runtime.id }
            let family = release?.resolvedFamily ?? familyByConvention(of: runtime.id)

            guard let version = release?.version ?? runtime.version else {
                log.notice("Keeping \(runtime.id, privacy: .public): its version didn't parse, so it can't be ordered")
                continue
            }

            byFamily[family, default: []].append(.init(runtime: runtime, version: version))
        }

        var prunable: [Runtime] = []

        for (_, members) in byFamily where members.count > keptPerFamily {
            let ordered = members.sorted { left, right in
                // Id as the tie-break so the answer doesn't depend on directory order for two
                // builds reporting the same version.
                left.version == right.version
                    ? left.runtime.id > right.runtime.id
                    : left.version > right.version
            }

            for member in ordered.dropFirst(keptPerFamily) {
                guard !pinnedRuntimeIDs.contains(member.runtime.id) else {
                    log.notice("Keeping \(member.runtime.id, privacy: .public): a container was created against it")
                    continue
                }

                prunable.append(member.runtime)
            }
        }

        return prunable
    }

    /// Whether `release` is a newer build of the same lineage as `runtime`.
    ///
    /// The whole test for "fetch this even though something already works". False when
    /// `runtime` isn't a managed build from the catalogue, which is what keeps a library
    /// running happily on the bundled engine from being handed a download per game.
    static func isUpgrade(_ release: RuntimeRelease,
                          over runtime: Runtime,
                          catalogue: [RuntimeRelease] = RuntimeRelease.catalogue) -> Bool {
        guard let current = catalogue.first(where: { "managed:\($0.id)" == runtime.id }) else { return false }

        return current.resolvedFamily == release.resolvedFamily && release.version > current.version
    }

    /// The lineage of an id no longer in the catalogue, by stripping a trailing version.
    ///
    /// `"managed:wine-dxmt-11.16"` is `"wine-dxmt"`. Needed because an entry is normally
    /// removed from the manifest once a newer one replaces it, and a build the catalogue no
    /// longer describes would otherwise become its own family and never be swept — the ones
    /// most in need of sweeping kept forever.
    ///
    /// A convention, not a contract: an id with no trailing version is its own family, which
    /// is the same safe answer as declaring no family at all.
    static func familyByConvention(of runtimeID: String) -> String {
        let bare = runtimeID.replacingOccurrences(of: "managed:", with: "")

        guard let match = try? Regex(#"^(.+?)-\d+(?:\.\d+)*$"#).wholeMatch(in: bare),
              let family = match[1].substring else {
            return bare
        }

        return .init(family)
    }

    // MARK: - The sweep

    /// Delete what ``prunable(among:pinnedRuntimeIDs:catalogue:)`` names.
    ///
    /// Called after a successful install, which is the only moment the set can grow. Failure
    /// is logged and dropped: this reclaims disk, and an install that worked should not be
    /// reported as having failed because a directory wouldn't delete.
    static func sweep() {
        // Discover afresh: the caller has just installed something, and the cached list is
        // from before it existed — a stale list counts one member short and keeps a build it
        // should have pruned.
        Runtime.invalidateDiscoveryCache()

        let pinned = Set(Wine.containerObjects.compactMap(\.settings.runtimeID))
        let candidates = prunable(among: Runtime.discoverAll(), pinnedRuntimeIDs: pinned)

        guard !candidates.isEmpty else { return }

        for runtime in candidates {
            do {
                try RuntimeInstaller.remove(runtime)
                log.notice("Pruned \(runtime.id, privacy: .public); keeping the newest \(keptPerFamily, privacy: .public) of its family")
            } catch {
                log.error("Couldn't prune \(runtime.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        Runtime.invalidateDiscoveryCache()
    }
}
