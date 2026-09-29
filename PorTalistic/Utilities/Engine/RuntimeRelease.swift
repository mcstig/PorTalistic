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

    /// The lineage this build belongs to, for retention and for ordering.
    ///
    /// "Keep the latest three builds" has to mean the latest three *of the same thing*. A new
    /// Wine version arrives as a new id — `CompatibilityManifest`'s second rule forbids
    /// repointing an existing one at different bytes — so three DXMT releases landing must not
    /// evict Wine Stable, which is a different build kept for a different reason. The version
    /// is in the id; the family is what the ids of one lineage share.
    ///
    /// `nil` means the build is its own family: never pruned, and never prunes anything. That
    /// is the safe answer for an entry added without anyone thinking about lineage, which is
    /// how most of them will be added.
    var family: String?

    /// ``family``, or the id when it has none.
    var resolvedFamily: String { family ?? id }

    /// Whether this Wine exposes `winemac.drv`'s Metal escape interface, which is what DXMT
    /// needs to provide Direct3D 11 on Metal.
    ///
    /// Declared rather than derived, because nothing about a build's version says it. It also
    /// cannot be detected before installing — ``Wine/DXMT/isShippedByRuntime(_:)`` inspects
    /// files inside an installed runtime — and provisioning has to know *before* downloading
    /// which build could serve a Direct3D 11 game.
    ///
    /// Getting it wrong in the optimistic direction is the worst failure mode this whole
    /// feature has: DXMT on a Wine without the escapes half-works, device creation succeeds,
    /// everything looks right, and every swap chain fails with `EGL_BAD_ALLOC`. So it
    /// defaults to false and is set only for builds known to have them.
    var exposesMetalEscapes: Bool = false

    /// Whether this build was configured with a real i386 architecture, rather than relying on
    /// CrossOver's 32-on-64.
    ///
    /// A claim about how the build was configured — `--enable-archs=i386,x86_64` — and it has
    /// to be set by hand for that reason: nothing about a tarball says it. See
    /// ``RuntimeProfile/Requirements/nativeThirtyTwoBit`` for why a game would need it.
    var hasNativeThirtyTwoBit: Bool = false

    /// A second archive carrying the Unix libraries the engine links against, if it doesn't
    /// carry its own.
    ///
    /// Wineskin-style engines are built to sit inside a wrapper application that supplies
    /// these, so on their own they don't start at all — and they fail in a way that names
    /// neither the engine nor the wrapper:
    ///
    ///     dyld: Library not loaded: @rpath/libinotify.0.dylib
    ///       Referenced from: .../bin/wineserver
    ///       Reason: no LC_RPATH's found
    ///
    /// Mythic fetches the wrapper too and keeps its `Frameworks` directory beside the engine,
    /// pinned by its own digest like everything else here.
    var supportLibraries: SupportLibraries?

    struct SupportLibraries: Hashable {
        let downloadURL: URL
        let sha256: String

        /// Path within the extracted archive to the directory of dylibs.
        let payloadSubpath: String
    }
}

extension RuntimeRelease {
    /// Runtimes Mythic can install on request.
    ///
    /// The catalogue is ordered by preference, best first — where "best" means the one a
    /// new container should default to, so a runtime that can't boot one doesn't lead the
    /// list however good its graphics story is.
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
    /// The catalogue in force, which is the compiled-in list until a manifest replaces it.
    ///
    /// `nonisolated(unsafe)` for the same reason `Runtime`'s discovery cache is: written once
    /// early, read from wherever a game is about to launch. See ``CompatibilityManifest`` for
    /// what a fetched manifest is and isn't allowed to change about this — in short, it can
    /// add runtimes and reword these, but it cannot re-point an id that shipped in the app at
    /// different bytes.
    nonisolated(unsafe) static var catalogue: [RuntimeRelease] = compiledIn

    /// What shipped in this build, and the floor a manifest is merged onto.
    ///
    /// Also the offline answer: the whole catalogue being fetched would mean a first launch
    /// with no network had no runtimes at all to offer.
    ///
    /// Built in DEBUG-only additions first, because catalogue order is preference order.
    static let compiledIn: [RuntimeRelease] = unreleased + shipped

    /// Runtimes built locally that have no published release yet.
    ///
    /// Empty in a release build, on purpose: their `downloadURL` points at a tag that does
    /// not exist, and a runtime whose download 404s reads as the app being broken rather
    /// than as a tarball being unpublished. Each one moves into
    /// `Compatibility/manifest.json` — and out of here — once its release is cut.
    private static var unreleased: [RuntimeRelease] {
#if DEBUG
        [
        .init(
            id: "wine-dxmt-11.16",
            name: "Wine 11.16 (DXMT)",
            version: .init(11, 16, 0),
            downloadURL: .init(string: "https://github.com/mcstig/PorTalistic/releases/download/wine-dxmt-11.16/wine-dxmt-11.16.tar.xz")!,
            sha256: "55248a10f9771bb5d73e7fcaac3d52ca40414cb8601c4bb9bc330fbb2e81c54b",
            payloadSubpath: "wine-dxmt-11.16",
            executableSubpath: "bin/wine",
            summary: """
                Wine 11.16 from winehq source with CodeWeavers' winemac.drv patch, so a \
                Direct3D 11 swap chain has a CAMetalLayer to present into. Built rather than \
                downloaded because no published build has both that and a prefix that boots \
                here. Compiled without gnutls, so Windows code running inside the \
                installation gets no TLS — which games do not use, because the store client \
                and the launcher both live outside it.
                """,
            family: "wine-dxmt",
            exposesMetalEscapes: true,
            // `--enable-archs=i386,x86_64` in `Compatibility/build-dxmt-wine.sh`: a real
            // i386 architecture rather than 32-on-64. The only build here with one.
            hasNativeThirtyTwoBit: true
        )
        ]
#else
        []
#endif
    }

    private static let shipped: [RuntimeRelease] = [
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
                """,
            family: "wine-stable"
        ),
        .init(
            id: "wine-sikarugir-11.0",
            name: "Sikarugir Wine 11.0",
            version: .init(11, 0, 0),
            downloadURL: .init(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS11WineSikarugir11.0.tar.xz")!,
            sha256: "d12fa09149b9afd3be349d726eecea6b2216ac574c91f93f56d872bb6ca7b795",
            payloadSubpath: "wswine.bundle",
            executableSubpath: "bin/wine",
            summary: """
                Wine 11 built for DXMT, so it has both modern Wine and Direct3D 11 on Metal — \
                the combination nothing else here has. Installs and reports its version, but \
                on some Macs cannot create a container at all: every Windows process it starts \
                is killed by macOS the moment Wine hands control to Windows code. Try it, and \
                keep Wine Stable if it can't boot.
                """,
            family: "wine-sikarugir",
            exposesMetalEscapes: true,
            supportLibraries: .init(
                downloadURL: .init(string: "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.14.tar.xz")!,
                sha256: "f35b11837c79ca5ca23a0190784b44a5dd40deacf59bae4366e6032dcd4998fa",
                payloadSubpath: "Template-1.0.14.app/Contents/Frameworks"
            )
        ),
    ]

    /// The catalogue entry matching an installed runtime, if it came from here.
    static func matching(_ runtime: Runtime) -> RuntimeRelease? {
        catalogue.first { $0.id == runtime.id.replacingOccurrences(of: "managed:", with: "") }
    }
}
