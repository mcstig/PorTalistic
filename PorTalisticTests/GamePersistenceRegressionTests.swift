//
//  GamePersistenceRegressionTests.swift
//  PorTalisticTests
//
//  Created by Claude Opus 5 on 15/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Testing

@testable import PorTalistic

/**
 What survives being written to disk and read back, and what survives a storefront refresh.

 A library refresh merges what a storefront says into what is already stored, which means
 every per-game setting has to have an answer for "the storefront doesn't know about this".
 Getting that wrong is quiet and expensive: unplugging an external disk once destroyed a GOG
 install record, because a refresh that couldn't see the files reported the game as
 uninstalled and the merge believed it.
 */
@Suite("Game persistence")
struct GamePersistenceRegressionTests {
    private func installedGame(id: String = "test-game",
                               title: String = "Test Game",
                               at location: URL = .temporaryDirectory.appending(path: "PorTalisticTests-Game")) -> LocalGame {
        .init(id: id, title: title, installationState: .installed(location: location, platform: .windows))
    }

    @Test("Per-game settings survive a round trip through storage")
    func settingsSurviveEncoding() throws {
        let game = installedGame()
        game.isSettingsAutomatic = false
        game.settingsOverride = .init(retinaMode: true, windowsVersion: .win7)
        game.isFavourited = true

        let data = try JSONEncoder().encode(AnyGame(game))
        let restored = try JSONDecoder().decode(AnyGame.self, from: data).base

        #expect(restored is LocalGame, "the storefront has to survive too, or the game decodes as a bare Game")
        #expect(restored.id == game.id)
        #expect(restored.isSettingsAutomatic == false)
        #expect(restored.settingsOverride.retinaMode == true)
        #expect(restored.settingsOverride.windowsVersion == .win7)
        #expect(restored.isFavourited)
        #expect(restored.isInstalled)
    }

    @Test("A game stored before per-game settings existed decodes as automatic")
    func legacyGamesDecodeAsAutomatic() throws {
        // Built by removing the keys rather than by hand-writing the old shape, so this keeps
        // testing the real format rather than my memory of it.
        let data = try JSONEncoder().encode(AnyGame(installedGame()))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        object.removeValue(forKey: "isSettingsAutomatic")
        object.removeValue(forKey: "settingsOverride")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(AnyGame.self, from: legacy).base

        #expect(restored.isSettingsAutomatic, "absent means let the app decide, which is what it was already doing")
        #expect(restored.settingsOverride.isEmpty)
    }

    @Test("A refresh that cannot see the files does not un-install the game")
    func refreshDoesNotUninstall() throws {
        // The unplugged-disk fault, at the layer where it did the damage.
        let stored = installedGame(id: "same", title: "Same")
        let refreshed: LocalGame = .init(id: "same", title: "Same", installationState: .uninstalled)

        try stored.merge(with: refreshed)

        #expect(stored.isInstalled)
    }

    @Test("A hand-made settings choice outlives a refresh")
    func refreshDoesNotResetSettings() throws {
        let stored = installedGame(id: "same", title: "Same")
        stored.isSettingsAutomatic = false
        stored.settingsOverride = .init(retinaMode: true)
        stored.isFavourited = true

        let refreshed = installedGame(id: "same", title: "Same")

        try stored.merge(with: refreshed)

        #expect(stored.isSettingsAutomatic == false, "if either side has taken the wheel, it stays taken")
        #expect(stored.settingsOverride.retinaMode == true)
        #expect(stored.isFavourited)
    }

    @Test("A refresh that has taken the wheel is respected too")
    func refreshCanTakeOverSettings() throws {
        let stored = installedGame(id: "same", title: "Same")
        let refreshed = installedGame(id: "same", title: "Same")
        refreshed.isSettingsAutomatic = false
        refreshed.settingsOverride = .init(dxvk: true)

        try stored.merge(with: refreshed)

        #expect(stored.isSettingsAutomatic == false)
        #expect(stored.settingsOverride.dxvk == true)
    }

    @Test("A game on a disk that isn't attached still counts as installed")
    func installedOnAnAbsentVolumeIsStillInstalled() {
        let game = installedGame(at: URL(filePath: "/Volumes/\(UUID().uuidString)/Games/Test"))

        #expect(game.isInstalled,
                """
                `isInstalled` is what the library believes, not what the disk says. A card that \
                asks the disk instead is what made macOS prompt for removable-volume access \
                while scrolling.
                """)
    }

    @Test("An uninstalled game says so")
    func uninstalledGamesSaySo() {
        let game: LocalGame = .init(id: "none", title: "None", installationState: .uninstalled)

        #expect(game.isInstalled == false)
    }

    @Test("Installed beats uninstalled whichever way round the merge runs")
    func installationStateOrdering() {
        // `max` is the merge strategy for this key, so the ordering *is* the rule.
        let installed: Game.InstallationState = .installed(location: URL(filePath: "/tmp/x"), platform: .windows)

        #expect(isInstalled(max(installed, .uninstalled)))
        #expect(isInstalled(max(Game.InstallationState.uninstalled, installed)))
    }

    private func isInstalled(_ state: Game.InstallationState) -> Bool {
        if case .installed = state { return true }
        return false
    }
}
