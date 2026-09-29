//
//  GameOperationManager.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 16/11/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog
import Observation
import UserNotifications
import AppKit
import DockProgress

@Observable @MainActor final class GameOperationManager {
    static var shared: GameOperationManager = .init()
    private let log: Logger = .custom(category: "GameOperationManager")

    // ‼️ operationqueue should NOT be accessed outside, this will always be private
    // cannot name this _queue, swiftui seems to automatically insert _queue for the queue variable
    // avoid naming 'underlyingQueue', this is already a variable
    // swiftlint:disable:next identifier_name
    var _operationQueue: OperationQueue
    /// The operation the interface should show for a game, if any.
    ///
    /// Defined once here because three places were asking the same question of the queue
    /// with the same predicate written out by hand.
    func operation(for game: Game) -> GameOperation? {
        queue.first { $0.game == game && ($0.isExecuting || $0.type.modifiesFiles) }
    }

    /// The launch keeping a game running, if it has one.
    func launchOperation(for game: Game) -> GameOperation? {
        queue.first { $0.game == game && $0.type == .launch }
    }

    /// A game this app launched is now on screen.
    ///
    /// By game id rather than by `Game`, because this is called from the supervision task that
    /// follows the game, and the library replaces its objects on every refresh.
    func noteGameAppeared(forGameID id: Game.ID) {
        queue.first { $0.game.id == id && $0.type == .launch }?.noteGameAppeared()
    }

    // necessitated by deprecation of `OperationQueue.operations`
    internal private(set) var queue: [GameOperation] = .init() {
        didSet { updateDockProgress() }
    }

    /// Tells the Dock when a download starts running — see ``updateDockProgress()``.
    @ObservationIgnored private var executionObservations: [GameOperation.ID: NSKeyValueObservation] = [:]

    private init() {
        let queue: OperationQueue = .init()
        queue.name = "GameOperationManagerQueue"
        queue.maxConcurrentOperationCount = .max
        queue.qualityOfService = .utility
        
        self._operationQueue = queue
    }

    /// Remove what a stopped install had written.
    ///
    /// Every check here fails closed: anything unproven leaves the files alone. Deleting the
    /// wrong folder costs somebody an installed game, while declining to delete costs disk
    /// space and a puzzled look, and those are not the same mistake.
    ///
    /// - Parameters:
    ///   - location: the folder the tool said it was writing into — see ``DownloadDestination``,
    ///     which will only ever name a strict subfolder of the chosen install directory.
    ///   - id: the game, so that one which turns out to be installed after all is left alone.
    nonisolated private static func discardPartialDownload(at location: URL, forGameWithID id: String) async {
        let log: Logger = .custom(category: "GameOperationManager")

        // Gathered first, decided once. Every one of these is a reason *not* to delete, and
        // the rule that weighs them is `mayDiscardPartialDownload` — kept separate, and tested,
        // because this is the only thing in the app that destroys something irreversibly.

        // Waits for the folder to stop changing, not for a process to disappear.
        //
        // The process is the better signal in principle and the worse one in practice:
        // `ChildProcesses` forgets it the moment cancelling returns, and cancelling now returns
        // before the tool has actually gone — deliberately, so the interface does not sit on a
        // download that has already stopped. `Process.interruptThenInsist(within:)` kills it
        // within fifteen seconds regardless, so a folder still changing after thirty is one
        // somebody has started writing to again.
        let folderHasSettled = await nothingIsWriting(to: location)

        // Nobody else's. Between stopping and here the person may have pressed Install again —
        // the most natural next thing to do — and that download writes into this very folder.
        let isClaimed = await MainActor.run {
            shared.queue.contains {
                // By folder *or* by game. The folder is the precise test and the game is the
                // backstop: on the Epic path the destination is only known once legendary has
                // printed it, so a download queued a moment ago has no folder to match yet.
                $0.downloadDestination?.url == location
                    || ($0.game.id == id && $0.type == .install)
            }
        }

        // And not a game that is on disk after all. `.install` does not mean the files were not
        // already there: a library with the game's state wrong offers Install for something
        // already installed, and stopping one in the moment it finished would otherwise delete
        // a complete installation.
        //
        // Asked of the tools rather than of the library, which is the one source that cannot be
        // trusted here — a game filed as uninstalled while `installed.json` has it is precisely
        // the fault that put an Install button on games already on disk, and "the library says
        // it isn't installed" is circular when the library being wrong is the premise. These
        // two files are also what the library's own refresh reads, so they cannot be staler
        // than it is.
        let isInstalled = (try? Legendary.getGameInstallationData(gameID: id)) != nil
            || GOGDL.installRecord(forGameID: id) != nil

        // legendary's record of the download goes *first*, and on the decision to discard rather
        // than on whether the folder is there. The two failures are not alike: files without a
        // record cost a re-download, because legendary with no resume file simply fetches
        // everything again; a record without its files is what ships a truncated game, because
        // legendary trusts that a listed file which exists is finished. So the dangerous half is
        // removed before anything can go wrong with the safe half — a folder already deleted by
        // hand, a `removeItem` that fails halfway on an external disk, or a quit in between all
        // leave files without a record, never the reverse.
        if mayDiscardResumeState(folderHasSettled: folderHasSettled,
                                 isClaimed: isClaimed,
                                 isInstalled: isInstalled) {
            Legendary.discardResumeState(forGameID: id)
        }

        guard mayDiscardPartialDownload(folderHasSettled: folderHasSettled,
                                        isClaimed: isClaimed,
                                        isInstalled: isInstalled,
                                        exists: FileManager.default.fileExists(atPath: location.path)) else {
            log.notice("""
                Leaving the stopped download at \(location.path, privacy: .public) where it is \
                (settled: \(folderHasSettled, privacy: .public), \
                claimed: \(isClaimed, privacy: .public), \
                installed: \(isInstalled, privacy: .public))
                """)
            return
        }

        do {
            try FileManager.default.removeItem(at: location)
            log.notice("Removed the stopped download at \(location.path, privacy: .public)")
        } catch {
            log.error("""
                Couldn't remove the stopped download at \(location.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    /// Whether what a stopped install wrote may be removed.
    ///
    /// Pure, and kept apart from the gathering above, because this is the one decision in the
    /// app that destroys something irreversibly. Every other fault in this area announced
    /// itself — a stuck spinner, a blank size, a modal that would not go away. This one would
    /// delete fifteen gigabytes silently and look correct doing it, so the rule lives somewhere
    /// it can be tested without a manager, a storefront or a disk.
    ///
    /// Every argument is a reason *not* to: only the single all-clear combination returns true.
    ///
    /// - Parameters:
    ///   - folderHasSettled: nothing has written to it for a while. `false` also covers "we
    ///     waited and it was still changing", which is not permission.
    ///   - isClaimed: a live operation is downloading into it, or is an install of the same
    ///     game — the person pressed Install again, which is the natural next thing to do.
    ///   - isInstalled: the tools' own records say the game is on disk. Not the library's: a
    ///     library with the state wrong is what offers Install for a game already installed.
    ///   - exists: there is something there to remove.
    nonisolated static func mayDiscardPartialDownload(folderHasSettled: Bool,
                                                     isClaimed: Bool,
                                                     isInstalled: Bool,
                                                     exists: Bool) -> Bool {
        folderHasSettled && !isClaimed && !isInstalled && exists
    }

    /// Whether anything is still writing where a stopped download was.
    ///
    /// Two questions, and the first is the one that matters: is either tool running at all?
    /// The folder's own modification date is not enough on its own — a download filling files
    /// that already exist never touches it — and that is exactly how a cancelled download's
    /// folder came to be deleted and then immediately recreated: three seconds of quiet inside
    /// a download that had not finished stopping.
    nonisolated private static func nothingIsWriting(to location: URL) async -> Bool {
        // Bounded by what stopping allows: `Process.interruptThenInsist(within:)` has killed
        // the tool and its workers by fifteen seconds, so anything still alive at forty is not
        // going to die on its own.
        let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(40))

        while ChildProcesses.stoppingProcessesRemain {
            guard .now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }

        return await hasSettled(location)
    }

    /// Whether legendary's record of a stopped download may be removed.
    ///
    /// The folder rule without `exists`, deliberately. The record has to go whenever the download
    /// is being discarded, including when its folder has already gone some other way — that is
    /// precisely when a record left behind lists files that are not there, which is what lets a
    /// later attempt skip a half-written file as finished. Where the two rules differ is only
    /// when there is no folder, and then there is nothing for the other rule to remove.
    nonisolated static func mayDiscardResumeState(folderHasSettled: Bool,
                                                 isClaimed: Bool,
                                                 isInstalled: Bool) -> Bool {
        folderHasSettled && !isClaimed && !isInstalled
    }

    /// Whether a folder has stopped changing.
    ///
    /// - Returns: `true` once nothing has changed for `stillness`, and `false` if it is still
    ///   changing when `limit` runs out — never `true` on a timeout, because "I waited long
    ///   enough" is not the same as "nothing is writing here".
    ///
    /// - Important: a folder that does not exist reads as settled — its modification date is
    ///   `nil` every time, and `nil == nil`. That is load-bearing, not an oversight: it is what
    ///   lets a stopped download whose folder was already deleted by hand still have legendary's
    ///   resume record removed, and a record that outlives its files is how a later download
    ///   skips a half-written one as finished. "Hardening" this to return `false` when the folder
    ///   cannot be read would quietly bring that back.
    nonisolated private static func hasSettled(_ url: URL,
                                               for stillness: Duration = .seconds(3),
                                               givingUpAfter limit: Duration = .seconds(30)) async -> Bool {
        func changedAt() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }

        let deadline: ContinuousClock.Instant = .now.advanced(by: limit)
        var last = changedAt()
        var unchangedSince: ContinuousClock.Instant = .now

        while .now < deadline {
            try? await Task.sleep(for: .milliseconds(500))

            let current = changedAt()

            guard current == last else {
                last = current
                unchangedSince = .now
                continue
            }

            if unchangedSince.duration(to: .now) >= stillness { return true }
        }

        return false
    }

    private func removeFromOverlyingQueue(_ operation: GameOperation) {
        executionObservations[operation.id] = nil
        queue.removeAll(where: { $0 == operation })
    }

    func queueOperation(_ operation: GameOperation) {
        // prevent concurrent operations from modifying the same game, potentially causing data races
        for existingOperation in queue where existingOperation.game == operation.game {
            operation.addDependency(existingOperation)
        }
        
        // FIXME: Legendary has a self-managed datalock, so we must queue those operations serially
        if case .epicGames = operation.game.storefront, operation.type.modifiesFiles {
            for existingOperation in queue where existingOperation.game.storefront == .epicGames && existingOperation.type.modifiesFiles {
                operation.addDependency(existingOperation)
            }
        }
        
        let originalCompletionBlock = operation.completionBlock
        operation.completionBlock = { [self] in
            // run code that was already in the completion block
            originalCompletionBlock?()
            
            // remove operation from `queue` on operation completion,
            // this ensures `queue` is always mirroring `operationQueue`.
            Task { await removeFromOverlyingQueue(operation) }

            if operation.discardsDownloadWhenStopped, let location = operation.downloadDestination?.url {
                let id = operation.game.id
                Task.detached(priority: .utility) {
                    await Self.discardPartialDownload(at: location, forGameWithID: id)
                }
            }

            // present any unhandled errors within the operation to the ui.
            Task { @MainActor in
                guard let error = operation.error else { return }

                // Nobody asked for this one. An install resumed at startup that fails is worth
                // a line in the log and another attempt next time — not a modal in front of
                // somebody who has just opened the app, which is what an orphaned download
                // holding legendary's lock produced.
                guard !operation.isAutomatic else {
                    self.log.error("""
                        \(operation.debugDescription, privacy: .public) failed: \
                        \(error.localizedDescription, privacy: .public)
                        """)
                    return
                }

                let alert = NSAlert()
                alert.messageText = String(localized: "Unable to complete operation [\(operation.description)].")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: String(localized: "OK"))

                // This used to be `NSApp.windows.first`, and that is how a failed launch
                // became "nothing happens". `windows.first` is whatever window happens to be
                // first — the About panel, or a Settings window the user had dragged onto
                // another display — and worse, a window can host only one sheet: attach an
                // alert to a window that already has one and it waits, invisibly, for the
                // first to be dismissed. Which it may never be.
                //
                // So: the window the user is actually looking at, and only if it is free.
                // Otherwise a plain modal, which cannot be hidden behind anything.
                let candidate = NSApp.keyWindow ?? NSApp.mainWindow

                if let window = candidate, window.attachedSheet == nil, window.isVisible {
                    alert.beginSheetModal(for: window)
                } else {
                    NSApp.activate()
                    alert.runModal()
                }
            }

            // An install that finished is not one to pick up next time. Cancelled ones keep
            // their note: quitting cancels, and that is the case this exists for.
            if operation.type == .install, !operation.isCancelled, operation.error == nil {
                Task { @MainActor in PendingInstalls.forget(gameID: operation.game.id) }
            }

            // display completion notification to user
            Task {
                // ensure operation actually completed
                guard operation.type.modifiesFiles else { return }
                guard !operation.isCancelled else { return }

                // And succeeded. Without this a failed download announced "is now ready" right
                // beside the alert saying it had failed.
                guard operation.error == nil else { return }
                
                let notificationContent: UNMutableNotificationContent = .init()
                notificationContent.title = String(localized: "Operation complete.")
                notificationContent.body = String(localized: "\(operation.game.description) is now ready.")
                notificationContent.interruptionLevel = .active

                let notificationRequest: UNNotificationRequest = .init(
                    identifier: "GameOperationCompletion_\(operation.id)",
                    content: notificationContent,
                    trigger: nil
                )

                do {
                    try await UNUserNotificationCenter.current().add(notificationRequest)
                } catch {
                    log.error("Unable to send notification for operation completion: \(error.localizedDescription)")
                }
            }
            
            // FIXME: dirtyfix: refresh from storefronts after installation to update instances
            // FIXME: of this operation's associated game with its new installation values,
            // FIXME: since GameDataStore.refreshFromStorefronts is needed to re-sync file status
            // to fix this, legendary's JSONs must be monitored using an API like FSEvents.
            // but this is way simpler rofl
            if case .epicGames = operation.game.storefront, operation.type.modifiesFiles {
                Task(priority: .utility, operation: { try? await GameDataStore.shared.refreshFromStorefronts(.epicGames) })
            }
            
            log.debug("Operation \(operation.debugDescription) complete.")
        }

        // Registered before it is queued, so the start cannot be missed. An operation starts
        // whenever its turn comes — once what it waits on is done, on the queue's own thread —
        // and nothing about the queue changes when it does; the Dock follows the one running.
        if operation.type.modifiesFiles {
            executionObservations[operation.id] = operation.observe(\.isExecuting) { @Sendable _, _ in
                Task { @MainActor in GameOperationManager.shared.updateDockProgress() }
            }
        }

        _operationQueue.addOperation(operation)
        queue.append(operation)

        log.debug("Queued operation \(operation.debugDescription)\(operation.dependencies.isEmpty ? "." : "with dependencies \(operation.dependencies.map(\.description).formatted(.list(type: .and)))")")
    }

    /// Stop an operation because the person asked for it.
    ///
    /// Distinct from ``stopFileOperationsForQuit()``: an install the person stops is not
    /// resumed the next time the app opens, and an install stopped by quitting is. Every Stop
    /// control in the interface comes through here so that difference is stated in one place.
    func cancel(_ operation: GameOperation) {
        if operation.type == .install {
            PendingInstalls.forget(gameID: operation.game.id)

            // And take the bytes with it. Forgetting the note without removing what it had
            // already written left a partial download nobody would ever resume — sitting in
            // the folder the next install goes into, and counted against the free-space check
            // that then refuses it. Only for `.install`: an update or a repair is writing into
            // a game that is already there.
            operation.discardsDownloadWhenStopped = true
        }

        // Said the moment it is pressed. A launch takes about a second longer to be gone — it
        // makes sure of the kill before it ends — and until then its status is the only answer
        // the person gets to having pressed the button.
        if operation.type == .launch {
            operation.isForceQuitting = true
        }

        operation.cancel()

        // Its progress too. DockProgress queues every change it hears of and drops one from a
        // cancelled progress when it gets to it; without this, a change heard just before Stop
        // landed after the badge had come down, and put the stopped download's ring back.
        operation.progressKVOBridge._progress.cancel()

        // Now, rather than when the operation finally ends: that waits for the tool to stop,
        // which takes seconds, and a badge still counting a download somebody has just
        // stopped is what this was reported as.
        updateDockProgress()
    }

    /// Stop everything that is writing to disk, and wait for it to stop. Running games are
    /// left alone.
    ///
    /// Two faults in one. Quitting used to cancel *every* operation, which now includes the
    /// launches that keep a running game in the queue — so closing the launcher would have
    /// force-quit the game being played, a decision that belongs to the "Force quit all games
    /// when \(Branding.name) closes" setting and to nothing else. And it cancelled without
    /// waiting: `legendary` and `gogdl` write their resume state when interrupted, and an app
    /// that terminates the instant it asks them to leaves that unwritten — which is a download
    /// that starts again from nothing.
    ///
    /// Bounded, because quitting has to happen.
    func stopFileOperationsForQuit() async {
        let stopping = queue.filter { $0.type.modifiesFiles }

        if !stopping.isEmpty {
            // `GameOperation.cancel()` directly, not `cancel(_:)` — deliberately. Going
        // through the manager would mark these installs as stopped by hand, which forgets
        // their notes *and* deletes what they have downloaded. Quitting promises the opposite:
        // the alert says they pick up where they left off, so every byte has to stay.
        log.debug("Stopping \(stopping.count) file operation(s) before quitting.")
            stopping.forEach { $0.cancel() }
            updateDockProgress()

            let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(8))
            while .now < deadline, queue.contains(where: { stopping.contains($0) }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        // And make sure — whether or not there was an operation. A download still shutting down
        // when the app terminates carries on without it, downloading where nobody can see it and
        // holding legendary's installed-games lock against the next launch. This used to sit
        // behind an early return for an empty queue, which meant it never saw the processes the
        // app starts for itself: its housekeeping and its cloud saves are not operations, and
        // those were exactly the ones left behind. See `ChildProcesses`.
        await ChildProcesses.stopSurvivors()
    }

    // MARK: - The Dock icon

    /// Which download the Dock icon's badge follows, and how many it counts — or `nil` when
    /// nothing is writing to disk, which is when the badge has to come down.
    ///
    /// A stopped download stops counting the moment it is stopped, not when it finally ends:
    /// ending waits for the tool, which takes seconds.
    ///
    /// The ring follows a download — an install, an update or a repair — before anything else,
    /// because nothing else reports progress: an uninstall or a move leaves its progress at
    /// nothing, and following one hid the ring of a download running beside it. The download
    /// running comes first and, failing that, the first one waiting, so the badge is already on
    /// it when it starts.
    ///
    /// Pure, like ``mayDiscardPartialDownload(folderHasSettled:isClaimed:isInstalled:exists:)``,
    /// so the rule can be tested without a queue or a Dock.
    nonisolated static func dockBadge(for operations: [GameOperation]) -> (following: GameOperation, count: Int)? {
        let counted = operations.filter { $0.type.modifiesFiles && !$0.isCancelled && !$0.isFinished }
        let downloads = counted.filter { [.install, .update, .repair].contains($0.type) }

        guard let following = downloads.first(where: { $0.isExecuting }) ?? downloads.first ?? counted.first else {
            return nil
        }
        return (following, counted.count)
    }

    /// Points the Dock icon's badge at the download that is running, or takes it down.
    ///
    /// Taking it down is the half that was missing. DockProgress draws the badge while the
    /// progress it follows is under way, and redraws only when that progress changes. A
    /// stopped download's never changes again, so its last frame — ring and count — stayed on
    /// the icon until the app quit: nothing ever told the Dock the download had gone.
    ///
    /// Asked again whenever the answer can change: the queue changing, a download starting,
    /// and a Stop.
    private func updateDockProgress() {
        guard let badge = Self.dockBadge(for: queue) else {
            guard DockProgress.progressInstance != nil || DockProgress.progress != 0 else { return }

            DockProgress.progressInstance = nil
            DockProgress.resetProgress()
            return
        }

        DockProgress.style = .badge(color: .accentColor, badgeValue: { Self.dockBadge(for: self.queue)?.count ?? 0 })

        let followed = badge.following.progressKVOBridge._progress
        guard DockProgress.progressInstance !== followed else { return }

        DockProgress.progressInstance = followed
        // DockProgress hears only of changes from here on, so it starts from where this
        // download already is rather than from wherever the last one stopped.
        DockProgress.progress = followed.fractionCompleted
    }
}
