//
//  RuntimeProfileRegressionTests.swift
//  PorTalisticTests
//
//  Created by Claude Opus 5 on 15/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Testing

@testable import PorTalistic

/**
 What a game gets launched with when nobody has told the app anything.

 The point of automatic settings is that a default is applied to a hundred and thirty games
 at once, so a wrong default is not one bug. Retina Mode on gave Prey a quarter of a
 4096x2660 desktop and blanked the other display; off is now the default everywhere, and
 these tests are what stop it drifting back.
 */
@Suite("Runtime profiles")
struct RuntimeProfileRegressionTests {
    @Test("A game nothing is known about does not get a Retina desktop")
    func unknownGameIsNonRetina() {
        #expect(RuntimeProfile.unknownGame.settings.retinaMode == false)
        #expect(RuntimeProfile.unknownGame.source == .fallback)
        #expect(RuntimeProfile.unknownGame.reasons.isEmpty == false,
                "a verdict that can't explain itself is indistinguishable from a bug")
    }

    @Test("Resolving with nothing to go on still says Retina Mode off")
    func resolvingWithNoEvidenceIsNonRetina() {
        let profile: RuntimeProfile = .resolve(executable: nil)

        #expect(profile.settings.retinaMode == false)
        #expect(profile.source == .fallback)
    }

    @Test("A hand-set value wins, and the profile says so")
    func userOverrideWins() {
        let profile: RuntimeProfile = .resolve(executable: nil, userOverride: .init(retinaMode: true))

        #expect(profile.settings.retinaMode == true)
        #expect(profile.source == .userOverride)
        #expect(profile.source.isAutomatic == false,
                "the settings panel reads this to decide whether to show Auto as on")
    }

    @Test("An empty override does not claim the user chose anything")
    func emptyOverrideIsNotAUserChoice() {
        // Every game carries a `settingsOverride`, empty until something is set by hand. If
        // an empty one counted, every game in the library would report itself as manually
        // configured and automatic would never apply to anything.
        let profile: RuntimeProfile = .resolve(executable: nil, userOverride: .init())

        #expect(profile.source == .fallback)
    }

    @Test("Overlaying keeps what the other side has no opinion about")
    func overlayingIsSparse() {
        let base: RuntimeProfile.SettingsOverride = .init(dxvk: false, retinaMode: false)
        let overlaid = base.overlaid(with: .init(retinaMode: true))

        #expect(overlaid.retinaMode == true, "the other side wins where it has an opinion")
        #expect(overlaid.dxvk == false, "and does not erase what it has no opinion about")
        #expect(overlaid.msync == nil, "and invents nothing")
    }

    @Test("`false` is an opinion, not an absence")
    func falseIsAnOpinion() {
        #expect(RuntimeProfile.SettingsOverride().isEmpty)
        #expect(RuntimeProfile.SettingsOverride(retinaMode: false).isEmpty == false)
        #expect(RuntimeProfile.SettingsOverride().overlaid(with: .init(retinaMode: false)).retinaMode == false)
    }

    @Test("Every curated entry explains itself")
    func curatedEntriesExplainThemselves() {
        // The database's own rule, from its documentation: "Retina Mode off" is meaningless in
        // six months, and it is what the user reads when a game won't start.
        for entry in CompatibilityDatabase.seed.entries {
            let named = entry.titles.first ?? entry.identifiers.first?.id ?? "an unnamed entry"

            #expect(entry.note?.isEmpty == false, "\(named) has no note")
        }
    }

    @Test("A curated entry is reachable by every identifier and title it claims")
    func curatedEntriesAreReachable() {
        // An entry nothing can look up is worse than no entry: it reads as a fix that is in
        // place while inspection quietly decides something else.
        let database: CompatibilityDatabase = .seed

        for entry in CompatibilityDatabase.seed.entries {
            for identifier in entry.identifiers {
                #expect(database.entry(storefront: identifier.storefront, id: identifier.id, title: "") != nil,
                        "\(identifier.storefront) \(identifier.id) matches nothing")
            }

            for title in entry.titles {
                #expect(database.entry(storefront: nil, id: "", title: title) != nil,
                        "\"\(title)\" matches nothing")
            }
        }
    }

    @Test("An entry with a note carries something that acts")
    func notesAreNotFixes() {
        // The failure this catches: Blades of Time's entry described a stack overflow caused
        // by Retina Mode being off, set nothing at all, and was left that way on the
        // assumption the game would move to DXMT — which a 32-bit game never can. The note
        // read like a fix and was a comment. When the global default for Retina Mode later
        // went off, the crash it described came straight back.
        //
        // Deliberately not "a note that mentions a setting must state it": a good note also
        // records what was *tried and rejected*, and this entry now names both CSMT and Retina
        // Mode as wrong answers.
        for entry in CompatibilityDatabase.seed.entries {
            guard let note = entry.note, !note.isEmpty else { continue }
            let named = entry.titles.first ?? entry.identifiers.first?.id ?? "an unnamed entry"

            let acts = !entry.settings.isEmpty
                || entry.graphicsBackend != nil
                || entry.requiresModernNetworking == true
                || entry.requiresNativeThirtyTwoBit == true

            #expect(acts, """
                \(named) has a note and changes nothing. Either it states the setting, the \
                backend or the requirement that avoids what it describes, or the entry goes \
                and the note goes with it — an entry that only explains is a comment \
                pretending to be a fix.
                """)
        }
    }

    @Test("Blades of Time asks for a Wine with real 32-bit support")
    func bladesOfTimeNeedsNativeThirtyTwoBit() throws {
        // Measured: on the bundled engine — CrossOver-derived, so 32-on-64 — this exhausts the
        // main thread's 1MB stack on its fullscreen path, because every Win32 call reaches the
        // 64-bit side through a thunk and the frames come out deeper than the game was built
        // for. Turning CSMT off gave a byte-identical crash. Retina Mode on avoids it and
        // blacks out every other display, which is not a trade worth making.
        let entry = try #require(CompatibilityDatabase.seed.entry(storefront: .gog,
                                                                  id: "1164193173",
                                                                  title: "Blades of Time"))

        #expect(entry.requiresNativeThirtyTwoBit == true)
        #expect(entry.settings.retinaMode == false, "the crash is fixed by the runtime, not by taking someone's monitor")
    }

    @Test("A curated requirement cannot be taken away by a default")
    func curatedRequirementsSurviveADefaultChange() {
        // The mechanism, not one game. A per-game entry has to win over whatever the defaults
        // happen to be that week — turning Retina Mode off for every container is what
        // re-created a crash that had been recorded, explained, and left unenforced.
        let entry = CompatibilityDatabase.seed.entry(storefront: .gog,
                                                     id: "1164193173",
                                                     title: "Blades of Time")
        let profile: RuntimeProfile = .resolve(executable: nil, databaseEntry: entry)

        #expect(profile.requirements.nativeThirtyTwoBit)
        #expect(profile.source == .database)
    }

    @Test("Only a build with a real i386 architecture answers that requirement")
    func onlyNativeThirtyTwoBitBuildsQualify() {
        // The bundled engine must never satisfy it — it is the specific thing being ruled out,
        // and `rankedWithCompromises` therefore has to refuse to fall back to it.
        let required: RuntimeProfile.Requirements = .init(nativeThirtyTwoBit: true)

        for release in RuntimeRelease.catalogue where !release.capabilities.nativeThirtyTwoBit {
            #expect(RuntimeRelease.release(satisfying: required)?.id != release.id,
                    "\(release.name) has no real i386 architecture and must not be offered")
        }

        if let answer = RuntimeRelease.release(satisfying: required) {
            #expect(answer.capabilities.nativeThirtyTwoBit)
            #expect(answer.hasNativeThirtyTwoBit)
        }
    }

    @Test("A DLL override that needs a real file comes with the verb that installs it")
    func overridesNeedingAFileCarryTheirVerb() throws {
        // The trap this guards: `d3dcompiler_47=n` with no native file in the prefix falls
        // straight through to Wine's builtin and changes nothing, so the override reads like a
        // fix and is a no-op. Any entry asking for a DLL that Wine does not ship has to ask for
        // the verb that puts it there too.
        let needsAFile: Set<String> = ["d3dcompiler_47", "d3dcompiler_43", "d3dx9", "vcrun2019", "xact"]

        for entry in CompatibilityDatabase.seed.entries {
            let named = entry.titles.first ?? entry.identifiers.first?.id ?? "an unnamed entry"

            for (dll, spec) in entry.settings.dllOverrides ?? [:]
            where needsAFile.contains(dll) && spec.hasPrefix("n") {
                #expect(entry.winetricks.contains(dll), """
                    \(named) asks for a native \(dll) without the winetricks verb that installs \
                    it. Native with no file present is Wine's builtin, silently.
                    """)
            }
        }
    }

    @Test("No entry asks for a native DLL without a fallback")
    func nativeOverridesAlwaysFallBack() {
        // `n` means native *only*. With no real file in the prefix it resolves to nothing, the
        // import fails with `c0000135`, and the game does not start at all — which is strictly
        // worse than the fault the override was added to fix. `n,b` is native if a file is
        // there and Wine's builtin otherwise, so a verb whose download failed costs the fix
        // rather than the game. This is not hypothetical: it happened to BioShock Remastered
        // the first time round, because the `d3dcompiler_43` verb could not be installed.
        for entry in CompatibilityDatabase.seed.entries {
            let named = entry.titles.first ?? entry.identifiers.first?.id ?? "an unnamed entry"

            for (dll, spec) in entry.settings.dllOverrides ?? [:] where spec.contains("n") {
                #expect(spec.contains("b"), """
                    \(named) overrides \(dll) as "\(spec)". A native-only override turns a \
                    missing file into a game that will not launch; write "n,b".
                    """)
            }
        }
    }

    @Test("BioShock Remastered gets both halves of its fix")
    func bioShockNeedsBothHalves() throws {
        // Two separate crashes, two separate causes, and the second only became visible once
        // the first was fixed: a stub AMD Display Library handing the game a null, then Wine's
        // HLSL compiler unable to compile any shader containing a jump.
        let entry = try #require(CompatibilityDatabase.seed.entry(storefront: .epicGames,
                                                                  id: "bc2c95c6ff564a16b26644f1d3ac3c55",
                                                                  title: "BioShock Remastered"))

        #expect(entry.settings.dllOverrides?["atiadlxx"] == "d")

        // Both versions: Wine logs every d3dcompiler under one channel, so the log never says
        // which the game loads, and overriding only 47 left Wine's own compiler running.
        for version in ["d3dcompiler_43", "d3dcompiler_47"] {
            #expect(entry.settings.dllOverrides?[version] == "n")
            #expect(entry.winetricks.contains(version))
        }
    }

    @Test("A curated entry's winetricks verbs reach the profile")
    func winetricksVerbsReachTheProfile() {
        // Prefix preparation has to survive resolution, or `planLaunch` never installs it.
        let entry = CompatibilityDatabase.seed.entry(storefront: .epicGames,
                                                     id: "bc2c95c6ff564a16b26644f1d3ac3c55",
                                                     title: "BioShock Remastered")
        let profile: RuntimeProfile = .resolve(executable: nil, databaseEntry: entry)

        #expect(profile.winetricks.contains("d3dcompiler_47"))
        #expect(RuntimeProfile.unknownGame.winetricks.isEmpty, "and nothing is installed for a game nobody has an opinion about")
    }

    @Test("Titles match through the decoration storefronts add to them")
    func titleMatchingIgnoresDecoration() {
        #expect(CompatibilityDatabase.normalise("Sid Meier's Civilization® VI") == "sidmeierscivilizationvi")
        #expect(CompatibilityDatabase.normalise("PREY") == CompatibilityDatabase.normalise("Prey"))
        #expect(CompatibilityDatabase.normalise("Fallout: New Vegas™") == CompatibilityDatabase.normalise("Fallout New Vegas"))
    }

    @Test("A title that normalises to nothing matches nothing")
    func emptyTitlesMatchNothing() {
        // Otherwise a game whose title is punctuation, or a lookup done before the title
        // arrives, takes whichever entry happens to be first in the list.
        #expect(CompatibilityDatabase.seed.entry(storefront: nil, id: "", title: "") == nil)
        #expect(CompatibilityDatabase.seed.entry(storefront: nil, id: "", title: "—") == nil)
    }

    @Test("An unknown game is not refused a profile")
    func unknownGamesStillLaunch() {
        // A game the app knows nothing about still has to start. `unknownGame` is deliberately
        // the answer most games want rather than a refusal.
        #expect(RuntimeProfile.unknownGame.requirements == .init())
        #expect(RuntimeProfile.unknownGame.graphicsBackend == nil)
    }
}

/**
 Automatic settings, from the outside: what the switch in a game's settings actually does.

 "The user should not have to worry about what Wine version a game runs on" is the feature;
 turning it off has to hand over exactly what automatic had arrived at rather than a blank
 slate, and turning it back on must not have lost anything.
 */
@Suite("Automatic settings")
@MainActor
struct AutomaticSettingsRegressionTests {
    @Test("Automatic does not read the stored override, and does not throw it away")
    func automaticIgnoresTheStoredOverride() async {
        let game: LocalGame = .init(id: "auto", title: "Auto", installationState: .uninstalled)
        game.isSettingsAutomatic = true
        game.settingsOverride = .init(retinaMode: true)

        let profile = await Provisioner.shared.profile(for: game)

        #expect(profile.source.isAutomatic)
        #expect(profile.settings.retinaMode != true, "automatic works the answer out; it does not consult the override")
        #expect(game.settingsOverride.retinaMode == true, "and it keeps it, so switching automatic off returns what was there")
    }

    @Test("Switching automatic off hands over exactly what was stored")
    func manualUsesTheStoredOverride() async {
        let game: LocalGame = .init(id: "manual", title: "Manual", installationState: .uninstalled)
        game.isSettingsAutomatic = false
        game.settingsOverride = .init(retinaMode: true)

        let profile = await Provisioner.shared.profile(for: game)

        #expect(profile.settings.retinaMode == true)
        #expect(profile.source == .userOverride)
    }

    @Test("A game whose platform was never recorded is still read as a Windows game")
    func unrecordedPlatformsAreStillInspected() {
        // `platform == .windows` was too strict. A game whose recorded platform never got
        // filled in is still a Windows game with an executable worth reading, and skipping it
        // sent the profile all the way back to "PorTalistic hasn't read this game's files
        // yet" for games that were plainly running under Wine.
        let windows: LocalGame = .init(id: "win", title: "Windows Game",
                                        installationState: .installed(location: URL(filePath: "/tmp/win"),
                                                                      platform: .windows))
        #expect(Provisioner.GameFacts(game: windows) != nil)

        let mac: LocalGame = .init(id: "mac", title: "Mac Game",
                                    installationState: .installed(location: URL(filePath: "/tmp/mac"),
                                                                  platform: .macOS))
        #expect(Provisioner.GameFacts(game: mac) == nil, "a native build has no PE binary to inspect")

        let uninstalled: LocalGame = .init(id: "none", title: "Nothing", installationState: .uninstalled)
        #expect(Provisioner.GameFacts(game: uninstalled) == nil, "nothing on disk to read")
    }
}
