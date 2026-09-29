//
//  SparkleUpdateController.swift
//  Mythic
//
//  Created by Josh on 11/14/24.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Combine
import Sparkle
import OSLog

final class SparkleUpdateController: NSObject, SPUUserDriver, ObservableObject {
    @MainActor static let shared: SparkleUpdateController = .init()

    private let log: Logger = .custom(category: "SparkleUpdaterController")

    private var sparkleUpdater: SPUUpdater?

    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var userInitiatedCheck: Bool = false

    /// The version somebody answered "Later" to, for the sidebar's reminder.
    ///
    /// Not the `updateAvailable` state itself: the Sparkle session that offered it ended when
    /// they answered, and its reply can't be given twice. The reminder starts a fresh check.
    @Published private(set) var postponedVersion: String?

    /// "Update and Restart" was chosen, so the restart it promised needs no second question.
    private var restartWhenReady: Bool = false

    override init() {
        super.init()

        // No feed, no updater — and that is a decision rather than an oversight.
        //
        // `SUFeedURL` pointed at upstream Mythic's appcast, and `SUPublicEDKey` at upstream's
        // update-signing key. Shipping either would have meant this application quietly
        // replacing itself with a different one, signed by someone else, on the first update
        // check. Both are this project's own now — the feed is `appcast.xml` in its repository
        // — and ``Branding/appcastURL`` is still the switch.
        guard Branding.appcastURL != nil else {
            log.notice("No appcast configured; automatic updates are off.")
            return
        }

        // And no key, no updater. Sparkle checks every update against `SUPublicEDKey` before
        // it will install anything, so without one an update can only fail — in front of
        // somebody, after they agreed to it.
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            log.notice("No update-signing key (SUPublicEDKey) in Info.plist; automatic updates are off.")
            return
        }

        let updater: SPUUpdater = .init(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: self,
            delegate: nil
        )
        self.sparkleUpdater = updater

        // Sparkle's own schedule stays off, and nothing downloads until somebody says so: the
        // check is the one below, and what it finds is a question, not an install.
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false

        do {
            try updater.start()
        } catch {
            log.error("Sparkle failed to start: \(error.localizedDescription).")
            return
        }

#if !DEBUG
        // Once, at launch, and never on a timer: a question that arrives in the middle of a game
        // is a question in the wrong place. A few seconds in, so there is a window to ask it
        // over. Release builds only — a Debug build offered a release would replace itself
        // with it, in DerivedData, under the developer's feet.
        Task { @MainActor in
            guard !AppDelegate.isRunningTests else { return }

            try? await Task.sleep(for: .seconds(3))
            SparkleUpdateController.shared.checkForUpdates(userInitiated: false)
        }
#endif
    }

    /// Onboarding is on screen — the one time an update waits in the sidebar instead of asking.
    ///
    /// Read the way `@AppStorage` reads it: the key is only written once onboarding ends, and
    /// `bool(forKey:)` answers `false` for a missing key — "finished" — on the one launch it is
    /// certainly showing.
    private var isOnboardingOnScreen: Bool {
        UserDefaults.standard.object(forKey: "isOnboardingPresented") as? Bool ?? true
    }

    /// This build can't update itself: no feed, or no key to check an update against.
    struct UpdatesUnavailableError: LocalizedError {
        var errorDescription: String? {
            String(localized: "This copy of PorTalistic can't update itself.")
        }

        var recoverySuggestion: String? {
            String(localized: "Download the latest version from PorTalistic's releases on GitHub.")
        }
    }

    func clearState() -> Bool {
        switch state {
        case .idle:
            return true
        case .checkingForUpdates(let cancel):
            cancel()
        case .updateAvailable(let choice, _):
            choice(.dismiss)
        case .noUpdateAvailable(let acknowledge):
            acknowledge()
        case .downloadingUpdate(let cancel, _):
            cancel()
        case .extractingUpdate:
            return false
        case .initializingUpdate:
            return false
        case .readyToRelaunch(let acknowledge):
            acknowledge(.dismiss)
        case .installingUpdate:
            return false
        case .error(let acknowledge, _):
            acknowledge()
        }

        return true
    }

    func checkForUpdates(userInitiated: Bool = false) {
        guard let updater = sparkleUpdater else {
            // "Check for Updates…" used to do nothing at all here, which reads as broken.
            log.notice("Update check asked for, but this build has no updater.")
            if userInitiated {
                userInitiatedCheck = true
                state = .error(acknowledge: { self.state = .idle }, error: UpdatesUnavailableError())
            }
            return
        }

        guard !updater.sessionInProgress else {
            log.info("\(userInitiated ? "User-initiated" : "Automatic") update check ignored due to in-progress update session.")
            if userInitiated {
                userInitiatedCheck = true
            }
            return
        }

        log.info("\(userInitiated ? "User-initiated" : "Automatic") update check initiated...")
        _ = clearState()

        // After `clearState()`, which answers an open offer with "Later" and so sets this.
        postponedVersion = nil
        restartWhenReady = false
        userInitiatedCheck = userInitiated
        updater.checkForUpdates()
    }

    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        log.debug("Update permission request received.")
        return .init(
            automaticUpdateChecks: false,
            sendSystemProfile: false
        )
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        log.debug("Update check initiated.")
        state = .checkingForUpdates {
            cancellation()
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log.notice("Update found: \(appcastItem.displayVersionString.isEmpty ? "unknown" : appcastItem.displayVersionString, privacy: .public).")

        postponedVersion = nil

        self.state = .updateAvailable(choice: { choice in
            switch choice {
            case .update:
                self.restartWhenReady = true
                reply(.install)
                self.state = .initializingUpdate
            case .dismiss:
                reply(.dismiss)
                self.postponedVersion = appcastItem.displayVersionString
                self.state = .idle
            }
        }, appcast: appcastItem)

        // Always a question — at launch just as from the menu. This used to install without
        // asking whenever the check was the automatic one, which is exactly the check nobody
        // is watching. Onboarding is the one time it waits: the offer stays in the sidebar for
        // when the app is properly open. After the state, so the sheet opens on the offer.
        if !isOnboardingOnScreen {
            userInitiatedCheck = true
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        log.debug("Release notes received.")
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        log.error("Failed to download release notes: \(error.localizedDescription).")

        if !userInitiatedCheck {
            self.state = .idle
            return
        }

        state = .error(acknowledge: {
            self.state = .idle
        }, error: error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.info("No update available.")

        if !userInitiatedCheck {
            acknowledgement()
            self.state = .idle
            return
        }

        state = .noUpdateAvailable(acknowledge: {
            acknowledgement()
            self.state = .idle
        })
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.error("Updater error: \(error.localizedDescription).")

        if !userInitiatedCheck {
            acknowledgement()
            self.state = .idle
            return
        }

        state = .error(acknowledge: {
            acknowledgement()
            self.state = .idle
        }, error: error)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        log.debug("Update download initiated.")
        state = .downloadingUpdate(cancel: {
            cancellation()
            self.state = .idle
        }, progress: .init(started: .init(), total: 0, completed: 0))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case .downloadingUpdate(let cancel, var progress) = state else { return }

        progress.total = expectedContentLength
        state = .downloadingUpdate(cancel: cancel, progress: progress)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case .downloadingUpdate(let cancel, var progress) = state else { return }

        progress.completed += length
        state = .downloadingUpdate(cancel: cancel, progress: progress)
    }

    func showDownloadDidStartExtractingUpdate() {
        log.debug("Update download complete; extracting...")
        state = .extractingUpdate(progress: .init(started: .init(), progress: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        guard case .extractingUpdate(let currentProgress) = state else { return }

        state = .extractingUpdate(progress: .init(started: currentProgress.started, progress: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log.notice("Update ready to install.")

        // "Update and Restart" has already answered this. Asking "Relaunch now?" after it is a
        // second question with one sensible answer, put to somebody who has just given it.
        if restartWhenReady {
            restartWhenReady = false
            state = .installingUpdate
            reply(.install)
            return
        }

        state = .readyToRelaunch { choice in
            switch choice {
            case .update:
                reply(.install)
                self.state = .installingUpdate
            case .dismiss:
                reply(.dismiss)
                self.state = .idle
            }
        }

        // Reached without that answer only for an update Sparkle had already downloaded — one
        // left waiting by "Update on Close" in a session that never closed properly.
        if !isOnboardingOnScreen {
            userInitiatedCheck = true
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        log.debug("Update installing...")
        state = .installingUpdate
        if !applicationTerminated {
            retryTerminatingApplication()
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {  }

    func dismissUpdateInstallation() {
        guard userInitiatedCheck else {
            self.state = .idle
            return
        }

        if case .checkingForUpdates = state {
            state = .noUpdateAvailable {
                self.state = .idle
            }
        }
    }
}

extension SparkleUpdateController {
    enum UpdateChoice {
        case update
        case dismiss
    }

    struct DownloadProgress {
        let started: Date
        var total: UInt64
        var completed: UInt64
    }

    struct ExtractProgress {
        let started: Date
        var progress: Double
    }

    enum UpdateState {
        var stateType: Int {
            switch self {
            case .idle: return 0
            case .checkingForUpdates: return 1
            case .updateAvailable: return 2
            case .noUpdateAvailable: return 3
            case .initializingUpdate: return 4
            case .downloadingUpdate: return 5
            case .extractingUpdate: return 6
            case .readyToRelaunch: return 7
            case .installingUpdate: return 8
            case .error: return 9
            }
        }

        case idle
        case checkingForUpdates(cancel: () -> Void)
        case updateAvailable(choice: (UpdateChoice) -> Void, appcast: SUAppcastItem)
        case noUpdateAvailable(acknowledge: () -> Void)
        case initializingUpdate
        case downloadingUpdate(cancel: () -> Void, progress: DownloadProgress)
        case extractingUpdate(progress: ExtractProgress)
        case readyToRelaunch(acknowledge: (UpdateChoice) -> Void)
        case installingUpdate
        case error(acknowledge: () -> Void, error: Error)
    }
}
