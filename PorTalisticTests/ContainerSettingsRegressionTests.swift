//
//  ContainerSettingsRegressionTests.swift
//  PorTalisticTests
//
//  Created by Claude Opus 5 on 15/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Testing

@testable import PorTalistic

/**
 The display settings a container carries, and the one rule that connects them.

 Every test in this file stands for something that reached the user. Horizon Chase Turbo
 opened in a window a quarter of the size it asked for on three separate occasions, and each
 time the cause was the same: a prefix whose DPI said one thing while its Retina Mode said
 another. The rule was fixed three times too, in three different places, which is why the
 fourth place could still contradict it.
 */
@Suite("Container display settings")
struct ContainerSettingsRegressionTests {
    @Test("Retina Mode is off by default, and so is the DPI that goes with it")
    func defaultsAreNonRetina() {
        let settings: Wine.Container.Settings = .init()

        #expect(settings.retinaMode == false)
        #expect(settings.displayScaling == 96)
    }

    @Test("The DPI follows Retina Mode, both ways")
    func displayScalingFollowsRetinaMode() {
        #expect(Wine.Container.Settings(retinaMode: true).displayScaling == 192)
        #expect(Wine.Container.Settings(retinaMode: false).displayScaling == 96)

        // The static form is what `Wine.toggleRetinaMode` and `Provisioner.apply` ask, having
        // no `Settings` of their own to consult. Both forms have to give the same answer, or
        // the rule has two versions again.
        #expect(Wine.Container.Settings.displayScaling(forRetinaMode: true) == 192)
        #expect(Wine.Container.Settings.displayScaling(forRetinaMode: false) == 96)
    }

    @Test("A stored DPI cannot contradict Retina Mode")
    func storedScalingCannotContradictRetinaMode() {
        // This is the small window, exactly. A container created while Retina Mode defaulted
        // to on kept `scaling` at 192 after the default changed. The prefix then advertised a
        // 2x display while handing the game a 1x desktop, and a DPI-aware game sized its
        // window for twice the pixels it was ever going to get.
        var settings: Wine.Container.Settings = .init(retinaMode: false)
        settings.scaling = 192

        #expect(settings.displayScaling == 96,
                "`scaling` is stored history — it must never be what decides the prefix's DPI")
    }

    @Test("A container written before Retina Mode was defaulted off still decodes non-Retina")
    func legacyContainerDecodesNonRetina() throws {
        // `scaling = 192` and no `retinaMode` key at all is what is actually on disk in the
        // prefixes made by the versions that caused this.
        let legacy: [String: Any] = ["scaling": 192]
        let data = try PropertyListSerialization.data(fromPropertyList: legacy, format: .xml, options: 0)
        let settings = try PropertyListDecoder().decode(Wine.Container.Settings.self, from: data)

        #expect(settings.retinaMode == false)
        #expect(settings.displayScaling == 96)
        #expect(settings.scaling == 192, "the stored number is kept, it just isn't obeyed")
    }

    @Test("A container made before Retina Mode was defaulted off gets migrated off it")
    func containersAreMigratedOffRetina() {
        // This fault was entirely in the data. Every default in the code read correctly and
        // every test above passed, while all four containers on the machine were still stored
        // Retina-on — because changing a default does nothing to what is already on disk, and
        // nobody upgrading has a container made after the change.
        let stored: Wine.Container.Settings = .init(retinaMode: true, scaling: 192)
        let migrated = Migrator.v0_6_1.settingsMigratedOffRetina(stored)

        #expect(migrated.retinaMode == false)
        #expect(migrated.scaling == 96, "the stored number is brought back into step, not left behind")
        #expect(migrated.displayScaling == 96)
    }

    @Test("Migrating a container touches nothing but the display pair")
    func migrationChangesOnlyTheDisplayPair() {
        let stored: Wine.Container.Settings = .init(metalHUD: true,
                                                    msync: false,
                                                    retinaMode: true,
                                                    dxvk: true,
                                                    dxvkAsync: true,
                                                    windowsVersion: .win7,
                                                    scaling: 192,
                                                    commandStreamThread: false,
                                                    runtimeID: "managed:wine-dxmt-11.16")
        let migrated = Migrator.v0_6_1.settingsMigratedOffRetina(stored)

        #expect(migrated.metalHUD == stored.metalHUD)
        #expect(migrated.msync == stored.msync)
        #expect(migrated.dxvk == stored.dxvk)
        #expect(migrated.dxvkAsync == stored.dxvkAsync)
        #expect(migrated.windowsVersion == stored.windowsVersion)
        #expect(migrated.commandStreamThread == stored.commandStreamThread)
        #expect(migrated.avx2 == stored.avx2)
        #expect(migrated.runtimeID == stored.runtimeID,
                "a container losing its runtime would be married to the wrong Wine")
    }

    @Test("Migration can never leave a contradiction behind")
    func migrationLeavesNoContradiction() {
        // Including `scaling: 0`, which is what containers from v0.3.2 and earlier carry.
        for retinaMode in [true, false] {
            for scaling in [0, 96, 192] {
                var stored: Wine.Container.Settings = .init(retinaMode: retinaMode)
                stored.scaling = scaling

                let migrated = Migrator.v0_6_1.settingsMigratedOffRetina(stored)

                #expect(migrated.scaling == migrated.displayScaling,
                        "retinaMode \(retinaMode), scaling \(scaling)")
            }
        }
    }

    @Test("A game does not take every display by default")
    func displaysAreNotCapturedByDefault() {
        // Tried the other way round and reverted. Capturing a display captures all of them —
        // there is no "just this one" — so a second monitor goes black for as long as the game
        // is fullscreen. On a two-monitor desk that is a worse trade than the menu bar sitting
        // over a corner of the game, which is what off costs.
        #expect(Wine.Container.Settings().captureDisplaysForFullscreen == false)
    }

    @Test("A container written while capture defaulted on comes back off")
    func legacyContainersDoNotCaptureDisplays() throws {
        // Neither the containers that predate the setting nor the ones written during the day
        // it defaulted to on carry the key, so both take the current default. Worth a test
        // because the opposite — a default reaching nothing already on disk — is what
        // `Migrator.v0_6_1` exists to undo.
        let legacy: [String: Any] = ["retinaMode": false, "scaling": 96]
        let data = try PropertyListSerialization.data(fromPropertyList: legacy, format: .xml, options: 0)
        let settings = try PropertyListDecoder().decode(Wine.Container.Settings.self, from: data)

        #expect(settings.captureDisplaysForFullscreen == false)
    }

    @Test("Display capture can be turned on for one game without touching the container")
    func displayCaptureIsOverridablePerGame() {
        // The reason it is a setting rather than a deleted experiment: one game worth giving
        // the whole screen to shouldn't mean every game taking the second monitor.
        let container: Wine.Container.Settings = .init()
        let overlaid = RuntimeProfile.SettingsOverride(captureDisplaysForFullscreen: true)
            .overlaid(with: .init())

        #expect(container.captureDisplaysForFullscreen == false)
        #expect(overlaid.captureDisplaysForFullscreen == true)
        #expect(RuntimeProfile.SettingsOverride(captureDisplaysForFullscreen: false).isEmpty == false,
                "`false` is an opinion here too — a game can ask to leave the other screens alone")
    }

    @Test("A container carries no runtime until one is chosen for it")
    func newContainersHaveNoRuntime() {
        // `nil` means the bundled engine, which is what every container made before runtimes
        // existed decodes as. A default of anything else would silently marry old prefixes to
        // a Wine that cannot open them — prefixes migrate forward only.
        #expect(Wine.Container.Settings().runtimeID == nil)
    }
}
