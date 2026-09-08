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
    /// The catalogue is ordered by preference, best first.
    ///
    /// "Best" here means the combination that actually works, which took a while to find.
    /// Mainline Wine and the bundled engine each have half of what a Windows game needs on a
    /// Mac and neither has both:
    ///
    ///   - The bundled engine is Game Porting Toolkit derived and carries Apple's D3DMetal, so
    ///     Direct3D 11 works. It is also Wine 7.7, and its socket layer is old enough that the
    ///     Steam client trips over it continuously.
    ///   - Mainline Wine 11 has four years of fixes and working sockets, and only wined3d,
    ///     which on macOS has OpenGL 2.1 underneath: Direct3D feature level 9_3 and an adapter
    ///     that claims to be an NVIDIA GeForce 6800.
    ///
    /// DXMT closes that gap, but only on a Wine that exposes `winemac.drv`'s Metal entry
    /// points — its own guide asks for a CrossOver-derived Wine 24+. On a Wine without them,
    /// DXMT half-works in the worst way: adapter enumeration and device creation succeed, so
    /// everything looks right, and then every swap chain fails with `EGL_BAD_ALLOC` and every
    /// window that needs one is black.
    ///
    /// The Sikarugir build is that Wine. It ships a `dxmt_extescape` marker for the escape
    /// interface DXMT needs and a `no_d3dmetal` one to say it doesn't carry Apple's
    /// implementation, which is the pairing we want.
    ///
    /// - Note: Currently compiled in. It wants to become a signed manifest fetched at
    ///   runtime so new builds don't require an app update — but a hardcoded list with
    ///   pinned digests is the safer starting point, and the shape won't change.
    static let catalogue: [RuntimeRelease] = [
        .init(
            id: "wine-sikarugir-11.0",
            name: "Sikarugir Wine 11.0",
            version: .init(11, 0, 0),
            downloadURL: .init(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS11WineSikarugir11.0.tar.xz")!,
            sha256: "d12fa09149b9afd3be349d726eecea6b2216ac574c91f93f56d872bb6ca7b795",
            payloadSubpath: "wswine.bundle",
            executableSubpath: "bin/wine",
            summary: """
                Wine 11 built for DXMT, which is what gives it Direct3D 11 on Metal. The one \
                runtime here that has both modern Wine and working Direct3D — install DXMT \
                from Settings › Engine after installing this.
                """
        ),
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
