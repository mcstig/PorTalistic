//
//  RuntimeRelease.swift
//  Mythic
//
//  Created by Claude (Cowork) on 6/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SemanticVersion

/**
 A Wine runtime Mythic knows how to fetch and install by itself.

 Deliberately not routed through Homebrew. An app driving a package manager inherits all of
 its failure modes — Homebrew has to be installed, third-party taps need interactive trust,
 installs want an admin password, and the artifacts land somewhere another tool owns. That
 stopped being theoretical on 1 September 2026, when the `wine-stable` cask was disabled for
 failing Gatekeeper checks and became uninstallable.

 The artifacts themselves are just tarballs on GitHub releases, so Mythic fetches the same
 file Homebrew would have, verifies it against a pinned digest, and unpacks it into its own
 directory. No package manager, no password, nothing shared.
 */
struct RuntimeRelease: Identifiable, Hashable {
    /// Stable identifier, also the directory name under `Runtimes/`.
    let id: String

    let name: String
    let version: SemanticVersion

    let downloadURL: URL

    /// SHA-256 of the download, lowercase hex.
    ///
    /// Not optional, and not decorative. Mythic clears the quarantine attribute after
    /// unpacking — without that, nothing it installs will run — which means Gatekeeper's
    /// notarisation check is not going to catch a substituted archive. This digest is the
    /// thing standing in its place, so a release without one doesn't belong in the catalogue.
    let sha256: String

    /// Path within the extracted archive to the directory that becomes the runtime root.
    let payloadSubpath: String

    /// Path from the installed runtime root to `wine64`.
    let executableSubpath: String

    /// Shown to the user when choosing between runtimes.
    let summary: String
}

extension RuntimeRelease {
    /// Runtimes Mythic can install on request.
    ///
    /// - Note: Currently compiled in. It wants to become a signed manifest fetched at
    ///   runtime so new builds don't require an app update — but a hardcoded list with
    ///   pinned digests is the safer starting point, and the shape won't change.
    static let catalogue: [RuntimeRelease] = [
        .init(
            id: "wine-stable-11.0",
            name: "Wine Stable 11.0",
            version: .init(11, 0, 0),
            downloadURL: .init(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")!,
            sha256: "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388",
            payloadSubpath: "Wine Stable.app",
            // Wine 11 ships a single `wine` binary. `wine64` is gone: the new WoW64
            // architecture runs 32-bit Windows processes through the same 64-bit binary,
            // so the split that Mythic's bundled 7.7 engine still has no longer exists.
            executableSubpath: "Contents/Resources/wine/bin/wine",
            summary: """
                Mainline Wine, four major versions newer than the bundled engine. No D3DMetal, \
                so it isn't the right choice for demanding games — but it's the current \
                reference point for anything the older engine can't run, the Steam client above all.
                """
        )
    ]

    /// The catalogue entry matching an installed runtime, if it came from here.
    static func matching(_ runtime: Runtime) -> RuntimeRelease? {
        catalogue.first { $0.id == runtime.id.replacingOccurrences(of: "managed:", with: "") }
    }
}
