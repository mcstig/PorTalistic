//
//  RebrandRegressionTests.swift
//  PorTalisticTests
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import Foundation
import Testing

@testable import PorTalistic

/**
 What macOS calls a Windows program PorTalistic started.

 Force Quit listed a running game as `BioshockHD.exe (Mythic)`. Nothing in this app said that:
 the bundled engine's Mac driver registers every Windows process with LaunchServices under
 upstream's name, from a format string compiled into `winemac.drv`, and `Wine.ApplicationNaming`
 renames each one once it has a window. These pin what that rename has to get right — the
 launcher's name goes, the executable's name stays (Force Quit is useless without it, and the
 foreground hand-off finds games by it), and only a Wine this app installed is touched.

 The LaunchServices round trip itself can't run here: it needs a Windows program with a window.
 Launch a game and open Force Quit (⌘⌥⎋).
 */
@Suite("Windows program names")
struct WindowsProgramNameRegressionTests {
    private let brand = "PorTalistic"

    private func verdict(_ displayName: String) -> Wine.ApplicationName.Verdict {
        Wine.ApplicationName.verdict(forDisplayName: displayName, brand: brand)
    }

    @Test("The engine's name for a game is replaced with this app's")
    func upstreamNameIsReplaced() {
        #expect(verdict("BioshockHD.exe (Mythic)") == .rename(to: "BioshockHD.exe (PorTalistic)"))
    }

    @Test("Whichever launcher an engine was built for, its name goes",
          arguments: ["Mythic", "Whisky", "CrossOver", "Wine"])
    func anyLauncherNameIsReplaced(launcher: String) {
        #expect(verdict("Prey.exe (\(launcher))") == .rename(to: "Prey.exe (PorTalistic)"))
    }

    @Test("The executable's name survives the rename")
    func executableNameIsKept() {
        // `Wine.handOverForeground` recognises a game by its executable's name in `localizedName`.
        // A rename that dropped it would stop games coming to the front, and leave Force Quit
        // with rows nobody can tell apart.
        guard case .rename(to: let renamed) = verdict("BloodstainedRotN-Win64-Shipping.exe (Mythic)") else {
            Issue.record("a game named by the engine should be renamed")
            return
        }

        #expect(renamed.localizedCaseInsensitiveContains("BloodstainedRotN-Win64-Shipping"))
        #expect(!renamed.contains("Mythic"))
    }

    @Test("Executable names with brackets or dots of their own keep them")
    func awkwardExecutableNames() {
        #expect(verdict("Game (x64).exe (Mythic)") == .rename(to: "Game (x64).exe (PorTalistic)"))
        #expect(verdict("My.Game.v1.2.exe (Mythic)") == .rename(to: "My.Game.v1.2.exe (PorTalistic)"))
    }

    @Test("A program named only after its executable gets this app's name beside it")
    func bareExecutableGetsTheBrand() {
        #expect(verdict("steam.exe") == .rename(to: "steam.exe (PorTalistic)"))
    }

    @Test("A program already called the right thing is left alone")
    func alreadyNamedIsSettled() {
        // Otherwise every pass would ask LaunchServices again, for as long as the game ran.
        #expect(verdict("BioshockHD.exe (PorTalistic)") == .alreadyNamed)
        #expect(verdict("  BioshockHD.exe (PorTalistic) ") == .alreadyNamed)
    }

    @Test("A name that isn't a program's is never replaced by the brand on its own",
          arguments: ["Wine", "CrossOver-Hosted Application", "BioshockHD", "Mythic", ""])
    func notAProgramNameIsLeftAlone(name: String) {
        // Renaming "Wine" to "PorTalistic" would put two rows called PorTalistic in Force Quit —
        // one of them the game — and nothing to say which is which.
        #expect(verdict(name) == .notAProgramName)
    }

    // MARK: - Whose Wine

    private let ownWineDirectories: [URL] = [
        URL(filePath: "/Users/player/Library/Application Support/PorTalistic/Engine"),
        URL(filePath: "/Users/player/Library/Application Support/PorTalistic/Runtimes")
    ]

    @Test("Programs on the engine and on the managed runtimes are this app's",
          arguments: [
            "/Users/player/Library/Application Support/PorTalistic/Engine/wine/bin/wine64-preloader",
            "/Users/player/Library/Application Support/PorTalistic/Runtimes/wine-stable-11.0/Wine Stable.app/Contents/Resources/wine/bin/wine"
          ])
    func ownWineIsRecognised(path: String) {
        #expect(Wine.ApplicationName.isRunningOnOwnWine(executableURL: URL(filePath: path),
                                                          ownWineDirectories: ownWineDirectories))
    }

    @Test("Another app's Wine is left alone, and so is a folder that only starts the same way",
          arguments: [
            "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine",
            "/Users/player/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64-preloader",
            "/Users/player/Library/Application Support/PorTalistic/Engine-old/wine/bin/wine64-preloader"
          ])
    func otherWineIsNotClaimed(path: String) {
        #expect(!Wine.ApplicationName.isRunningOnOwnWine(executableURL: URL(filePath: path),
                                                           ownWineDirectories: ownWineDirectories))
    }

    @Test("A program with no executable path is never claimed")
    func missingExecutableIsNotClaimed() {
        #expect(!Wine.ApplicationName.isRunningOnOwnWine(executableURL: nil, ownWineDirectories: ownWineDirectories))
    }

    // MARK: - lsappinfo

    @Test("LaunchServices' answer is read back as the name")
    func infoOutputIsParsed() {
        #expect(Wine.ApplicationName.displayName(inInfoOutput: "\"LSDisplayName\"=\"BioshockHD.exe (Mythic)\"\n")
                == "BioshockHD.exe (Mythic)")
        #expect(Wine.ApplicationName.displayName(inInfoOutput: "") == nil)
    }

    @Test("The new name reaches lsappinfo as one quoted string")
    func renameIsQuoted() {
        // lsappinfo parses the value itself, and a string with spaces in it is one it is given
        // in double quotes.
        #expect(Wine.ApplicationName.writeNameArguments("BioshockHD.exe (PorTalistic)", forProcess: 4242)
                == ["setinfo", "-app", "4242", "LSDisplayName=\"BioshockHD.exe (PorTalistic)\""])
    }
}

/**
 Where games install by default, now that the default is named after this app.

 The rename changed the default install folder from `Games/Mythic` to `Games/PorTalistic`, and
 that folder is also where installed games are looked for: a GOG install record without a
 location of its own is found at the install folder plus the game's name. Moving the default out
 from under a library that is already there would make those games look uninstalled — the fault
 `GamePersistenceRegressionTests` exists for, reached from a different direction.
 */
@Suite("Install folder after the rebrand")
struct InstallFolderRegressionTests {
    @Test("A library already in upstream's games folder keeps installing there")
    func existingLibraryKeepsItsFolder() {
        #expect(Migrator.v0_6_0.shouldKeepUpstreamGamesFolder(hasChosenInstallFolder: false,
                                                               upstreamFolderContents: ["Prey", ".DS_Store"]))
    }

    @Test("A folder the person chose is never overridden")
    func chosenFolderWins() {
        #expect(!Migrator.v0_6_0.shouldKeepUpstreamGamesFolder(hasChosenInstallFolder: true,
                                                                upstreamFolderContents: ["Prey"]))
    }

    @Test("No library in upstream's folder, so the new default applies",
          arguments: [nil, [], [".DS_Store"]] as [[String]?])
    func noLibraryTakesTheNewDefault(contents: [String]?) {
        #expect(!Migrator.v0_6_0.shouldKeepUpstreamGamesFolder(hasChosenInstallFolder: false,
                                                                upstreamFolderContents: contents))
    }
}

// MARK: - The engine's container's name

/**
 Onboarding called the bundled engine's container "Default", and the Containers page showed it
 that way — while the default runtime had become the newest shipped build. Named after its Wine
 now, like every other container, and the one already on disk is renamed once.
 */
@Suite("The engine's container's name")
struct EngineContainerNameRegressionTests {
    @Test("Only the engine's own 'Default' is renamed")
    func onlyTheEnginesDefaultIsRenamed() {
        #expect(Migrator.v0_6_22.shouldRename("Default", runtimeID: nil))
        #expect(!Migrator.v0_6_22.shouldRename("Default", runtimeID: "managed:wine-dxmt-11.16"),
                "a container the person named Default on another build is theirs")
        #expect(!Migrator.v0_6_22.shouldRename("Mythic Engine", runtimeID: nil), "already done")
        #expect(!Migrator.v0_6_22.shouldRename("Steam", runtimeID: nil))
    }
}

// MARK: - The version the app shows

/**
 The update prompt said "You have 0.6+70": `SemanticVersion`'s description prints two parts, so
 0.6.2 and 0.6.20 both read "0.6", and the one number that tells them apart was the one dropped.
 */
@Suite("The version the app shows")
struct ShownVersionRegressionTests {
    @Test("The shown version carries the whole version and the build, the way the prompt names updates")
    func wholeVersionAndBuild() throws {
        let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let build = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)

        #expect(appVersionDescription == "\(version) (\(build))")
        #expect(appVersionDescription.contains(version), "every part of the version, not the first two")
    }
}

// MARK: - Storefront stores

/**
 Each storefront's own store page.

 One view serves every store, so everything that distinguishes them is data on
 `Game.Storefront` — and data is what a test can hold. The fault worth guarding is the one
 that was already live on GOG: a cookie jar that is a fresh `UUID()` per reader, so signing in
 on one page leaves the other asking you to sign in.
 */
@Suite("Storefront stores")
struct StorefrontStoreRegressionTests {
    @Test("Every storefront offered a store row has a page, a name and a cookie jar")
    func storesAreComplete() {
        for storefront in Game.Storefront.withStores {
            #expect(storefront.storeURL != nil, "\(storefront) is offered a store row with no page")
            #expect(storefront.storeName?.isEmpty == false, "\(storefront) has no store name")
            #expect(storefront.webDataStoreIdentifier != nil,
                    "\(storefront)'s store would browse in a different cookie jar from its sign-in window")
        }
    }

    @Test("Epic and GOG are both offered, each under its own name")
    func epicAndGOGBothHaveStores() {
        let names = Game.Storefront.withStores.compactMap(\.storeName)

        #expect(names.contains("Epic Store"))
        #expect(names.contains("GOG Store"))
        #expect(Set(names).count == names.count, "two stores sharing a name is two sidebar rows nobody can tell apart")
    }

    @Test("A store page is HTTPS on the storefront's own domain")
    func storeURLsAreSane() {
        for storefront in Game.Storefront.withStores {
            guard let url = storefront.storeURL else { continue }
            #expect(url.scheme == "https", "\(storefront)'s store is not HTTPS")
            #expect(url.host()?.isEmpty == false)
        }
    }

    @Test("A storefront's cookie jar is the same one every time it is asked")
    func cookieJarIsStable() {
        // The fault, verbatim: `@CodableAppStorage("gogWebDataStore") var … = UUID()` does not
        // write its default back, so each reader evaluated `UUID()` and got its own jar. You
        // signed in through the sign-in window and the store asked you to sign in again.
        #expect(GOG.webDataStoreIdentifier == GOG.webDataStoreIdentifier)
        #expect(Legendary.webDataStoreIdentifier == Legendary.webDataStoreIdentifier)
        #expect(GOG.webDataStoreIdentifier != Legendary.webDataStoreIdentifier,
                "two storefronts sharing one jar would carry one sign-in into the other's pages")
    }

    @Test("A storefront with no store page is never offered one")
    func storefrontsWithoutStores() {
        #expect(Game.Storefront.local.storeURL == nil)
        #expect(!Game.Storefront.withStores.contains(.local))
        #expect(!Game.Storefront.withStores.contains(.steam),
                "Steam is behind Steam.isEnabled, and its store row has to be too")
    }
}
