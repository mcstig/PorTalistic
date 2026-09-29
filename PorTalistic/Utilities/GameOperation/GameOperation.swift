//
//  GameOperation.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 17/11/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

@Observable final class GameOperation: Operation, Identifiable, @unchecked Sendable {
    private let log: Logger = .custom(category: "GameOperation")

    let id: UUID = .init()
    let game: Game
    let type: ActiveOperationType
    private let _progress: Progress
    private(set) var progressKVOBridge: ProgressKVOBridge

    /// The underlying code that is run when the operation's conditions to run are met.
    /// - Parameter #1: the mutable `Progress` instance, which should be updated as the operation's function progresses in — well — progress.
    /// - Note: This function is called within a `Task`, which is cancellable by the user.
    /// - Note: To best handle task cancellation, use `withTaskCancellationHandler` within the closure.
    let function: (Progress) async throws -> Void

    var error: Error?

    /// Whether the app started this itself rather than being asked to.
    ///
    /// An install resumed at launch is the only one so far. It matters because a failure nobody
    /// asked for should not arrive as a modal — see `GameOperationManager.queueOperation(_:)`.
    var isAutomatic: Bool = false

    /// Where this operation's download is landing, once whoever is running it says so.
    ///
    /// A box rather than a plain property because the value is discovered *inside* the
    /// operation's own closure, which is written before the operation exists.
    var downloadDestination: DownloadDestination?

    /// Whether stopping this operation should take its partial download with it.
    ///
    /// Set only when a person stops an install — see ``GameOperationManager/cancel(_:)``. An
    /// install stopped by quitting is resumed on the next launch and must keep every byte it
    /// has; one stopped by hand is deliberately forgotten, so what it wrote is dead weight that
    /// nobody will ever resume. It was being left on disk with nothing in the interface to say
    /// it existed: fifteen gigabytes for one game, six for another, sitting in the folder the
    /// next install would have gone into and counting against the free-space check.
    var discardsDownloadWhenStopped: Bool = false

    /// For a `.launch`: whether the game has actually appeared yet.
    ///
    /// A launch used to be over the moment the process this app started returned, and on the
    /// Epic path that process is `legendary`, which hands the game to Wine and exits seconds
    /// after Play while the game is still loading. Everything shown about a running game came
    /// from that, so the spinner was a six-second guess and Play went live again underneath a
    /// game that was up. `Wine.superviseGame` is what moves this on, and the operation now
    /// lives as long as the game does.
    private(set) var launchPhase: LaunchPhase = .preparing

    /// What this launch is the first to run with, in the person's words.
    ///
    /// Set from the journal when the launch begins: it is what the recovery loop decided after
    /// the *previous* launch, and this is the one that applies it. `nil` when nothing was
    /// decided, which is almost every launch — a game that works is never reconfigured.
    var pendingConfigurationChange: String?

    /// Force Quit has been pressed on this launch, and it is making sure of it.
    ///
    /// For the second between the button and the operation being gone — the prefix is cleared
    /// twice, a second apart, see `Wine.forceQuit(containerAt:)` — so that what the page says is
    /// what is happening. Before, it went on saying "Starting", which is exactly what somebody
    /// who has just pressed Force Quit on a game that won't finish starting doesn't want to read.
    var isForceQuitting: Bool = false

    /// Whether this launch is, at this moment, putting a new configuration in place.
    ///
    /// Both halves matter. There has to be something to apply — almost no launch has one, since
    /// a game that works is never reconfigured — and it has to still be being applied: once the
    /// game is on its way, what was new about the configuration is simply what the game runs
    /// with. Here rather than in the view it is drawn in, so that it can be tested and so the
    /// two `note…` methods below sit next to the thing that reads them.
    var isApplyingConfiguration: Bool {
        type == .launch && launchPhase == .preparing && pendingConfigurationChange != nil && !isForceQuitting
    }

    /// The container is ready and the game is being started.
    @MainActor func noteConfigurationApplied() {
        guard type == .launch, launchPhase == .preparing else { return }
        launchPhase = .starting
    }

    /// The game exists now.
    @MainActor func noteGameAppeared() {
        guard type == .launch, launchPhase != .running else { return }
        launchPhase = .running
    }

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Held while ``task`` is recorded and while it is looked for — see ``start()``.
    private let taskLock: NSLock = .init()

    init(game: Game,
         type: ActiveOperationType,
         progress: Progress = .init(),
         function: @escaping (Progress) async throws -> Void) {
        self.game = game
        self.type = type
        self._progress = progress
        self.progressKVOBridge = .init(progress: progress)
        self.function = function

        // initialise `Operation`
        super.init()
    }
    
    // MARK: `Operation` inheritance overrides
    override func start() {
        guard !isCancelled else {
            log.notice("Operation \(self.debugDescription) has been cancelled before commencing.")
            isFinished = true; return
        }
        
        let task = Task(priority: .utility) {
            defer {
                isExecuting = false
                isFinished = true
            }
            
            do {
                isExecuting = true
                try Task.checkCancellation()
                try await function(_progress)
            } catch is CancellationError {
                log.notice("Operation \(self.debugDescription) was cancelled.")
            } catch let error where Task.isCancelled || self.isCancelled {
                // Stopped, and what it threw on the way out is the stopping, not a failure. Not
                // every step ends in a `CancellationError` when its task is cancelled: a launch
                // force-quit while its runtime was downloading throws `URLError(.cancelled)`, and
                // one force-quit while `legendary` was signing in could find an ERROR line in what
                // it had written so far. Either would come up as an alert saying the launch had
                // failed — for a button the person had pressed a moment before.
                log.notice("Operation \(self.debugDescription) was cancelled: \(error.localizedDescription)")
            } catch {
                self.error = error
                log.error("Error occurred in operation \(self.debugDescription): \(error.localizedDescription).")
            }
        }

        // A cancel that arrived between the check at the top and here found no task to cancel,
        // and only flagged the operation — so the function ran anyway, with nothing inside it
        // able to tell, and a Force Quit pressed the instant a launch was queued started the game
        // regardless.
        // Recorded and checked under one lock, with `cancel()` flagging first and looking second,
        // so whichever of the two comes second sees the other.
        let cancelledMeanwhile = taskLock.withLock {
            self.task = task
            return isCancelled
        }

        if cancelledMeanwhile { task.cancel() }
    }
    
    override func cancel() {
        // Flagged before the task is looked for, not after: see the end of `start()`.
        super.cancel()
        taskLock.withLock { task }?.cancel()
    }
    
    override var isAsynchronous: Bool { true }

    private var _isExecuting = false
    override private(set) var isExecuting: Bool {
        get { _isExecuting }
        set { // + KVO awareness, to spec
            willChangeValue(for: \.isExecuting)
            _isExecuting = newValue
            didChangeValue(for: \.isExecuting)
        }
    }

    private var _isFinished = false
    override private(set) var isFinished: Bool {
        get { _isFinished }
        set { // + KVO awareness, to spec
            willChangeValue(for: \.isFinished)
            _isFinished = newValue
            didChangeValue(for: \.isFinished)
        }
    }
}

/// Where a download is landing, once whoever is running it says so.
///
/// GOG works the folder out before it starts and sets it directly. Epic cannot: legendary
/// decides the folder name itself from the game's own metadata — "BioShock Infinite: Complete
/// Edition" becomes `BioshockInfiniteCompleteEdition`, which is not derivable from the title —
/// so it is read from the line legendary prints before the first byte.
final class DownloadDestination: @unchecked Sendable {
    /// The directory the download was told to go under. Nothing outside it is this download's
    /// to remove.
    private let base: URL
    private let lock: NSLock = .init()
    private var _url: URL?

    init(under base: URL) {
        self.base = base
    }

    var url: URL? { lock.withLock { _url } }

    /// Accepts only a strict subfolder of the install directory, and refuses everything else.
    ///
    /// This is the guard that stops a bad folder name costing somebody their whole library. The
    /// GOG path builds its answer as `baseDirectory + folderName`, and a `folderName` that is
    /// empty, `.` or `/` resolves to **the install directory itself** — so removing it would
    /// remove every game in it. `..` climbs above it. Neither needs a bug here to happen: both
    /// are one malformed field in somebody else's metadata away.
    func set(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = base.standardizedFileURL.resolvingSymlinksInPath()

        guard resolved != root, resolved.path.hasPrefix(root.path + "/") else { return }

        lock.withLock { _url = resolved }
    }

    /// `[Core] INFO: Install path: /Volumes/Mac Extended/Games/GOG/BioshockInfiniteCompleteEdition`
    func note(_ chunk: Process.OutputChunk) {
        guard case .standardError = chunk.stream,
              let match = try? Regex(#"Install path: (.+)$"#).firstMatch(in: chunk.output),
              let path = match[1].substring else { return }

        let trimmed = String(path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Through `set`, so legendary's answer is held to the same rule as GOG's.
        set(.init(filePath: trimmed))
    }
}

extension GameOperation {
    /// How far a launch has got. Nothing else has phases.
    enum LaunchPhase: Sendable, Equatable {
        /// Getting the container ready: applying this game's settings, installing the verbs it
        /// needs, booting a prefix that has never run. Nothing has been started yet, and this
        /// is where a configuration the recovery loop decided after the last launch is put in
        /// place — which is worth saying on screen, because it is the part that can take a
        /// while and the part the person has been waiting for.
        case preparing
        /// Asked for, no window yet.
        case starting
        /// The game is on screen.
        case running
    }

    /// What to call this operation in the interface.
    ///
    /// A launch is "Running" only once the game is up. Saying it while the game is still
    /// loading is what made a six-second spinner look like a signal.
    var statusDescription: String {
        if type == .launch, isForceQuitting { return String(localized: "Force quitting") }

        guard type == .launch, launchPhase != .running else { return type.description }
        return String(localized: "Starting")
    }

    override var description: String { "\(type) \(game)" }
    override var debugDescription: String { "[\(id)] \(type) for game \(game.debugDescription)" }
}

// MARK: - Types

extension GameOperation {
    enum ActiveOperationType {
        // case download
        case install
        case repair
        case update
        case move
        case uninstall
        case launch
        
        var modifiesFiles: Bool {
            switch self {
            case .launch:  false
            default:        true
            }
        }
    }
}

extension GameOperation.ActiveOperationType: CustomStringConvertible {
    var description: String {
        switch self {
        // case .download:     String(localized: "Downloading")
        case .install:      String(localized: "Installing")
        case .repair:       String(localized: "Repairing")
        case .update:       String(localized: "Updating")
        case .move:         String(localized: "Moving")
        case .uninstall:    String(localized: "Uninstalling")
        case .launch:       String(localized: "Running")
        }
    }
}

extension ProgressUserInfoKey {
    /// How much of the download tool's in-memory cache is in use, in bytes.
    ///
    /// Read together with ``diskWriteThroughput`` — on its own it does not say which end is
    /// slow. Downloads land in this cache and are written out from it *in order*, and slots
    /// also hold chunks waiting their turn and chunks kept for reuse by later files. Full with
    /// the disk writing fast means the disk is the limit; full with the disk writing next to
    /// nothing means the writer is waiting on one late chunk, which is the network.
    static let downloadCacheUsage: ProgressUserInfoKey = .init("PorTalisticDownloadCacheUsage")

    /// How fast the download is being written to disk, in bytes a second.
    static let diskWriteThroughput: ProgressUserInfoKey = .init("PorTalisticDiskWriteThroughput")
}

// MARK: - ProgressKVOBridge
@Observable final class ProgressKVOBridge: @unchecked Sendable {
    // swiftlint:disable:next identifier_name
    let _progress: Progress

    // Observables that mirror `Progress`
    private(set) var fractionCompleted: Double = 0.0
    private(set) var completedUnitCount: Int64 = 0
    private(set) var totalUnitCount: Int64 = 0
    private(set) var throughput: Int?
    private(set) var estimatedTimeRemaining: TimeInterval?
    private(set) var fileTotalCount: Int?
    private(set) var fileCompletedCount: Int?
    private(set) var downloadCacheUsage: Int64?
    private(set) var diskWriteThroughput: Int64?

    private var observers: Set<NSKeyValueObservation>
    private var lock: NSRecursiveLock = .init()
    private var pollingTimer: Timer?

    // register KVOs and send to observables
    init(progress: Progress) {
        self._progress = progress
        self.observers = .init()

        observers.insert(self._progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, change in
            guard let self, let newValue = change.newValue else { return }
            Task { @MainActor in
                lock.withLock({ self.fractionCompleted = newValue })
            }
        })

        observers.insert(self._progress.observe(\.completedUnitCount, options: [.new]) { [weak self] _, change in
            guard let self, let newValue = change.newValue else { return }
            Task { @MainActor in
                lock.withLock({ self.completedUnitCount = newValue })
            }
        })

        observers.insert(self._progress.observe(\.totalUnitCount, options: [.new]) { [weak self] _, change in
            guard let self, let newValue = change.newValue else { return }
            Task { @MainActor in
                lock.withLock({ self.totalUnitCount = newValue })
            }
        })

        // polling task to update KVO-incompatible variables
        Task { @MainActor [weak self] in
            while let self = self {
                lock.withLock({ self.throughput = self._progress.throughput })
                lock.withLock({ self.estimatedTimeRemaining = self._progress.estimatedTimeRemaining })
                lock.withLock({ self.fileTotalCount = self._progress.fileTotalCount })
                lock.withLock({ self.fileCompletedCount = self._progress.fileCompletedCount })
                lock.withLock({
                    self.downloadCacheUsage = (self._progress.userInfo[.downloadCacheUsage] as? NSNumber)?.int64Value
                    self.diskWriteThroughput = (self._progress.userInfo[.diskWriteThroughput] as? NSNumber)?.int64Value
                })

                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    deinit { observers.forEach({ $0.invalidate() }) }
}
