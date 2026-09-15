//
//  RuntimeProfile.swift
//  Mythic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 What a game should be launched with, and why.

 Runtimes are not better and worse versions of each other — they fail in different
 directions, and which one a game wants depends on the game. This turns the facts in
 ``WindowsExecutable`` into a decision, so nobody has to open a menu to make it.

 Expressed as *capabilities a runtime must have* rather than a runtime by name. The same
 profile then resolves against whatever is installed or installable, which is what lets
 provisioning fetch only what the library actually needs, and lets a better runtime arriving
 later improve an existing game without the profile having to change.
 */
struct RuntimeProfile: Codable, Hashable {
    /// What a runtime has to be able to do for this game.
    var requirements: Requirements

    /// The translation layer that should be in the container, or `nil` for "whatever the
    /// runtime already provides" — which is the honest answer when nothing could be learned
    /// about how the game renders.
    var graphicsBackend: GraphicsBackend?

    /// Container settings this game wants, overlaid at launch over whatever the container
    /// has. Every field optional: a profile states only what it has an opinion about.
    var settings: SettingsOverride

    /// Where the decision came from, most authoritative first.
    var source: Source

    /// Why, in plain words, one line per reason.
    ///
    /// The backlog's rule for this feature is "automatic, but not silent": a game's settings
    /// should be able to say which runtime was chosen and what for. A verdict that can't
    /// explain itself is indistinguishable from a bug when a game doesn't start.
    var reasons: [String]

    // MARK: - Requirements

    struct Requirements: Codable, Hashable {
        /// Direct3D 10 or newer, which on macOS means Apple's D3DMetal or DXMT. Nothing else
        /// here renders it: wined3d tops out below it and DXVK needs Vulkan.
        var direct3DOnMetal: Bool = false

        /// The game is 32-bit, so the runtime needs a working 32-on-64 path. Also rules out
        /// D3DMetal and DXMT, both of which are 64-bit only.
        var thirtyTwoBit: Bool = false

        /// Wine new enough to have a working socket layer. The bundled engine is Wine 7.7 and
        /// anything network-heavy trips over it constantly.
        var modernNetworking: Bool = false

        /// Native Vulkan, which no runtime here provides. Recorded so the profile can say so
        /// rather than quietly choosing something that won't work.
        var nativeVulkan: Bool = false
    }

    enum GraphicsBackend: String, Codable, Hashable {
        /// Apple's Direct3D-on-Metal, as shipped in the Game Porting Toolkit derived engine.
        ///
        /// Not something Mythic can provide: Apple's Game Porting Toolkit licence restricts
        /// distribution of its proprietary components to non-commercial purposes. Named here
        /// because a machine that already has the engine can still use it, and because a
        /// curated entry may want to ask for it.
        case direct3DMetal
        /// DXMT — Direct3D 11 on Metal, on a Wine that exposes `winemac.drv`'s Metal escapes.
        /// Open source, and therefore what Mythic actually ships for Direct3D 10 and newer.
        case dxmt
        /// DXVK — Direct3D 10/11 on Vulkan. No Direct3D 9 implementation, which is why it is
        /// never the answer for an older game.
        case dxvk
        /// Wine's own Direct3D, on OpenGL. The only path for Direct3D 9, and the floor when
        /// nothing better applies.
        case wined3d

        var description: String {
            switch self {
            case .direct3DMetal:    "D3DMetal"
            case .dxmt:             "DXMT"
            case .dxvk:             "DXVK"
            case .wined3d:          "wined3d"
            }
        }
    }

    enum Source: String, Codable, Hashable {
        /// The user chose this by hand. Never overridden by anything below.
        case userOverride
        /// A curated entry for this specific game.
        case database
        /// Derived from reading the game's executable.
        case inspection
        /// Nothing was known, so the defaults apply.
        case fallback

        var isAutomatic: Bool { self != .userOverride }
    }

    // MARK: - Settings

    /// A sparse overlay on ``Wine/Container/Settings``.
    ///
    /// Per-game rather than per-container because the right value is per-game and always was:
    /// Prey wants Retina Mode off, where on it renders a quarter of a 4096×2660 desktop;
    /// Blades of Time wanted it on, and started crashing with it off. Same container, same
    /// setting, opposite answers, an hour apart.
    struct SettingsOverride: Codable, Hashable, Sendable {
        var dxvk: Bool?
        var dxvkAsync: Bool?
        var retinaMode: Bool?
        var commandStreamThread: Bool?
        var msync: Bool?
        var metalHUD: Bool?
        var avx2: Bool?
        var windowsVersion: Wine.WindowsVersion?

        var isEmpty: Bool {
            self == .init()
        }

        /// This overlay on top of another, with the other winning where both have an opinion.
        /// Used to let a database entry refine an inspected profile without restating it.
        func overlaid(with other: SettingsOverride) -> SettingsOverride {
            .init(dxvk: other.dxvk ?? dxvk,
                  dxvkAsync: other.dxvkAsync ?? dxvkAsync,
                  retinaMode: other.retinaMode ?? retinaMode,
                  commandStreamThread: other.commandStreamThread ?? commandStreamThread,
                  msync: other.msync ?? msync,
                  metalHUD: other.metalHUD ?? metalHUD,
                  avx2: other.avx2 ?? avx2,
                  windowsVersion: other.windowsVersion ?? windowsVersion)
        }
    }
}

// MARK: - Resolution

extension RuntimeProfile {
    static let log: Logger = .custom(category: "RuntimeProfile")

    /// The profile for a game, from the strongest evidence available.
    ///
    /// Layered rather than exclusive: the executable decides the shape of the answer, and a
    /// curated entry refines it. That ordering matters — a database entry saying "this one
    /// needs working sockets" should not also have to restate that the game is 64-bit
    /// Direct3D 11, and would go stale if it did.
    static func resolve(executable: WindowsExecutable?,
                        databaseEntry: CompatibilityDatabase.Entry? = nil,
                        userOverride: SettingsOverride? = nil) -> RuntimeProfile {
        var profile = executable.map(inferred(from:)) ?? .unknownGame

        if let entry = databaseEntry {
            profile = profile.refined(by: entry)
        }

        if let userOverride, !userOverride.isEmpty {
            profile.settings = profile.settings.overlaid(with: userOverride)
            profile.source = .userOverride
            profile.reasons.append("You set some of these by hand.")
        }

        return profile
    }

    /// What the binary alone implies.
    ///
    /// Every reason here has to be true of *this* binary. An earlier version formed the
    /// Direct3D test as `(version ?? 0) <= 9`, which made "it renders with Direct3D 9" the
    /// verdict for every binary that renders with no Direct3D at all — including two Steam
    /// executables that use OpenGL and nothing. A wrong explanation is worse than none: it
    /// is the thing the user reads when a game won't start.
    private static func inferred(from executable: WindowsExecutable) -> RuntimeProfile {
        var requirements: Requirements = .init()
        var settings: SettingsOverride = .init()
        var reasons: [String] = .init()

        let direct3D: Int? = executable.highestDirect3DVersion
        let usesOpenGL: Bool = executable.graphicsAPIs.contains(.openGL)
        let usesVulkan: Bool = executable.graphicsAPIs.contains(.vulkan)

        // DXGI is shared by Direct3D 10 onwards, so touching it is a floor even when no
        // version number was found: whatever else this binary is, it isn't Direct3D 9-only.
        let needsMetalTranslation: Bool = (direct3D ?? 0) >= 10 || executable.usesDXGI
        let rendererIsUnknown: Bool = direct3D == nil && !usesOpenGL && !usesVulkan && !executable.usesDXGI

        let backend: GraphicsBackend? = {
            guard executable.architecture == .x86_64 else { return .wined3d }
            if needsMetalTranslation { return .dxmt }
            // A renderer we did identify, and it isn't one Metal translation serves.
            if direct3D != nil || usesOpenGL || usesVulkan { return .wined3d }
            // Nothing identified. Naming a backend here would be a guess dressed up as a
            // decision; whatever the runtime already provides is the truthful answer.
            return nil
        }()

        // DXVK and D3DMetal both claim `dxgi` and `d3d11`, so a container can't have both,
        // and DXVK has no Direct3D 9 to offer the older games. Inspection alone therefore
        // never chooses it — only a curated entry does.
        settings.dxvk = false

        // Retina Mode off unless something knows better.
        //
        // On, Wine hands the game a desktop at the display's full backing resolution, and a
        // game that does not ask for that renders its own picture into one corner of it —
        // which is exactly what Prey did, at 2048×1330 inside a 4096×2660 desktop, with
        // every attached display captured and blanked. Most games do not ask.
        //
        // A curated entry still wins: Blades of Time crashes with it off, and that is what
        // the database is for. So does the user, if they set it by hand.
        // Stated in the settings panel rather than in `reasons`: a line here would be
        // repeated for every game in the library, and would contradict itself whenever a
        // curated entry turned it back on two lines later.
        settings.retinaMode = false

        switch executable.architecture {
        case .arm64:
            // Named rather than guessed about. No runtime in the catalogue runs a native
            // ARM64 Windows binary, and saying so beats sending it somewhere that will fail.
            reasons.append("This is a native ARM64 Windows program. No runtime PorTalistic can install runs one, so it isn't expected to start.")

        case .i386:
            requirements.thirtyTwoBit = true

            if needsMetalTranslation {
                reasons.append("It asks for Direct3D 10 or newer at 32-bit, which nothing here translates — Apple's D3DMetal and DXMT are both 64-bit only. Expect it to run badly or not at all.")
            } else if let version = direct3D {
                reasons.append("32-bit Direct3D \(version). The two ways of getting Direct3D onto Metal are 64-bit only and DXVK has no Direct3D 9, so Wine's own Direct3D on OpenGL is the only path that draws anything.")
            } else {
                reasons.append("32-bit, so it runs through Wine's 32-on-64 support.")
            }

        case .x86_64:
            if needsMetalTranslation {
                requirements.direct3DOnMetal = true
                let named: String = direct3D.map { "Direct3D \($0)" } ?? "Direct3D 10 or newer"
                reasons.append("64-bit \(named), which has to be translated to Metal. PorTalistic uses DXMT for that, on a Wine build exposing the Metal interface DXMT needs.")
            } else if let version = direct3D {
                reasons.append("64-bit Direct3D \(version). DXVK has no Direct3D 9, so this goes through Wine's own Direct3D.")
            }
        }

        if usesOpenGL, !needsMetalTranslation, direct3D == nil {
            reasons.append("It renders with OpenGL, which Wine passes through to the system.")
        }

        if usesVulkan, !needsMetalTranslation, direct3D == nil {
            // Vulkan with no Direct3D anywhere is a native Vulkan renderer, and nothing here
            // provides Vulkan on macOS. Flagged rather than silently mis-served.
            requirements.nativeVulkan = true
            reasons.append("It renders with Vulkan directly, which no runtime here provides. It isn't expected to start.")
        }

        if rendererIsUnknown {
            reasons.append(executable.referenceScanWasTruncated
                           ? "Nothing in the part of the executable PorTalistic read says how it renders — the file was too large to read all of it — so it gets the setup that suits most games."
                           : "Nothing in the executable says how it renders, so it gets the setup that suits most games.")
        }

        return .init(requirements: requirements,
                     graphicsBackend: backend,
                     settings: settings,
                     source: .inspection,
                     reasons: reasons)
    }

    /// Used when the executable couldn't be read at all — a game not yet installed, an
    /// unreadable file, a macOS build that has no PE binary to inspect.
    ///
    /// Deliberately the same answer most games want, not a refusal. A game Mythic knows
    /// nothing about still has to launch, and the bundled engine with D3DMetal is the
    /// likeliest thing to work.
    static let unknownGame: RuntimeProfile = .init(
        requirements: .init(),
        graphicsBackend: nil,
        // Retina Mode off even here. It is the default for every game for the reason given
        // in `inferred(from:)`, and a game nothing is known about is the last one that
        // should be handed a full-resolution desktop it never asked for.
        settings: .init(retinaMode: false),
        source: .fallback,
        reasons: ["PorTalistic hasn't read this game's files yet, so it gets the defaults."]
    )

    /// This profile with a curated entry's opinions applied over it.
    private func refined(by entry: CompatibilityDatabase.Entry) -> RuntimeProfile {
        var refined = self
        refined.source = .database

        if let backend = entry.graphicsBackend {
            refined.graphicsBackend = backend
        }

        if entry.requiresModernNetworking == true {
            refined.requirements.modernNetworking = true
        }

        refined.settings = refined.settings.overlaid(with: entry.settings)

        if let note = entry.note {
            refined.reasons.append(note)
        } else {
            refined.reasons.append("PorTalistic's compatibility list has an entry for this game.")
        }

        return refined
    }
}
