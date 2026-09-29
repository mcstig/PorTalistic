//
//  CompatibilityDatabase.swift
//  Mythic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 What is known about specific games, beyond what their binaries admit.

 Reading an executable answers "32-bit Direct3D 9" well and answers "this one's networking
 falls over on Wine 7.7" not at all. That second kind of fact only ever comes from running the
 game, so it has to be written down somewhere — which is what this is.

 Three rules about what goes in here, all learned the hard way:

 - **Only what has been observed.** A guessed entry is worse than no entry, because an absent
   entry falls back to inspection — which is usually right — while a wrong entry overrides it.
 - **Say why.** "Retina Mode off" is meaningless in six months. "Off, because on it renders a
   quarter of the screen" is still actionable, and is what the game's settings can show.
 - **Never disarm an entry on a guess about the future.** Blades of Time's entry described a
   stack overflow caused by Retina Mode being off, and then set nothing — it had been emptied
   out on the reasoning that the game "runs on DXMT now", which a 32-bit game never can,
   because DXMT and D3DMetal are both 64-bit only. The note was left as the only thing
   standing between the game and the crash it described, and a note is not a fix. When the
   global default for Retina Mode later went off, the crash came straight back. If a fault has
   been observed, the entry states the setting that avoids it; if the setting has genuinely
   stopped being needed, the entry goes, and so does the note.

 - Note: The intent is for this to be fetched from the public repository and verified by
   digest, so a game can be fixed for everyone without shipping an app update. The compiled-in
   seed below is then the offline fallback. Until that lands, the seed *is* the database.
 */
struct CompatibilityDatabase: Codable, Hashable {
    static let log: Logger = .custom(category: "CompatibilityDatabase")

    var entries: [Entry]

    struct Entry: Codable, Hashable {
        /// Storefront-qualified game ids this applies to. Exact, and the preferred way in.
        var identifiers: [Identifier] = []

        /// Titles this applies to, for the same game on a storefront whose id we don't have.
        /// Matched after normalisation, so punctuation and trademark symbols don't matter.
        var titles: [String] = []

        /// Override the translation layer the binary implies.
        var graphicsBackend: RuntimeProfile.GraphicsBackend?

        /// The game needs a Wine with a working socket layer, which the bundled 7.7 engine
        /// does not have. Not inferable from the executable — every game imports `ws2_32` —
        /// so it can only be recorded here.
        var requiresModernNetworking: Bool?

        /// The game cannot survive CrossOver's 32-on-64 and needs a Wine with a real i386
        /// architecture. Only ever observable by running it — see
        /// ``RuntimeProfile/Requirements/nativeThirtyTwoBit``.
        var requiresNativeThirtyTwoBit: Bool?

        var settings: RuntimeProfile.SettingsOverride = .init()

        /// Winetricks verbs this game's prefix needs — `d3dcompiler_47`, `vcrun2019` and so
        /// on. Installed once per container, before the game is started.
        var winetricks: [String] = []

        /// Why this entry exists, shown to the user as the reason for the choice.
        var note: String?

        /// This entry with `other` laid over it, `other` winning wherever both have an opinion.
        ///
        /// Exists for one job: putting what the app *learned* for a game underneath what a
        /// curated entry says about it. Somebody who read the logs outranks a fix found by
        /// trying configurations, on every field they both speak to — and the learned entry
        /// keeps the fields the curated one is silent on, so a partial curated answer doesn't
        /// throw away a local fix that went further.
        ///
        /// Identifiers and titles come from `other` when it has any, because they are how the
        /// entry is matched and the curated spelling is the canonical one.
        func overlaid(with other: Entry) -> Entry {
            .init(identifiers: other.identifiers.isEmpty ? identifiers : other.identifiers,
                  titles: other.titles.isEmpty ? titles : other.titles,
                  graphicsBackend: other.graphicsBackend ?? graphicsBackend,
                  requiresModernNetworking: other.requiresModernNetworking ?? requiresModernNetworking,
                  requiresNativeThirtyTwoBit: other.requiresNativeThirtyTwoBit ?? requiresNativeThirtyTwoBit,
                  settings: settings.overlaid(with: other.settings),
                  winetricks: winetricks + other.winetricks.filter { !winetricks.contains($0) },
                  note: [note, other.note].compactMap { $0 }.joined(separator: "\n\n"))
        }

        struct Identifier: Codable, Hashable {
            let storefront: Game.Storefront
            let id: String
        }
    }

    // MARK: - Lookup

    /// The entry for a game, by id first and title second.
    ///
    /// Takes plain values rather than a `Game` so it can be called from wherever the work is
    /// happening: `Game` is a main-actor-bound reference type, and profile resolution reads
    /// executables off disk, which has no business on the main actor.
    func entry(storefront: Game.Storefront?, id: String, title: String) -> Entry? {
        if let storefront, let byIdentifier = entries.first(where: { entry in
            entry.identifiers.contains { $0.storefront == storefront && $0.id == id }
        }) {
            return byIdentifier
        }

        let normalised = Self.normalise(title)
        guard !normalised.isEmpty else { return nil }

        return entries.first { entry in
            entry.titles.contains { Self.normalise($0) == normalised }
        }
    }

    @MainActor
    func entry(for game: Game) -> Entry? {
        entry(storefront: game.storefront, id: game.id, title: game.title)
    }

    /// Titles arrive decorated differently from every storefront — "Fallout New Vegas®",
    /// "Sid Meier's Civilization® VI", "PREY" — so matching is on letters and digits only.
    static func normalise(_ title: String) -> String {
        title.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    // MARK: - Contents

    /// The database in force.
    ///
    /// A stored property rather than a computed one so a fetched database can replace it, and
    /// `nonisolated(unsafe)` for the same reason the runtime discovery cache is: written once
    /// during provisioning, read from wherever a game is about to launch.
    nonisolated(unsafe) static var current: CompatibilityDatabase = .seed

    /// What has actually been observed on a real machine, with the observation attached.
    ///
    /// Short on purpose. Every line here is something a game did, not something a game is
    /// expected to do.
    static let seed: CompatibilityDatabase = .init(entries: [
        .init(
            identifiers: [.init(storefront: .gog, id: "1158493447")],
            titles: ["Prey"],
            settings: .init(retinaMode: false),
            note: """
                Retina Mode off: with it on, Prey's 2048×1330 fullscreen is rendered into a \
                quarter of a 4096×2660 desktop and every display gets captured.
                """
        ),
        .init(
            identifiers: [.init(storefront: .epicGames, id: "bc2c95c6ff564a16b26644f1d3ac3c55")],
            titles: ["BioShock Remastered"],
            requiresNativeThirtyTwoBit: true,
            settings: .init(dllOverrides: ["atiadlxx": "d",
                                           "d3dcompiler_43": "n,b",
                                           "d3dcompiler_47": "n,b"]),
            winetricks: ["d3dcompiler_43", "d3dcompiler_47"],
            note: """
                AMD's Display Library disabled. The game asks Wine's `atiadlxx` for the
                graphics adapter, and Wine's copy is a stub: `ADL_Main_Control_Create`
                succeeds without producing a context, `ADL_Adapter_NumberOfAdapters_Get` is
                then called with `ptr 00000000`, and the game reads through the null it was
                handed — `wine: Unhandled page fault on read access to 00000050 at address
                028A415A`. The logo appears and the process is gone.

                Disabled rather than fixed, because the two are different: a DLL that fails to
                load sends a game down its "no such hardware" path, which is the truth on a
                Mac, while a stub that succeeds and returns nothing sends it into a fault.

                Native `d3dcompiler_47` as well, which is what the winetricks verb is for.
                Past the adapter query the game compiles its shaders at runtime and Wine's
                own HLSL compiler cannot: `fixme:write_sm4_block Unhandled instruction type
                HLSL_IR_JUMP` for every shader with a loop or a branch in it, then `wine:
                Unhandled page fault on execute access to FFFFFE9B at address FFFFFE9B` on
                the shader thread — a jump into whatever the failed compile left behind. Two
                disclaimers in, which is where the first frame would have been.

                The override on its own does nothing, and that is the trap: `n` with no
                native file in the prefix falls straight through to the builtin that cannot
                compile them. The verb is what puts Microsoft's compiler there.

                It is **43** that this game imports, not 47 — `BioshockHD.exe` names
                `D3DCOMPILER_43.dll` in its import table, which is why overriding only 47 did
                nothing and Wine's builtin 43 went on compiling the shaders.

                And `n,b`, never a bare `n`. `n` means native *only*: with the verb's
                download having failed, it resolved to nothing and the game would not start at
                all — `err:module:import_dll Library D3DCOMPILER_43.dll not found`, status
                `c0000135`. `n,b` is native if a real file is there and Wine's builtin
                otherwise, so a failed verb costs the fix rather than the game.
                """
        ),
        .init(
            identifiers: [.init(storefront: .gog, id: "1164193173")],
            titles: ["Blades of Time"],
            requiresNativeThirtyTwoBit: true,
            settings: .init(retinaMode: false),
            note: """
                Needs a Wine with a real i386 architecture, which on this catalogue means \
                the DXMT build — it would use wined3d there, DXMT itself being 64-bit only. \
                The bundled engine is CrossOver-derived and therefore 32-on-64, where every \
                Win32 call reaches the 64-bit side through a thunk and the frames come out \
                deeper than this game was built for.

                On the bundled engine, pressing Escape through the opening cinematic exhausts \
                the main thread's stack: `err:seh:call_stack_handlers invalid frame \
                000000000012EDF0 (0000000000132000-000000000022FD20)` — an exception frame \
                twelve kilobytes below the bottom of a 1MB stack — then `NtRaiseException \
                Exception frame is not in stack limits`, which is Wine unable to dispatch the \
                guard-page fault because there is no stack left to build a handler on.

                Measured, and two fixes were wrong before this one. Turning the command-stream \
                thread off gave a byte-identical crash, with `csmt` confirmed at 0 in both the \
                registry and the log, so CSMT is not involved. No display mode change appears \
                in the log either, so it is not the missing-video-mode failure Bloodstained \
                hits.

                Retina Mode on also avoids the crash, by keeping the game off its fullscreen \
                path altogether, and was this entry's answer twice. It is not one any more: \
                Retina Mode has Wine put the display into its backing mode, which takes the \
                display, and taking one takes them all — every other monitor goes black for as \
                long as the game runs. `CaptureDisplaysForFullscreen` is not what does that; \
                it was `n` throughout. Avoiding a crash by blacking out somebody's second \
                screen is a worse answer than fixing the crash.
                """
        )
    ])
}
