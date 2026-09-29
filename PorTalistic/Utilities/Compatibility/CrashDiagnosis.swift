//
//  CrashDiagnosis.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 Reading a launch transcript and saying what went wrong.

 Every fault in this file was diagnosed by hand first, over an evening, one game at a time:
 BioShock Remastered's AMD stub and its shader compiler, Blades of Time's exhausted stack,
 Prey's captured displays, a stale `wineserver` that killed every later launch in a prefix.
 Each one took a session of reading logs and guessing. The transcript said it plainly in every
 case — it just needed somebody to read it.

 So this reads it. The knowledge is the asset, not the code around it: a signature is a name,
 the lines that identify it, and the change that fixed it, and adding one is adding a case to
 `signatures` and a fixture to the tests.

 # Why the log and not the exit status

 A Windows unhandled exception leaves Wine exiting with the NTSTATUS — `0xc0000005` for an
 access violation, `0xc0000135` for a missing DLL. POSIX truncates a wait status to eight
 bits, so `0xc0000005` reaches us as `5` and is indistinguishable from a game that chose to
 exit with 5. The status is worth recording and worth nothing as a signal. The transcript is
 the signal.

 # What this is not

 Not a guess. A signature matches or it does not, and an unmatched crash is reported as
 unmatched rather than fitted to the nearest thing — `RecoveryLadder` is what handles those,
 and it is deliberately a separate idea. Confidence here comes from the patterns being quotes
 from real logs, so the cost of being wrong is a recognised fault that doesn't fire, not a
 working game reconfigured on a hunch.
 */
enum CrashDiagnosis {
    static let log: Logger = .custom(category: "CrashDiagnosis")

    // MARK: - What a diagnosis is

    /// A recognised fault, and what to do about it.
    struct Finding: Equatable {
        /// Stable across versions: it is the key in the journal, the dedup key in a report, and
        /// what a fix gets attributed to. Renaming one loses that history.
        let signature: String

        /// One line, for the person. Written to be read by somebody who did not ask for a
        /// diagnosis and just wants to know why their game closed.
        let summary: String

        /// The lines that matched, for the report. Bounded by the caller.
        var evidence: [String] = []

        /// `nil` when the fault is recognised but nothing can be changed automatically.
        var remedy: Remedy?
    }

    /// A change that made this fault go away, in the shape a compatibility entry is written in.
    ///
    /// Deliberately the same fields as `CompatibilityDatabase.Entry`, because a remedy that
    /// works is exactly a curated entry — and the whole point of the loop is that a fix found
    /// on one machine becomes an entry everybody gets.
    struct Remedy: Equatable {
        /// What changes, in the person's words: "disable AMD's Display Library".
        let describedAs: String

        var settings: RuntimeProfile.SettingsOverride = .init()
        var winetricks: [String] = []
        var requiresNativeThirtyTwoBit: Bool?
        var graphicsBackend: RuntimeProfile.GraphicsBackend?

        /// Something to do rather than something to set.
        var sideEffect: SideEffect?

        /// Whether applying this needs a different Wine build, and therefore possibly a
        /// download and a fresh prefix.
        var changesRuntime: Bool {
            requiresNativeThirtyTwoBit == true || graphicsBackend != nil
        }
    }

    enum SideEffect: String, Equatable {
        /// Kill the prefix's `wineserver` before the next launch. Not a setting: the
        /// configuration is already right and a process is holding the old one.
        case killWineserver
    }

    // MARK: - Detection

    /// Lines that mean a Windows process died rather than exited.
    ///
    /// Kept tight on purpose. Wine's logs are full of `err:` and `fixme:` at every launch,
    /// including launches of games that run perfectly, so a generous list here would classify
    /// every session as a crash and the whole feature would start reconfiguring working games.
    /// These five are the ones that only ever appear when something actually went wrong.
    static let crashMarkers: [String] = [
        #"Unhandled page fault"#,
        #"Unhandled exception"#,
        #"err:seh:"#,
        #"NtRaiseException"#,
        #"err:module:import_dll Library \S+ not found"#
    ]

    /// Whether this transcript shows a crash, and the lines that say so.
    static func faultLines(in transcript: String) -> [String] {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)

        return lines.filter { line in
            crashMarkers.contains { marker in
                line.range(of: marker, options: [.regularExpression, .caseInsensitive]) != nil
            }
        }.map(String.init)
    }

    // MARK: - Diagnosis

    /**
     What went wrong, if this is a fault we know.

     - Parameters:
       - transcript: the launch log's text.
       - applied: the settings the crashed launch actually ran with. Some faults are only
         recognisable against them — a missing DLL is a different fault when the app is the one
         that asked for a native-only override.
     */
    static func diagnose(transcript: String,
                         applied: RuntimeProfile.SettingsOverride = .init()) -> Finding? {
        // Ordered: the first match wins, and the specific ones come before the general ones.
        // `nativeOnlyOverride` in particular has to be asked before `missingImportedDLL`,
        // because the transcript looks identical and only one of them is our own fault.
        let candidates: [(String) -> Finding?] = [
            { nativeOnlyOverride(in: $0, applied: applied) },
            missingImportedDLL,
            matchFromSignatures
        ]

        for candidate in candidates {
            if let finding = candidate(transcript) {
                log.notice("Diagnosed \(finding.signature, privacy: .public)")
                return finding
            }
        }

        return nil
    }

    // MARK: - The catalogue

    /// A fault identified by lines appearing together.
    struct Signature {
        let id: String
        let summary: String
        /// Every one of these must appear somewhere in the transcript.
        let requiring: [String]
        /// None of these may appear. Used to keep a general fault from claiming a specific one.
        var excluding: [String] = []
        var remedy: Remedy?
    }

    static let signatures: [Signature] = [
        .init(
            id: "atiadlxx-stub-returns-null",
            summary: String(localized: "The game asked Wine for an AMD graphics adapter and read through the empty answer it got."),
            requiring: [#"atiadlxx"#, #"page fault on read access"#],
            remedy: .init(
                describedAs: String(localized: "Disable AMD's Display Library, so the game takes its \u{201C}no such hardware\u{201D} path"),
                settings: .init(dllOverrides: ["atiadlxx": "d"])
            )
        ),

        .init(
            id: "builtin-hlsl-compiler-cannot-branch",
            summary: String(localized: "Wine's own shader compiler can't compile this game's shaders, and the game ran into what the failed compile left behind."),
            requiring: [#"HLSL_IR_JUMP"#],
            remedy: .init(
                describedAs: String(localized: "Install Microsoft's shader compiler into the container and use it instead of Wine's"),
                settings: .init(dllOverrides: ["d3dcompiler_43": "n,b", "d3dcompiler_47": "n,b"]),
                winetricks: ["d3dcompiler_43", "d3dcompiler_47"]
            )
        ),

        .init(
            id: "exception-frame-outside-stack",
            summary: String(localized: "The game ran out of stack. Its 32-bit code is reaching the 64-bit side through a thunk, which makes every call deeper than the game was built for."),
            requiring: [#"(invalid frame|Exception frame is not in stack limits)"#],
            remedy: .init(
                describedAs: String(localized: "Move the game to a Wine built with a real 32-bit architecture"),
                requiresNativeThirtyTwoBit: true
            )
        ),

        .init(
            id: "vulkan-mapping-above-four-gigabytes",
            summary: String(localized: "The graphics driver handed this 32-bit game memory at an address a 32-bit pointer can't reach."),
            requiring: [#"(VK_ERROR_OUT_OF_DEVICE_MEMORY|address above 4G|mapping above 4)"#],
            remedy: .init(
                describedAs: String(localized: "Move the game to a Wine built with a real 32-bit architecture"),
                requiresNativeThirtyTwoBit: true
            )
        ),

        // Apple's implementation rather than Vulkan, which this used to ask for. DXMT is
        // failing here because the Wine build underneath it has no Metal escape interface, and
        // the build that ships DXMT has no Vulkan either — so "render through Vulkan" named the
        // one implementation nothing on this Mac can provide. It also changed nothing at all
        // for a while: a remedy's backend reached the profile and the badge and never the
        // runtime the game was given, and a signature is recorded as acted on and never tried
        // again, so the one attempt that mattered was spent reporting a change nobody made.
        .init(
            id: "metal-escapes-missing",
            summary: String(localized: "The Direct3D-on-Metal layer couldn't get a surface to draw into from this Wine build."),
            requiring: [#"(EGL_BAD_ALLOC|failed to create.*swapchain|no metal escape)"#],
            remedy: .init(
                describedAs: String(localized: "Run the game through Apple's Direct3D translation instead, which doesn't need those entry points"),
                graphicsBackend: .direct3DMetal
            )
        ),

        .init(
            id: "fullscreen-mode-not-on-this-display",
            summary: String(localized: "The game asked for a fullscreen resolution this display doesn't have."),
            requiring: [#"(DISP_CHANGE_BADMODE|ChangeDisplaySettingsEx.*-2\b)"#],
            remedy: .init(
                describedAs: String(localized: "Let Wine take the display for fullscreen, so it can present the mode the game asked for"),
                settings: .init(captureDisplaysForFullscreen: true)
            )
        ),

        .init(
            id: "stale-wineserver-without-msync",
            summary: String(localized: "A leftover Wine server is holding this container, and it was started without the synchronisation this launch needs."),
            requiring: [#"msync_init Failed to open msync shared memory file"#],
            remedy: .init(
                describedAs: String(localized: "Stop the leftover Wine server before the next launch"),
                sideEffect: .killWineserver
            )
        ),

        .init(
            id: "wine-mono-prompt",
            summary: String(localized: "Wine stopped to ask about installing Mono and nothing could answer it."),
            requiring: [#"Wine Mono"#],
            remedy: .init(
                describedAs: String(localized: "Keep .NET support switched off in this container, so nothing asks"),
                settings: .init()
            )
        )
    ]

    private static func matchFromSignatures(in transcript: String) -> Finding? {
        for signature in signatures {
            let matched = signature.requiring.allSatisfy { pattern in
                transcript.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }

            guard matched else { continue }

            let excluded = signature.excluding.contains { pattern in
                transcript.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }

            guard !excluded else { continue }

            return .init(signature: signature.id,
                         summary: signature.summary,
                         evidence: lines(in: transcript, matching: signature.requiring),
                         remedy: signature.remedy)
        }

        return nil
    }

    // MARK: - The two faults that need more than a pattern

    /// A DLL the game imports that isn't in the prefix.
    ///
    /// The remedy is the DLL's name, so this can't be a static signature. `n,b` rather than
    /// `n`, always: native-only turns a missing file into a game that will not start at all,
    /// which is how a fix for BioShock Remastered became a worse bug than the one it fixed.
    private static func missingImportedDLL(in transcript: String) -> Finding? {
        guard let range = transcript.range(of: #"import_dll Library \S+\.dll not found"#,
                                           options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }

        let matched = String(transcript[range])

        guard let nameRange = matched.range(of: #"\S+\.dll"#, options: [.regularExpression]) else {
            return nil
        }

        let library = String(matched[nameRange])
        let base = library.replacingOccurrences(of: ".dll", with: "", options: [.caseInsensitive])
            .lowercased()

        return .init(
            signature: "missing-imported-dll",
            summary: String(localized: "The game needs \(library), which isn't in its container."),
            evidence: [matched],
            remedy: .init(
                describedAs: String(localized: "Install \(library) into the container"),
                settings: .init(dllOverrides: [base: "n,b"]),
                winetricks: knownVerb(for: base).map { [$0] } ?? []
            )
        )
    }

    /// The same missing DLL, when the app is the one that made it missing.
    ///
    /// A bare `"n"` override means native *only*: with no native file in the prefix it resolves
    /// to nothing and the game will not start, where Wine's builtin would at least have tried.
    /// Recognised separately because the remedy is to undo our own setting, and because a
    /// generic "install the DLL" answer here would keep failing for as long as the verb does.
    private static func nativeOnlyOverride(in transcript: String,
                                           applied: RuntimeProfile.SettingsOverride) -> Finding? {
        guard let overrides = applied.dllOverrides else { return nil }

        let nativeOnly = overrides.filter { $0.value.trimmingCharacters(in: .whitespaces) == "n" }
        guard !nativeOnly.isEmpty else { return nil }

        guard transcript.range(of: #"import_dll Library \S+\.dll not found"#,
                               options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }

        let corrected = nativeOnly.mapValues { _ in "n,b" }

        return .init(
            signature: "native-only-override-with-no-native-file",
            summary: String(localized: "A library was set to use only the Windows version, and that version isn't there."),
            evidence: nativeOnly.keys.sorted().map { "\($0) = n" },
            remedy: .init(
                describedAs: String(localized: "Fall back to Wine's own copy when the Windows one is missing"),
                settings: .init(dllOverrides: corrected)
            )
        )
    }

    /// The winetricks verb that installs a DLL, where one exists under that name.
    ///
    /// Only the ones actually verified here. A guessed verb fails the download, writes a line
    /// to the failure marker, and leaves the person with a fix that reads as applied.
    private static func knownVerb(for library: String) -> String? {
        let verbs: Set<String> = [
            "d3dcompiler_43", "d3dcompiler_47",
            "d3dx9", "d3dx10", "d3dx11_43",
            "vcrun2005", "vcrun2008", "vcrun2010", "vcrun2012",
            "vcrun2013", "vcrun2015", "vcrun2017", "vcrun2019", "vcrun2022",
            "xact", "xinput", "physx", "dotnet48", "dotnet35"
        ]

        return verbs.contains(library) ? library : nil
    }

    // MARK: - Evidence

    /// The transcript lines that matched, so a report carries the proof and not the whole log.
    private static func lines(in transcript: String, matching patterns: [String]) -> [String] {
        var collected: [String] = []

        for line in transcript.split(separator: "\n") {
            let matches = patterns.contains { pattern in
                line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }

            if matches {
                collected.append(String(line))
                if collected.count >= 12 { break }
            }
        }

        return collected
    }
}
