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

    @Test("The boot that creates a container can't ask for wine-mono either")
    func theCreatingBootDisablesMonoToo() throws {
        // A container that doesn't exist yet: no `drive_c`, no settings. This is what
        // `Wine.boot(at:parameters: .prefixInit)` hands to `transformProcess`, and it never
        // went near `assembleEnvironmentVariables` — which is why the test above passed while
        // every new container still put up the Wine Mono Installer and waited on it.
        let fresh: URL = .temporaryDirectory.appending(path: "PorTalisticTests-\(UUID().uuidString)")

        let process: Process = .init()
        process.environment = ["WINEDEBUG": "+environ"]
        Wine.transformProcess(process, containerURL: fresh)

        let overrides = try #require(process.environment?["WINEDLLOVERRIDES"],
                                     "a wineboot without overrides is a wineboot that can ask for wine-mono")
        #expect(overrides.contains("mscoree=d"))
        #expect(overrides.contains("mshtml=d"))
        #expect(process.environment?["WINEDEBUG"] == "+environ", "the caller's own variables survive")
    }

    @Test("A caller's own DLL overrides keep the base ones in front, once")
    func baseOverridesAreAddedOnce() {
        #expect(Wine.withBaseDLLOverrides(nil) == Wine.baseDLLOverrides)
        #expect(Wine.withBaseDLLOverrides("d3d11=n,b") == Wine.baseDLLOverrides + ";d3d11=n,b")

        let assembled = Wine.baseDLLOverrides + ";d3d11,dxgi=n,b"
        #expect(Wine.withBaseDLLOverrides(assembled) == assembled, "an assembled environment already has them")
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

/**
 Whether the `wineboot` that creates a container finished it.

 Every Wine 11.16 container failed to be created, on every Mac that didn't already have one:
 `wineboot` exited 0 into a finished prefix, the app waited for a line Wine 9.14 made a trace
 nobody asks for, said "Wine stopped before its Windows environment was ready", and deleted the
 prefix — on every attempt, for every game. The verdict is the prefix now, and these prefixes
 are laid out the way `wineboot` leaves them.
 */
@Suite("Creating a container")
struct ContainerCreationRegressionTests {
    /// A prefix as `wineboot` leaves it. `installed` is whether `wine.inf`'s `DefaultInstall`
    /// ran; `PreInstall` has written its file into `system32` either way.
    private func withPrefix<T>(installed: Bool, _ body: (URL) throws -> T) throws -> T {
        let url: URL = .temporaryDirectory.appending(path: "PorTalisticTests-\(UUID().uuidString)")
        let system32 = url.appending(path: "drive_c/windows/system32")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        FileManager.default.createFile(atPath: system32.appending(path: "winedevice.exe").path, contents: nil)
        if installed {
            FileManager.default.createFile(atPath: system32.appending(path: "kernel32.dll").path, contents: nil)
        }

        return try body(url)
    }

    /// Lines from the end of what Wine 11.16 printed creating a container on a clean Mac,
    /// 30/9/2026 — errors included, because a finished boot prints those too — and nowhere a
    /// line saying the configuration was updated.
    private let wine11Output = """
        0104:err:ntoskrnl:ZwLoadDriver failed to create driver L"winebth": c00000e5
        002c:err:setupapi:SetupDiInstallDevice Failed to start service L"winebth" for device L"ROOT", error 1359.
        012c:err:setupapi:do_file_copyW Unsupported style(s) 0x10
        0024:trace:process:NtQueryInformationProcess (0x64,0x00000000,0x31fd80,0x00000030,0x0)
        0158:trace:loaddll:build_module Loaded L"imm32.dll" at 00006FFFFD7B0000: builtin

        """

    @Test("A clean exit into a finished prefix is a container, whatever Wine printed about it")
    func aFinishedPrefixIsAContainer() throws {
        try withPrefix(installed: true) { prefix in
            #expect(Wine.prefixSetupShortfall(at: prefix, exitStatus: 0, standardError: wine11Output) == nil,
                    "Wine 9.14 and later don't announce a finished prefix unless asked — every Wine 11 container failed on this")
            #expect(Wine.prefixSetupShortfall(at: prefix, exitStatus: 0, standardError: nil) == nil,
                    "output that couldn't be read says nothing about the prefix")
            #expect(Wine.prefixSetupShortfall(at: prefix, exitStatus: 0,
                                              standardError: "wine: configuration in '/tmp/prefix' has been updated.\n") == nil,
                    "the engines that still announce it are unaffected")
        }
    }

    @Test("A clean exit into a prefix Windows was never installed into is not a container")
    func anUninstalledPrefixIsNotAContainer() throws {
        try withPrefix(installed: false) { prefix in
            let shortfall = Wine.prefixSetupShortfall(at: prefix, exitStatus: 0, standardError: wine11Output)
            #expect(shortfall?.contains("kernel32.dll") == true,
                    "drive_c exists from the first moment; only a finished install puts kernel32.dll in system32")
        }
    }

    @Test("A boot that exits with a failure is not a container, even over a finished prefix")
    func aFailedExitIsNotAContainer() throws {
        try withPrefix(installed: true) { prefix in
            let shortfall = Wine.prefixSetupShortfall(at: prefix, exitStatus: 1, standardError: wine11Output)
            #expect(shortfall?.contains("status 1") == true)
        }
    }

    @Test("Wine saying it couldn't update the prefix is a failure, even on a clean exit")
    func aFailedUpdateIsNotAContainer() throws {
        try withPrefix(installed: true) { prefix in
            let complaint = #"wine: failed to update L"/tmp/prefix", wine.inf not found"#
            let shortfall = Wine.prefixSetupShortfall(at: prefix, exitStatus: 0,
                                                      standardError: wine11Output + complaint + "\n")
            #expect(shortfall?.contains("wine.inf not found") == true)
        }
    }

    @Test("The alert says what the boot left undone")
    func theErrorSaysWhatWasMissing() {
        let error = Wine.Container.UnableToBootError(containerName: "Wine 11.16 (DXMT)",
                                                     unfinished: "wineboot exited with status 1")

        #expect(error.errorDescription?.contains("wineboot exited with status 1") == true)
        #expect(error.errorDescription?.contains("Wine 11.16 (DXMT)") == true)
    }
}

/**
 Reading back the Windows version a container reports.

 `winecfg -v` answers on stdout up to Wine 8 and on stderr from Wine 9. Which one to read was
 decided by the *bundled engine's* version — 7.7, whatever the container ran — so every Wine 11
 container answered `nil`, and the per-launch apply set its Windows version again every time.
 */
@Suite("A container's Windows version")
struct WindowsVersionRegressionTests {
    @Test("The answer is found on whichever stream this Wine printed it", arguments: [true, false])
    func eitherStream(onStandardError: Bool) {
        // Whatever the container's WINEDEBUG lets through comes before and after it.
        let noise = "0120:fixme:ntdll:NtQuerySystemInformation info_class SYSTEM_PERFORMANCE_INFORMATION\n"
        let output: Process.CommandResult = onStandardError
            ? .init(standardOutput: "", standardError: noise + "win10\n" + noise)
            : .init(standardOutput: "win10\n", standardError: noise)

        #expect(Wine.windowsVersion(reportedIn: output) == .win10)
    }

    @Test("Nothing that isn't a version name is taken for one")
    func noAnswerIsNil() {
        let output: Process.CommandResult = .init(standardOutput: nil,
                                                  standardError: "0120:err:winecfg:main something\n")

        #expect(Wine.windowsVersion(reportedIn: output) == nil)
    }
}
