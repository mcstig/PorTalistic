//
//  AppDelegate.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 25/2/2024.
//

// Copyright © 2023-2025 vapidinfinity

import OSLog

import SemanticVersion
import SwiftUI
import SwordRPC
import UserNotifications

import Firebase
import FirebaseCore
import FirebaseCrashlytics

// TODO: modularise
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Whether this process was started to run tests rather than to be used.
    ///
    /// A unit test bundle is hosted by the app, so `xcodebuild test` launches PorTalistic and
    /// loads the tests into it. Without this, everything below would run against the real
    /// machine on every ⌘U: the migrator moves folders, the provisioner starts installing
    /// runtimes, `refreshFromStorefronts()` talks to Epic and GOG, and the library gets
    /// rewritten in `UserDefaults`. A test suite that edits the thing it is testing is worse
    /// than no test suite. Tests get the app's code; they don't get its side effects.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard !Self.isRunningTests else { return }

        // First, before anything derives a path from the app's name or identifier.
        //
        // Both of the app's data locations are derived rather than chosen — application
        // support from `CFBundleDisplayName`, the container folder and `UserDefaults` from the
        // bundle identifier — so the rebrand moved all of it, and this is what follows it
        // across. It used to run *after* `refreshFromStorefronts()`, which reads Epic's and
        // GOG's configuration out of application support: harmless while the app's name never
        // changed, and fatal the moment it did.
        Migrator.fullMigration()

        // The runtime catalogue and the per-game compatibility list, before anything can want
        // them. Cached copy applied synchronously; the refresh happens on its own.
        CompatibilityManifest.bootstrap()

        // Keep the machine ready without anyone being asked to install anything. Does nothing
        // while operations are in flight, so this is safe to fire at launch.
        Task { @MainActor in
            Provisioner.shared.start()
        }

        // Force Quit, the Dock and ⌘-Tab list a Windows program under the name the engine gives
        // it, and the engine gives it upstream's: `BioshockHD.exe (Mythic)`. This renames them
        // once they have a window. See `Wine.ApplicationNaming`.
        Task { @MainActor in
            Wine.ApplicationNaming.shared.start()
        }

        // MARK: Firebase Configuration
        // Only when the bundled configuration actually belongs to this app. Upstream's
        // `GoogleService-Info.plist` is still here and names upstream's project, so
        // configuring against it would send this fork's crash reports and analytics into
        // someone else's Firebase. See ``Branding/hasOwnFirebaseConfiguration``.
        if Branding.hasOwnFirebaseConfiguration {
            FirebaseApp.configure()
            FirebaseConfiguration.shared.setLoggerLevel(.min)
        }

        setenv("CX_ROOT", Bundle.main.bundlePath, 1)

        // Before anything launches a wine process: children inherit this, and msync spends
        // a file descriptor per Win32 sync object. See `ResourceLimits`.
        ResourceLimits.raiseOpenFileLimit()

        // MARK: Register Defaults
        UserDefaults.standard.register(defaults: [
            "discordRPC": true,
            "engineAutomaticallyChecksForUpdates": true,
            "quitOnAppClose": false,
            // FIXME: dangerous but necessary force-unwrap
            // FIXME: very rarely, some users may not have write access to appGames.
            // FIXME: e.g. MGM cases
            "installBaseURL": Bundle.appGames!
        ])

        Task {
            // Whatever the last session left running. An orphaned legendary keeps downloading
            // where nothing can see it and keeps its installed-games lock, which is how an
            // install resumed here was refused outright — in a modal, at startup. See
            // `ChildProcesses.stopOrphans(of:within:)`.
            //
            // Beside the library rather than in front of it: stopping something that refuses to
            // stop takes a while, and the first screen has no reason to wait for it. The resume
            // does wait, because that is the one that would land on the lock.
            async let orphansStopped: Int = ChildProcesses.stopOrphans(
                of: [Legendary.legendaryExecutableURL, GOGDL.executableURL].compactMap { $0 }
            )

            try? await GameDataStore.shared.refreshFromStorefronts()
            _ = await orphansStopped

            // Anything that was downloading when the app last closed, started again and shown
            // — after the library, because an install is queued against a game and there are
            // none before this. See `PendingInstalls`.
            await PendingInstalls.resumeInterrupted()

            // Last, and only if the line above queued nothing: legendary's housekeeping deletes
            // the file that makes resuming possible, so it may not run in front of a download
            // that is counting on it.
            await Legendary.cleanUpStaleData()
        }

        // MARK: Start metadata update cycle for Legendary
        Task(priority: .utility) {
            while true {
                await Legendary.updateMetadata()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }

        // MARK: Autosync Legendary cloud saves
        Task(priority: .utility) {
            await Legendary.synchroniseCloudSaves()
        }

        // MARK: DiscordRPC Delegate Ininitialisation & Connection
        discordRPC.delegate = self
        if UserDefaults.standard.bool(forKey: "discordRPC"), discordRPC.isDiscordInstalled {
            _ = discordRPC.connect()
        }

        // MARK: Applications folder disclaimer
#if !DEBUG
        if !Bundle.main.bundleURL.pathComponents.contains("Applications") {
            let alert = NSAlert()
            alert.messageText = String(localized: "\(Branding.name) has detected it's running outside of the applications folder.")
            alert.informativeText = String(localized: "It's recommended to move \(Branding.name) into the Applications folder on your device.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "OK"))

            if let window = NSApp.windows.first {
                alert.beginSheetModal(for: window)
            }
        }
#endif // !DEBUG

        // MARK: Notification Authorisation Request and Delegation Setting
        UNUserNotificationCenter.current().delegate = self
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus != .authorized else { return }

            do {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                Logger.app.error("Unable to request notification authorization: \(error)")
            }
        }

        // MARK: Engine update alert chain
        // TODO: add manual engine update check button in toolbar
        Task(priority: .background) { @MainActor in
            guard UserDefaults.standard.bool(forKey: "engineAutomaticallyChecksForUpdates") else { return }

            await Engine.displayUpdateChecker(userInitiated: false)
        }

        // MARK: Version-specific app launch counter
        if let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            var launchCountDictionary = UserDefaults.standard.dictionary(forKey: "launchCount") as? [String: Int] ?? .init()
            launchCountDictionary[shortVersion, default: 0] += 1
            UserDefaults.standard.set(launchCountDictionary, forKey: "launchCount")
        }
    }

    func applicationDidBecomeActive(_: Notification) {
        _ = discordRPC.connect()
    }

    func applicationDidResignActive(_: Notification) {
        discordRPC.disconnect()
    }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard GameOperationManager.shared.queue.contains(where: { $0.type.modifiesFiles }) else {
            // Nothing worth asking about — but not necessarily nothing running. The app starts
            // `legendary` for its own errands, and those are not operations, so an empty queue
            // used to quit straight past them and leave one behind. No alert: the person is not
            // being asked to make a decision about the app's own housekeeping, only waited for.
            guard ChildProcesses.hasLiveProcesses else { return .terminateNow }

            Self.finishTerminating(sender, quitting: true)
            return .terminateLater
        }

        let alert: NSAlert = .init()
        
        alert.messageText = String(localized: "Are you sure you want to quit?")
        alert.informativeText = String(localized: "\(Branding.name) is still operating on games. Downloads will stop, and pick up where they left off the next time you open \(Branding.name).")
        alert.alertStyle = .warning
        
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        // The window the person is looking at, and only if it is free to show a sheet — the
        // same rule as the operation-failure alert, for the same reason: a window hosts one
        // sheet, and a second waits invisibly behind the first. It matters more here, because
        // the reply below is the only thing that ends the quit: attached to a busy window, or
        // to `windows.first` when there are no windows at all, ⌘Q hung for good with the
        // downloads still running.
        let window = (NSApp.keyWindow ?? NSApp.mainWindow)
            .flatMap { $0.attachedSheet == nil && $0.isVisible ? $0 : nil }

        if let window {
            alert.beginSheetModal(for: window) { response in
                Self.finishTerminating(sender, quitting: response == .alertFirstButtonReturn)
            }
        } else {
            NSApp.activate()
            Self.finishTerminating(sender, quitting: alert.runModal() == .alertFirstButtonReturn)
        }

        return .terminateLater
    }

    /// Stop the downloads, then let the quit through.
    ///
    /// Quitting waits for the downloads it stops: `legendary` and `gogdl` write their resume
    /// state when they are interrupted, and terminating the instant they are asked to leaves
    /// that unwritten — a download that would start again from nothing next time.
    ///
    /// Always asynchronous, including the "no, don't quit" answer: replying before
    /// `applicationShouldTerminate` has returned `.terminateLater` is not a thing AppKit
    /// promises anything about.
    @MainActor private static func finishTerminating(_ sender: NSApplication, quitting: Bool) {
        Task { @MainActor in
            if quitting {
                await GameOperationManager.shared.stopFileOperationsForQuit()
            }

            sender.reply(toApplicationShouldTerminate: quitting)
        }
    }

    @MainActor
    func applicationWillTerminate(_: Notification) {
        if UserDefaults.standard.bool(forKey: "quitOnAppClose") {
            try? Wine.killAll()
        }

        // Downloads are stopped in `applicationShouldTerminate`, where there is still time to
        // wait for them to write down where they got to. Nothing is cancelled here: the queue
        // now holds a launch for as long as its game is running, and cancelling one of those
        // kills the game — which is `quitOnAppClose`'s decision, taken above, and nobody
        // else's.
        //
        // legendary's housekeeping used to run here, from a detached task that was started and
        // never waited for. It deleted legendary's temporary files — including the `.resume`
        // that `applicationShouldTerminate` had just stopped the download in order to write —
        // so an install picked back up at the next launch downloaded the whole game again. It
        // now runs at launch, once the library is refreshed and only when no download would be
        // sacrificed to it. See `Legendary.cleanUpStaleData()`.
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show a notification even when this app is the one in front.
    ///
    /// Without this, macOS silently drops every notification posted while the app is frontmost
    /// — and frontmost is exactly where it is at the moment that matters. A game exits, the
    /// front comes back here, and the post-mortem then says what it found: that a download has
    /// finished, that it changed a configuration for the next run, or that it has tried
    /// everything it knows and is out of ideas. All of it went nowhere. The delegate was set
    /// and left empty, so the feature looked implemented from every side except the one the
    /// person is on.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // No sound. Every one of these arrives just after something finished — a download, a
        // game — and a noise for each would be the app talking over the thing the person went
        // back to.
        [.banner, .list]
    }
}

extension AppDelegate: SwordRPCDelegate {
    func swordRPCDidConnect(_ rpc: SwordRPC) {
        rpc.setPresence({
            var presence: RichPresence = .init()
            presence.details = "Idling in \(Branding.name)"
            presence.state = "Idle"
            presence.timestamps.start = .now
            presence.assets.largeImage = "macos_512x512_2x"

            return presence
        }())
    }
}
