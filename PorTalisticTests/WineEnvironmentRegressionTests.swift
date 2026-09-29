//
//  WineEnvironmentRegressionTests.swift
//  PorTalisticTests
//
//  Created by Claude Opus 5 on 15/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Testing

@testable import PorTalistic

/**
 The environment a wine process is handed.

 Two launch failures came from this and neither said anything useful while it was happening.
 A fresh prefix put up the "Wine could not find a wine-mono package" dialog and `wineboot`
 waited for a click that nothing in the app was ever going to make — two wine icons in the
 Dock and a game that never appeared. And a caller that assembled its own environment left
 `WINEMSYNC` out, which `wineserver` reads once at startup, so a later launch died on
 `msync_init` against a server it had no way to know was already running.

 A real container on disk rather than a stub, because the part that went wrong is precisely
 that these values are read back from what the container persisted.
 */
@Suite("Wine launch environment")
struct WineEnvironmentRegressionTests {
    private func withTemporaryContainer<T>(_ settings: Wine.Container.Settings,
                                           _ body: (Wine.Container) throws -> T) throws -> T {
        let url: URL = .temporaryDirectory.appending(path: "PorTalisticTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: "drive_c"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        return try body(Wine.Container(name: "Tests", url: url, settings: settings))
    }

    @Test("Wine is never left able to ask for wine-mono")
    func monoAndGeckoAreAlwaysDisabled() throws {
        try withTemporaryContainer(.init()) { container in
            let environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: container.url)
            let overrides = try #require(environment["WINEDLLOVERRIDES"])

            #expect(overrides.contains("mscoree=d"), "the wine-mono dialog is what blocks a boot forever")
            #expect(overrides.contains("mshtml=d"))
        }
    }

    @Test("Turning DXVK on does not drop the overrides that keep boot unattended")
    func dxvkDoesNotClobberBaseOverrides() throws {
        // `WINEDLLOVERRIDES` is one string, so the DXVK line has to extend it rather than
        // replace it. It replaced it once.
        try withTemporaryContainer(.init(dxvk: true)) { container in
            let environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: container.url)
            let overrides = try #require(environment["WINEDLLOVERRIDES"])

            #expect(overrides.contains("mscoree=d"))
            #expect(overrides.contains("mshtml=d"))
            #expect(overrides.contains("d3d11=n,b"), "and DXVK still gets asked for")
        }
    }

    @Test("Every container's environment states WINEMSYNC outright", arguments: [true, false])
    func msyncIsAlwaysStated(msync: Bool) throws {
        // Never left to a default. `wineserver` reads this once and then serves the prefix
        // long after the process that started it has gone, so a launch that doesn't say what
        // it wants inherits whatever the last one did.
        try withTemporaryContainer(.init(msync: msync)) { container in
            let environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: container.url)

            #expect(environment["WINEMSYNC"] == (msync ? "1" : "0"))
        }
    }

    @Test("A profile's override beats the container's own setting")
    func overrideBeatsContainerSetting() throws {
        try withTemporaryContainer(.init(msync: true, dxvk: false)) { container in
            let environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: container.url,
                                                                    overriding: .init(dxvk: true, msync: false))

            let overrides = try #require(environment["WINEDLLOVERRIDES"])

            #expect(environment["WINEMSYNC"] == "0")
            #expect(overrides.contains("d3d11=n,b"))
        }
    }

    @Test("A game's own DLL overrides reach the environment, after everything else")
    func perGameDLLOverridesAreApplied() throws {
        // The mechanism behind every community "settings that make this game work" line, and
        // the thing a curated entry could not say until BioShock Remastered needed `atiadlxx`
        // disabled. Last in the string, so an entry can override the base overrides too.
        try withTemporaryContainer(.init(dxvk: true)) { container in
            let environment = try Wine.assembleEnvironmentVariables(
                forContainerAtURL: container.url,
                overriding: .init(dllOverrides: ["atiadlxx": "d", "d3dcompiler_47": "n"])
            )
            let overrides = try #require(environment["WINEDLLOVERRIDES"])

            #expect(overrides.contains("atiadlxx=d"))
            #expect(overrides.contains("d3dcompiler_47=n"))
            #expect(overrides.contains("mscoree=d"), "and nothing above it was dropped")
            #expect(overrides.contains("d3d11=n,b"))

            let base = try #require(overrides.range(of: "mscoree=d"))
            let perGame = try #require(overrides.range(of: "atiadlxx=d"))
            #expect(base.lowerBound < perGame.lowerBound, "a game's own overrides come last")
        }
    }

    @Test("Two layers of DLL overrides merge instead of replacing each other")
    func dllOverridesMerge() {
        // Replacing would lose a fix silently: a curated entry disabling `atiadlxx` and a user
        // forcing a native `d3dcompiler_47` are both real, and both have to survive.
        let curated: RuntimeProfile.SettingsOverride = .init(dllOverrides: ["atiadlxx": "d"])
        let merged = curated.overlaid(with: .init(dllOverrides: ["d3dcompiler_47": "n"]))

        #expect(merged.dllOverrides?["atiadlxx"] == "d")
        #expect(merged.dllOverrides?["d3dcompiler_47"] == "n")

        // Same key: the outer layer wins, like every other field here.
        let replaced = curated.overlaid(with: .init(dllOverrides: ["atiadlxx": "n"]))
        #expect(replaced.dllOverrides?["atiadlxx"] == "n")
    }

    @Test("A launch transcript never keeps a credential")
    func transcriptsAreRedacted() throws {
        // Found in a real transcript, not imagined: BioShock Remastered runs its publisher's
        // client with curl verbosity on, stderr is the transcript, and its 2K Coretech bearer
        // token went into the file whole — account id, session id and the coordinates of the
        // city it resolved the player to. A file whose entire purpose is to be attached to a
        // bug report is the last place a live session token belongs.
        let url: URL = .temporaryDirectory.appending(path: "PorTalisticTests-\(UUID().uuidString).log")
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3ODk2NzY3MTgsInN1YiI6Ijk3Mzg3NTY0In0.c2lnbmF0dXJl"

        try """
            game: Something
            > POST /sso/v2.0/presence/heartbeats HTTP/1.1
            Authorization:Bearer \(token)
            Cookie: session=abcdef123456
            < body mentioning \(token) again
            0024:fixme:thread:SetThreadIdealProcessor stub
            """.write(to: url, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: url) }

        Wine.redactSecrets(inLogAt: url)
        let redacted = try String(contentsOf: url, encoding: .utf8)

        #expect(redacted.contains(token) == false, "the token survived")
        #expect(redacted.contains("session=abcdef123456") == false, "so did a cookie")
        #expect(redacted.contains("SetThreadIdealProcessor"), "and the diagnostics have to survive")
        #expect(redacted.contains("POST /sso/v2.0/presence/heartbeats"), "including which request it was")
    }

    @Test("The previous launch's log is kept, and redacted on the way")
    func logsRotateAndAreRedactedWhenTheyDo() throws {
        // Both halves were real problems. Only the last launch's log survived, so a game that
        // crashed twice in different places could only be looked at once. And redaction could
        // not run when a game exited, because on the Epic path nothing knows when that is —
        // `legendary` returns while the game is still writing, which is how a live bearer token
        // survived a pass that had supposedly cleaned it. The start of the next launch is the
        // first moment the previous file is genuinely finished.
        let directory: URL = .temporaryDirectory.appending(path: "PorTalisticTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "A Game — launch.log")
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI5NzM4NzU2NCJ9.c2lnbmF0dXJl"
        try "Authorization:Bearer \(token)\nkeep this line\n".write(to: url, atomically: true, encoding: .utf8)

        Wine.rotateLog(at: url)

        #expect(FileManager.default.fileExists(atPath: url.path) == false, "the way is clear for a new log")

        let previous = directory.appending(path: "A Game — launch — previous.log")
        let kept = try #require(try? String(contentsOf: previous, encoding: .utf8))

        #expect(kept.contains(token) == false, "kept, but not the credential")
        #expect(kept.contains("keep this line"))
    }

    @Test("The machine is asked whether it can open a cabinet before a verb needs it to")
    func cabinetExtractionIsDetectable() {
        // Not an assertion about this machine — it is about the question being answerable.
        // `d3dcompiler_43` lives inside Microsoft's DirectX redistributable and winetricks
        // shells out to cabextract or 7z to open it; macOS ships neither, so the verb exited 1
        // with nothing a caller could act on and the real cause took three rounds to find.
        // Whatever the answer here, a failed verb can now say which it was.
        _ = Wine.canExtractCabinets
    }

    @Test("A container that isn't there is an error, not an empty environment")
    func missingContainerThrows() {
        let absent: URL = .temporaryDirectory.appending(path: "PorTalisticTests-\(UUID().uuidString)")

        #expect(throws: Wine.Container.DoesNotExistError.self) {
            try Wine.assembleEnvironmentVariables(forContainerAtURL: absent)
        }
    }
}
