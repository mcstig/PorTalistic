//
//  LegendaryInterface.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 21/9/2023.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import OSLog
import RegexBuilder

// FIXME: this code is on its way out. legendary will no longer be a Mythic dependency
/**
 Controls the function of the "legendary" cli, the backbone of the launcher's EGS capabilities.
 ‼️ When adding any non-operation method, ensure you use the game's ID as a parameter, instead of the actual Game object.

 [Legendary GitHub Repository](https://github.com/derrod/legendary)
 */
final class Legendary {

    static let configurationFolder: URL = Bundle.appHome!.appending(path: "Epic")

    /// Logger instance for legendary.
    static let log: Logger = .custom(category: "LegendaryInterface")

    /// Not private: `ChildProcesses` needs it to recognise a legendary an earlier session left
    /// running, which it does by path, since every worker process shares the name.
    static var legendaryExecutableURL: URL { Bundle.main.url(forResource: "legendary/cli", withExtension: nil)! }

    private static func constructEnvironment(withAdditionalFlags environment: [String: String] = .init()) -> [String: String] {
        var constructedEnvironment: [String: String] = .init()

        constructedEnvironment["LEGENDARY_CONFIG_PATH"] = configurationFolder.path

        return constructedEnvironment.merging(environment, uniquingKeysWith: { $1 })
    }

    @MainActor
    private static func applyOfflineFlagIfNeeded(_ currentArguments: [String]) -> [String] {
        // Only fall back to offline mode when Epic has been *confirmed* unreachable.
        //
        // This previously tested `!= .accessible`, which is also true while the
        // reachability probe is still running and — crucially — before it has ever run,
        // because `epicAccessibilityState` starts as `nil`. Any legendary command issued
        // in that window silently ran with `--offline`: signing in would fail, and the
        // library would come back empty, with no indication why.
        guard case .inaccessible = NetworkMonitor.shared.epicAccessibilityState else {
            return currentArguments
        }

        return currentArguments + ["--offline"]
    }
    
    ///
    /// - Note: This function will block until EOF.
    /// - Attention: This will only function if the process is currently executing.
    static func handleCLIErrorOutput(fromStandardErrorPipe pipe: Pipe) throws {
        guard let data: Data = try? pipe.fileHandleForReading.readToEnd(),
              let output: String = .init(data: data, encoding: .utf8) else { return }
        
        try handleCLIErrorOutput(fromStandardErrorOutput: output)
    }
    
    /// Whether an ERROR line from legendary is one it deals with itself.
    ///
    /// Read out of this build of legendary's own code, not guessed: each of these is logged and
    /// then retried, skipped or repaired by legendary without any help — a chunk that failed and
    /// is being fetched again, the next job picked up after one failed, selective-download data
    /// it could not get, an old manifest it can do without, and the verification findings that an
    /// update which switched itself into repair mode goes on to repair.
    static func isRecoverable(_ reason: String) -> Bool {
        let recoverable = [
            "failed, retrying...",
            ", fetching next one...",
            "Unable to get SDL data for",
            "Could not load old manifest, patching will not work!",
            "File does not match hash: ",
            "File is missing: ",
            "Other failure (see log), treating file as missing: ",
            "Verification failed, "
        ]

        return recoverable.contains { reason.contains($0) }
    }

    static func handleCLIErrorOutput(fromStandardErrorOutput output: String) throws {
        for line in output.split(whereSeparator: \.isNewline) {
            if let match = try? Regex(#"(ERROR|CRITICAL): (.*)"#).firstMatch(in: line),
               let errorReason = match.last?.substring {
                
                // legendary refuses rather than waits when something else holds its
                // installed-games database: "Failed to acquire installed data lock, only one
                // instance of Legendary may install/import/move applications at a time." It is
                // the one error here worth waiting out rather than showing to anybody — the app
                // races itself for that lock (a cloud-save sync at startup, an install resumed
                // beside one already running, a download the last session left finishing) — so
                // it gets a type of its own. See ``executeStreamedWaitingForLock(arguments:attempts:interval:chunkHandler:)``.
                if errorReason.localizedCaseInsensitiveContains("installed data lock") {
                    throw InstalledDataLockError()
                }

                // Logged at ERROR, and then handled by legendary itself. Failing the operation on
                // these reported downloads that recovered and finished as broken — and, before
                // the pipe was drained to the end, stopped reading legendary's output altogether,
                // which is how a download could hang for good on one retried chunk.
                //
                // Listed line by line rather than excused wholesale by an exit code of zero,
                // because legendary also exits 0 after genuine failures: a title that has to be
                // installed through a third-party store, a file it could not write, an update
                // that quietly turned into a repair it then declined to do.
                guard !isRecoverable(String(errorReason)) else { continue }

                throw GenericError(reason: String(errorReason))
            }
        }
    }

    /// Modify a process' properties to call `legendary`.
    /// This will modify `executableURL`, `arguments`, and `environment`, and passthrough existing values.
    /// - Parameter allowOfflineFallback: Whether this command may be run with `--offline`
    ///   when Epic is unreachable. Pass `false` for commands that are meaningless offline —
    ///   authentication above all, where the flag turns a recoverable network problem into
    ///   a flat "unable to sign in".
    static func transformProcess(_ process: Process, allowOfflineFallback: Bool = true) async {
        process.executableURL = legendaryExecutableURL
        
        let capturedArguments = process.arguments ?? []
        let arguments = allowOfflineFallback
            ? await applyOfflineFlagIfNeeded(capturedArguments)
            : capturedArguments
        process.arguments = arguments
        
        let capturedEnvironment = process.environment
        process.environment = constructEnvironment(withAdditionalFlags: capturedEnvironment ?? .init())
    }
    
    /// Execute a `Process` using `.runStreamed`.
    /// - Note: This is the recommended way to stream `legendary` output, as it automatically handles generic legendary errors.
    /// - Parameter launch: See ``StoppableLaunch``: how a stop reaches this process, including
    ///   one that arrives before it has been launched.
    static func executeStreamed(_ process: Process,
                                throwsOnChunkError: Bool = true,
                                launchingWith launch: StoppableLaunch? = nil,
                                chunkHandler: @Sendable @escaping (Process.OutputChunk) throws -> String?) async throws {
        await transformProcess(process)
        
        // Known about for as long as it runs, so quitting can be sure it is gone — see
        // `ChildProcesses`.
        ChildProcesses.register(process)
        defer { ChildProcesses.forget(process) }

        try await process.runStreamed(
            throwsOnChunkError: throwsOnChunkError,
            launchingWith: launch,
            chunkHandler: { chunk in
                if case .standardError = chunk.stream {
                    try handleCLIErrorOutput(fromStandardErrorOutput: chunk.output)
                }
                
                return try chunkHandler(chunk)
            }
        )
    }

    /// Something else holds legendary's installed-games lock.
    struct InstalledDataLockError: LocalizedError {
        var errorDescription: String? = String(localized: "Another download is still finishing.")
        var failureReason: String? = String(localized: "legendary allows one install, import or move at a time.")
    }

    /// Runs a legendary command that writes to the installed-games database, waiting out
    /// whoever else holds the lock on it.
    ///
    /// Everything that installs, updates or repairs goes through here. legendary refuses
    /// outright rather than queueing, and the app races itself for that lock often enough that
    /// refusing was reaching people: an install resumed at startup landed on the lock still held
    /// by a download the previous session had left running, and failed in a modal in front of
    /// somebody who had only just opened the app.
    ///
    /// A fresh process per attempt, because a `Process` cannot be run twice — which is also why
    /// the cancellation handler lives here rather than at the call site: it has to interrupt
    /// whichever attempt is running now.
    ///
    /// legendary's ERROR lines always count here: the ones it recovers from by itself are
    /// excused one by one in ``isRecoverable(_:)``. There is deliberately no way to ignore them
    /// all — that is how a missing manifest and a lock held elsewhere finished as successes.
    static func executeStreamedWaitingForLock(arguments: [String],
                                              attempts: Int = 5,
                                              interval: Duration = .seconds(15),
                                              chunkHandler: @Sendable @escaping (Process.OutputChunk) throws -> String?) async throws {
        // How a stop reaches whichever attempt is running — and refuses to start one once it has
        // been asked for. See `StoppableLaunch`.
        let launch: StoppableLaunch = .init()

        // What legendary asked for, if it stopped to ask, and the last thing it said before it
        // went. See `SharedMemoryRequirement` and `ErrorTranscript`.
        let requirement: SharedMemoryRequirement = .init()
        let transcript: ErrorTranscript = .init()

        try await withTaskCancellationHandler {
            // Declared in here: a `var` captured by a concurrently-executing closure is a data
            // race, and this one is rewritten mid-flight.
            var arguments = arguments

            // Its own budget, not a share of the lock's. The two conditions have nothing to do
            // with each other, and taking the memory retry out of the lock's allowance meant a
            // crash on the last attempt fell out of the loop and was reported as a lock that
            // was never held.
            var raisedSharedMemory = false
            var lockAttempt = 0

            while true {
                let process: Process = .init()
                process.arguments = arguments

                // Set, not inherited. This is spawned from a `.utility` task on a `.utility`
                // operation queue, and without its own quality of service the download ran at
                // theirs — and utility disk writes are throttled, tier-1 I/O policy, which
                // legendary's worker processes inherit along with everything else. A download is
                // always something a person is waiting on, so it runs as one. (Decompression is
                // not the likely limit: it is spread across sixteen processes.)
                process.qualityOfService = .userInitiated

                do {
                    do {
                        try await executeStreamed(process,
                                                  launchingWith: launch,
                                                  chunkHandler: { chunk in
                            requirement.note(chunk)
                            transcript.note(chunk)
                            return try chunkHandler(chunk)
                        })
                    } catch where Task.isCancelled {
                        // A stop is a stop, whatever legendary said before it. The reader keeps
                        // the first error it saw, and a recovered one from minutes earlier would
                        // otherwise surface as the reason — and put an "Unable to complete
                        // operation" alert in front of somebody who had just pressed Stop.
                        throw CancellationError()
                    }

                    // Stopped is not failed, and it has to be asked first. Cancelling a download
                    // interrupts legendary, which then exits non-zero like any other
                    // interrupted process — and `runStreamed` returns normally rather than
                    // throwing, so nothing else distinguishes the two. Without this, pressing
                    // Stop raised a failure alert, and quitting with a download running raised
                    // one during termination.
                    try Task.checkCancellation()

                    // The order of these two clauses is load-bearing, not tidiness.
                    // `terminationStatus` *raises* if the process has not exited — the same
                    // uncatchable family as `terminate()` — and a guard short-circuits left to
                    // right, so `!process.isRunning` is what keeps it from ever being read too
                    // early. Swapping them compiles and crashes.
                    guard !process.isRunning, process.terminationStatus != 0 else { return }

                    // legendary exiting is not legendary succeeding, and this is where that
                    // distinction was lost. A Python traceback looks nothing like the `ERROR:`
                    // line `handleCLIErrorOutput` watches for, so an install that crashed
                    // before downloading a byte finished *successfully*: no failure, no alert,
                    // nothing in the log. From the outside the download simply never started.
                    //
                    // The one crash with a known remedy is the first thing tried, and legendary
                    // names the remedy itself — its download cache defaults to 2 GiB and a
                    // large game's manifest needs more, so it stops and says how much. Asked
                    // again with that number, it installs. Raising the ceiling for every game
                    // instead would allocate that much shared memory for all of them.
                    if let megabytes = requirement.megabytes, !raisedSharedMemory {
                        log.notice("""
                            legendary needs a \(megabytes, privacy: .public) MiB download cache for \
                            this game; asking again with one
                            """)

                        raisedSharedMemory = true

                        // Not the bare figure legendary names. It asks for its peak need plus 64
                        // MiB, which is enough to start and not enough to run smoothly: at the peak
                        // there are then sixty-four free slots for thirty-two downloads in flight,
                        // so a single slow chunk holds the in-order writer, the free slots are gone
                        // in a moment, and the whole download sits at zero until that one chunk
                        // lands. A gigabyte more rides out one slow chunk for about as long as
                        // legendary's own ten-second read timeout at 35 MB/s. It is pageable and
                        // only touched when a backlog grows into it, and it only applies to games
                        // that already failed at the default.
                        arguments += ["--max-shared-memory", String(megabytes + 1024)]
                        continue
                    }

                    // Said out loud, because the exit code on its own says nothing. What sent
                    // this investigation the long way round was a `MemoryError` traceback that
                    // reached no log at all.
                    log.error("""
                        legendary exited \(process.terminationStatus, privacy: .public). \
                        Last output: \(transcript.tail, privacy: .public)
                        """)

                    throw Process.NonZeroTerminationStatusError(process.terminationStatus)
                } catch is InstalledDataLockError {
                    lockAttempt += 1
                    guard lockAttempt < max(1, attempts) else { throw InstalledDataLockError() }

                    log.notice("legendary's installed-games lock is held by something else (attempt \(lockAttempt, privacy: .public) of \(attempts, privacy: .public)); waiting")
                    try await Task.sleep(for: interval)
                }
            }
        } onCancel: {
            // Interrupt rather than terminate: legendary writes down where the download got to
            // when it is asked to stop, and one killed outright starts again from nothing. But
            // only *rather than* — see ``Foundation/Process/interruptThenInsist(within:)``,
            // because an interrupt legendary never acts on left a cancelled download's progress
            // bar on screen until the app was restarted.
            launch.stop()
        }
    }

    /// The last few lines legendary wrote to standard error.
    ///
    /// Kept because legendary can die without saying anything `handleCLIErrorOutput`
    /// recognises: it matches `ERROR:`/`CRITICAL:`, and an unhandled Python exception prints a
    /// traceback ending in `MemoryError: …` and `[PYI-…:ERROR] Failed to execute script`,
    /// neither of which is that shape. The exit code alone only says *that* it failed.
    private final class ErrorTranscript: @unchecked Sendable {
        private let lock: NSLock = .init()
        private var lines: [String] = .init()

        var tail: String { lock.withLock { lines.joined(separator: " / ") } }

        func note(_ chunk: Process.OutputChunk) {
            guard case .standardError = chunk.stream else { return }

            lock.withLock {
                lines.append(chunk.output)
                if lines.count > 12 { lines.removeFirst(lines.count - 12) }
            }
        }
    }

    /// The download's speed, averaged.
    ///
    /// legendary prints its rate once a second, measured over that second alone, so it swings
    /// with every burst of chunks — 34 MB/s, then 15, then nothing, while the download as a
    /// whole carries on at a steady pace. Shown raw, that read as a download that kept stalling.
    /// Five seconds is enough to show what it is actually doing, and short enough that a real
    /// stall still shows up as one.
    final class DownloadStatus: @unchecked Sendable {
        private let lock: NSLock = .init()
        private var recent: [Double] = .init()

        /// - Returns: bytes a second, averaged over the last few readings including this one.
        func averagedThroughput(adding rawMiBPerSecond: Double) -> Int {
            lock.withLock {
                recent.append(rawMiBPerSecond)
                if recent.count > 5 { recent.removeFirst(recent.count - 5) }

                return Int(recent.reduce(0, +) / Double(recent.count) * 1_048_576)
            }
        }
    }

    /// How much of a game was already on disk when this download run began.
    ///
    /// legendary reports progress over *this run's* work, not the game's: `Progress: 47.28%
    /// (261/552)` counts the chunks still to fetch, and a resumed download skips the files it
    /// already finished. So a download quit at 15% and picked back up started again at 0% — the
    /// resume itself was working, the bytes were kept and the folder went on growing from where
    /// it had been, but the progress bar said the download had barely begun.
    ///
    /// legendary says what it is skipping in its analysis, before the first byte:
    ///
    /// ```
    /// [DLM] INFO: Skipping 1234 files based on resume data.
    /// [cli] INFO: Install size: 38495.32 MiB
    /// [cli] INFO: Reusable size: 0.00 MiB (chunks) / 6841.20 MiB (unchanged / skipped)
    /// ```
    ///
    /// Two things about those lines are not what they look like, and both were read from
    /// legendary's own code rather than guessed:
    ///
    /// - **`Install size` is what is left, not the whole game.** legendary recomputes it after
    ///   removing the finished files, so the whole game is `install + skipped`. Dividing by
    ///   `install` alone overstated progress — past the halfway mark it read 100% for the entire
    ///   resumed download.
    /// - **`unchanged / skipped` is not only resume data.** Files left out by an install tag or a
    ///   prefix — a selective download's optional packs — land in the same figure, and counting
    ///   those would start a *fresh* install at 30%. So it is trusted only when the resume line
    ///   says a non-zero number of files were skipped. That line is printed whenever a resume
    ///   file exists, even a stale one that skipped nothing, hence "non-zero" and not "present".
    final class ResumeBaseline: @unchecked Sendable {
        private let lock: NSLock = .init()
        private var resumedFiles: Int = 0
        private var remainingMiB: Double?
        private var skippedMiB: Double?

        func note(_ line: String) {
            if let match = try? Regex(#"Skipping (\d+) files based on resume data"#).firstMatch(in: line),
               let value = Int(match[1].substring ?? "") {
                lock.withLock { resumedFiles = value }
            }

            if let match = try? Regex(#"Install size: (\d+(?:\.\d+)?) MiB"#).firstMatch(in: line),
               let value = Double(match[1].substring ?? "") {
                lock.withLock { remainingMiB = value }
            }

            if let match = try? Regex(#"/ (\d+(?:\.\d+)?) MiB \(unchanged / skipped\)"#).firstMatch(in: line),
               let value = Double(match[1].substring ?? "") {
                lock.withLock { skippedMiB = value }
            }
        }

        /// The whole game's progress, as a percentage, given this run's.
        ///
        /// What was skipped counts as done; this run's percentage covers what is left.
        func overall(fromRun percentage: Double) -> Double {
            lock.withLock {
                guard resumedFiles > 0,
                      let remainingMiB, let skippedMiB, skippedMiB > 0,
                      remainingMiB + skippedMiB > 0 else { return percentage }

                let alreadyDone = skippedMiB / (remainingMiB + skippedMiB)
                return (alreadyDone + (percentage / 100) * (1 - alreadyDone)) * 100
            }
        }
    }

    /// Forget where an Epic download had got to.
    ///
    /// legendary keeps `tmp/<game>.resume` — a list of the files a download has finished — and
    /// trusts it on the next attempt without checking the files themselves: it confirms each
    /// listed file *exists* and that the *recorded* hash matches the manifest, but never
    /// re-hashes what is on disk. The file is appended to and only deleted when a download
    /// completes.
    ///
    /// So removing a stopped download's folder without this left the list behind, and it lied.
    /// Install again, stop at 10% instead of 15%, reopen — and the file that was half-written
    /// at 10% now exists *and* is listed as finished from the first run, so it is skipped. The
    /// game installs with a truncated file in it, and legendary then deletes the only record
    /// that anything was wrong.
    static func discardResumeState(forGameID id: String) {
        // `clean_filename` only strips `<>:"/\|?*`, so an Epic id comes through unchanged.
        let file = configurationFolder.appending(path: "tmp").appending(path: "\(id).resume")

        guard FileManager.default.fileExists(atPath: file.path) else { return }

        do {
            try FileManager.default.removeItem(at: file)
            log.notice("Removed legendary's resume record for \(id, privacy: .public)")
        } catch {
            log.error("Couldn't remove legendary's resume record for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// How much shared memory legendary said it needed, if it refused for want of it.
    ///
    /// legendary sizes a shared-memory cache from the game's manifest, defaults that cache to
    /// 2 GiB, and dies with a Python `MemoryError` when the manifest wants more — naming the
    /// figure to pass in the same breath:
    ///
    /// ```
    /// MemoryError: Current shared memory cache is smaller than required: 2048.0 MiB < 3216.0 MiB.
    /// Try running legendary with "--enable-reordering" to reduce memory usage,
    /// or use "--max-shared-memory 3248" to increase the limit.
    /// ```
    ///
    /// Taking the number from the message rather than guessing one is the point: it is exactly
    /// what this game needs, and every game that does not need it keeps the smaller default.
    private final class SharedMemoryRequirement: @unchecked Sendable {
        private let lock: NSLock = .init()
        private var _megabytes: Int?

        var megabytes: Int? { lock.withLock { _megabytes } }

        func note(_ chunk: Process.OutputChunk) {
            guard case .standardError = chunk.stream,
                  let match = try? Regex(#"--max-shared-memory (\d+)"#).firstMatch(in: chunk.output),
                  let value = Int(match[1].substring ?? "") else { return }

            lock.withLock { _megabytes = value }
        }
    }

    // MARK: - Housekeeping

    /// Whether legendary's housekeeping may run right now.
    ///
    /// `legendary cleanup` removes its stale metadata, its stale manifests — and its temporary
    /// files, which is where `<game>.resume` lives: the list of the files a download has
    /// already finished, and the only reason an interrupted install carries on from where it
    /// stopped rather than starting again from nothing.
    ///
    /// It used to run on every quit, moments after quitting had gone to some trouble to stop
    /// the downloads gently so they could write that file down. Both halves worked. The second
    /// one deleted what the first had just saved, so every resumed install downloaded the whole
    /// game again — the fault looked like "resume is broken" and was nothing of the sort.
    ///
    /// - Parameters:
    ///   - pendingEpicInstalls: Epic installs waiting to be picked back up — see
    ///     ``PendingInstalls``. Epic's only: these are legendary's files, and a GOG download
    ///     waiting on gogdl has no stake in them. Counting every storefront would let one note
    ///     that never resolves switch legendary's housekeeping off for good.
    ///   - fileOperationsInFlight: work on a game's files happening right now. Not installs
    ///     alone: an update and a repair are legendary downloads too, writing the same resume
    ///     state — `--repair` *is* `install --repair`. Launch never sees one, since nothing is
    ///     queued that early, but Settings' "Clean Up Miscellaneous Caches" is reachable at any
    ///     moment, and pressing it during an update would have reproduced the original fault
    ///     exactly.
    nonisolated static func mayCleanUp(pendingEpicInstalls: Int, fileOperationsInFlight: Int) -> Bool {
        pendingEpicInstalls == 0 && fileOperationsInFlight == 0
    }

    /// ``mayCleanUp(pendingEpicInstalls:fileOperationsInFlight:)`` asked of the app as it is
    /// right now.
    private static func mayCleanUpNow() async -> Bool {
        await MainActor.run {
            mayCleanUp(
                pendingEpicInstalls: PendingInstalls.all.filter { $0.storefront == .epicGames }.count,
                fileOperationsInFlight: Game.operationManager.queue.filter { $0.type.modifiesFiles }.count
            )
        }
    }

    /// Run legendary's housekeeping, unless there is a download it would sabotage.
    ///
    /// At launch rather than at quit, for three reasons. Resume state has to outlive the quit
    /// that writes it. What is safe to delete is only known here — the library has just been
    /// refreshed, so legendary's idea of which games still exist is current, where at quit,
    /// after a session that never reached Epic, it is whatever happened to be cached. And this
    /// was a `Process` started from `applicationWillTerminate` and never waited for, which is
    /// precisely the orphan ``ChildProcesses/stopOrphans(of:within:)`` exists to clear up: the
    /// app's own housekeeping was leaving a legendary behind on every single quit.
    ///
    /// What is left, said plainly: the guard is a look, not a lock, so a download started
    /// while `legendary cleanup` is *already deleting* still loses the resume records written
    /// up to that moment. The reason that is tolerable and a lock is not: the only install that
    /// can land in that window is one begun by hand in the second or two after launch, since
    /// anything resumed was queued before the guard ran — so what is lost is a second of a
    /// download that has barely started, against making every Install button wait on
    /// housekeeping that is usually already finished. The fault this function exists for was
    /// losing a finished 40GB download's worth; this is not that fault in miniature, it is a
    /// different and much smaller one.
    ///
    /// - Returns: whether legendary reported finishing. `false` covers both "it did not run,
    ///   because a download was counting on the files it deletes" and "it did not complete".
    @discardableResult
    static func cleanUpStaleData() async -> Bool {
        guard await mayCleanUpNow() else {
            log.notice("Leaving legendary's temporary files alone: a download is counting on them")
            return false
        }

        let process: Process = .init()
        process.arguments = ["cleanup"]
        await transformProcess(process)

        // Asked a second time, because the line above suspends — `transformProcess` consults
        // the main actor — and by then the library is on screen with an Install button on it.
        // A download started inside that window would have had its resume state deleted by a
        // cleanup that checked before it existed.
        guard await mayCleanUpNow() else {
            log.notice("Leaving legendary's temporary files alone: a download started while this was getting ready")
            return false
        }

        // Waited for, and known about while it runs, so it cannot be the thing that outlives
        // the app. See ``ChildProcesses``.
        ChildProcesses.register(process)
        defer { ChildProcesses.forget(process) }

        let result = await process.runWrapped(timeout: .seconds(60))
        return result?.standardError?.contains("Cleanup complete") ?? false
    }

    /// Pull down Epic cloud saves.
    ///
    /// Waited for, and registered while it runs, like everything else this app starts. It was
    /// `try process.run()` inside a task nobody awaited — an orphan by construction, and the
    /// same shape as the housekeeping above: the app's own background errands were the thing
    /// leaving `legendary` processes behind on quit.
    ///
    /// The trade this makes, deliberately: quitting now stops a sync in progress, where before
    /// it carried on unsupervised. A save half-pulled is re-pulled on the next launch, which is
    /// the same outcome the old orphan had whenever macOS reaped it — except that this way the
    /// app knows it happened.
    ///
    /// - Returns: legendary's output, for the caller that reports on whether it worked.
    @discardableResult
    static func synchroniseCloudSaves() async -> Process.CommandResult? {
        let process: Process = .init()
        process.arguments = ["-y", "sync-saves"]
        await transformProcess(process)

        ChildProcesses.register(process)
        defer { ChildProcesses.forget(process) }

        return await process.runWrapped(timeout: .seconds(10 * 60))
    }

    /// Parse legendary's DLManager status output, and use it to update a `Progress` object.
    private static func handleDownloadManagerOutputProgress(for output: String,
                                                            progress: Progress,
                                                            baseline: ResumeBaseline? = nil,
                                                            status: DownloadStatus? = nil) {
        // these regexes are not dynamic, so there's no reason why they should fail to initialise
        // swiftlint:disable force_try
        let progressRegex: Regex = try! .init(#"Progress: (?<percentage>\d+\.\d+)% \((?<downloadedObjects>\d+)\/(?<totalObjects>\d+)\), Running for (?<runtime>\d+:\d+:\d+), ETA: (?<eta>\d+:\d+:\d+)"#)
        // let downloadRegex: Regex = try! .init(#"Downloaded: (?<downloaded>\d+\.\d+) \w+, Written: (?<written>\d+\.\d+) \w+"#)
        // let cacheRegex: Regex = try! .init(#"Cache usage: (?<usage>\d+\.\d+) \w+, active tasks: (?<activeTasks>\d+)"#)
        let downloadSpeedRegex: Regex = try! .init(#"\+ Download\s+- (?<raw>[\d.]+) \w+/\w+ \(raw\) / (?<decompressed>[\d.]+) \w+/\w+ \(decompressed\)"#)
        // let diskSpeedRegex: Regex = try! .init(#"\+ Disk\s+- (?<write>[\d.]+) \w+/\w+ \(write\) / (?<read>[\d.]+) \w+/\w+ \(read\)"#)
        // swiftlint:enable force_try

        /*
         SAMPLE LEGENDARY OUTPUT
         [DLManager] INFO: = Progress: 47.28% (261/552), Running for 00:00:14, ETA: 00:00:15
         [DLManager] INFO:  - Downloaded: 93.43 MiB, Written: 215.42 MiB
         [DLManager] INFO:  - Cache usage: 33.00 MiB, active tasks: 32
         [DLManager] INFO:  + Download    - 7.99 MiB/s (raw) / 17.00 MiB/s (decompressed)
         [DLManager] INFO:  + Disk    - 17.00 MiB/s (write) / 0.00 MiB/s (read)
         */

        if let match = try? progressRegex.firstMatch(in: output) {
            // an assumption is made that `.completedUnitCount` is set to 100.
            let runPercentage = Double(match["percentage"]?.substring ?? .init()) ?? 0

            // Put back in terms of the whole game, when this run is a resumption — see
            // `ResumeBaseline`. Without it a download picked up at 15% showed 1%.
            let percentage = baseline?.overall(fromRun: runPercentage) ?? runPercentage
            progress.completedUnitCount = Int64(percentage.rounded())

            progress.estimatedTimeRemaining = TimeInterval(HH_MM_SSString: String(match["eta"]?.substring ?? .init()))
            progress.fileCompletedCount = Int(match["downloadedObjects"]?.substring ?? .init()) ?? 0
            progress.fileTotalCount = Int(match["totalObjects"]?.substring ?? .init()) ?? 0
        }

        if let match = try? downloadSpeedRegex.firstMatch(in: output),
           let rawMiBPerSecond = Double(match["raw"]?.substring ?? .init()) {
            // Averaged, and no longer truncated to a whole MiB/s first — which turned anything
            // under 1 MiB/s into a flat zero. legendary's figure covers the last second only, so
            // on its own it lurches between 34 and 15 and zero while the download as a whole is
            // doing fine; see `DownloadStatus`.
            progress.throughput = status?.averagedThroughput(adding: rawMiBPerSecond)
                ?? Int(rawMiBPerSecond * 1_048_576)
        }

        // The two lines that say *why* a download slowed down, which were being thrown away.
        //
        //     [DLManager] INFO:  - Cache usage: 1934.00 MiB, active tasks: 32
        //     [DLManager] INFO:  + Disk    - 17.00 MiB/s (write) / 0.00 MiB/s (read)
        //
        // Neither means much alone. A full cache with the disk writing fast is a disk-bound
        // download; a full cache with the disk writing almost nothing is the in-order writer
        // waiting on one late chunk, which is the network. A near-empty cache with a low speed
        // is the network too.
        if let match = try? Regex(#"Cache usage: (?<usage>[\d.]+) MiB"#).firstMatch(in: output),
           let usageMiB = Double(match["usage"]?.substring ?? .init()) {
            progress.setUserInfoObject(NSNumber(value: Int64(usageMiB * 1_048_576)), forKey: .downloadCacheUsage)
        }

        if let match = try? Regex(#"\+ Disk\s+- (?<write>[\d.]+) MiB/s \(write\)"#).firstMatch(in: output),
           let writeMiBPerSecond = Double(match["write"]?.substring ?? .init()) {
            progress.setUserInfoObject(NSNumber(value: Int64(writeMiBPerSecond * 1_048_576)), forKey: .diskWriteThroughput)
        }

        // the others aren't really necessary, or useful information for endusers

        // for download speeds, use * pow(1024, 2), to convert from MiB to B
    }

    /*
     usage: legendary install <App Name> [options]

     Aliases: download, update

     positional arguments:
       <App Name>            Name of the app

     optional arguments:
       -h, --help            show this help message and exit
       --base-path <path>    Path for game installations (defaults to ~/Games)
       --game-folder <path>  Folder for game installation (defaults to folder specified in
                             metadata)
       --max-shared-memory <size>
                             Maximum amount of shared memory to use (in MiB), default: 1 GiB
       --max-workers <num>   Maximum amount of download workers, default: min(2 * CPUs, 16)
       --manifest <uri>      Manifest URL or path to use instead of the CDN one (e.g. for
                             downgrading)
       --old-manifest <uri>  Manifest URL or path to use as the old one (e.g. for testing
                             patching)
       --delta-manifest <uri>
                             Manifest URL or path to use as the delta one (e.g. for testing)
       --base-url <url>      Base URL to download from (e.g. to test or switch to a different
                             CDNs)
       --force               Download all files / ignore existing (overwrite)
       --disable-patching    Do not attempt to patch existing installation (download entire
                             changed files)
       --download-only, --no-install
                             Do not install app and do not run prerequisite installers after
                             download
       --update-only         Only update, do not do anything if specified app is not installed
       --dlm-debug           Set download manager and worker processes' loglevel to debug
       --platform <Platform>
                             Platform for install (default: installed or Windows)
       --prefix <prefix>     Only fetch files whose path starts with <prefix> (case
                             insensitive)
       --exclude <prefix>    Exclude files starting with <prefix> (case insensitive)
       --install-tag <tag>   Only download files with the specified install tag
       --enable-reordering   Enable reordering optimization to reduce RAM requirements during
                             download (may have adverse results for some titles)
       --dl-timeout <sec>    Connection timeout for downloader (default: 10 seconds)
       --save-path <path>    Set save game path to be used for sync-saves
       --repair              Repair installed game by checking and redownloading
                             corrupted/missing files
       --repair-and-update   Update game to the latest version when repairing
       --ignore-free-space   Do not abort if not enough free space is available
       --disable-delta-manifests
                             Do not use delta manifests when updating (may increase download
                             size)
       --reset-sdl           Reset selective downloading choices (requires repair to download
                             new components)
       --skip-sdl            Skip SDL prompt and continue with defaults (only required game
                             data)
       --disable-sdl         Disable selective downloading for title, reset existing
                             configuration (if any)
       --preferred-cdn <hostname>
                             Set the hostname of the preferred CDN to use when available
       --no-https            Download games via plaintext HTTP (like EGS), e.g. for use with a
                             lan cache
       --with-dlcs           Automatically install all DLCs with the base game
       --skip-dlcs           Do not ask about installing DLCs.
     */

    @discardableResult
    /// - Parameter isAutomatic: whether the app asked for this rather than a person — an
    ///   install picked back up at startup. A failure nobody asked for is logged rather than
    ///   shown, and it has to be known *before* the operation is queued, since by the time the
    ///   call returns the download is already running.
    static func install(game: EpicGamesGame,
                        forPlatform platform: Game.Platform,
                        qualityOfService: QualityOfService,
                        optionalPackIDs: [String] = .init(),
                        baseDirectoryURL: URL? = UserDefaults.standard.url(forKey: "installBaseURL"),
                        isAutomatic: Bool = false) async throws -> GameOperation {
        guard let supportedPlatforms = game.getSupportedPlatforms(),
              supportedPlatforms.contains(platform) else {
            throw UnsupportedInstallationPlatformError()
        }

        var arguments: [String] = ["-y", "install", game.id]
        arguments += ["--platform", matchPlatform(for: platform)]

        guard let baseDirectoryURL else {
            log.error("Failed to infer default base URL, installation cannot continue")
            throw CocoaError(.fileReadUnknown)
        }
        arguments += ["--base-path", baseDirectoryURL.path]

        // Noted before it starts: quitting stops the download, and this is what lets the next
        // launch pick it up where it left off rather than leaving the game looking untouched.
        // See `PendingInstalls`.
        await MainActor.run {
            PendingInstalls.remember(.init(gameID: game.id,
                                           storefront: .epicGames,
                                           platform: platform,
                                           baseDirectory: baseDirectoryURL,
                                           optionalPackIDs: optionalPackIDs))
        }

        // Where legendary decides to put it, noted as it says so — see `DownloadDestination`.
        // It is the only way to know: the folder name is legendary's own, not the title's.
        let destination: DownloadDestination = .init(under: baseDirectoryURL)

        // How much a resumed download had already done — see `ResumeBaseline`. Installs only:
        // an update's "unchanged" files are the parts of the game it is not updating, and
        // counting those as progress would show an update as nearly finished before it starts.
        let baseline: ResumeBaseline = .init()
        let status: DownloadStatus = .init()

        let operation: GameOperation = .init(game: game, type: .install) { [arguments] progress in
            progress.totalUnitCount = 100
            progress.fileOperationKind = .downloading

            try await executeStreamedWaitingForLock(arguments: arguments) { chunk in
                destination.note(chunk)

                // append optional packs to legendary's stdin when it requests for them
                if case .standardOutput = chunk.stream {
                    if chunk.output.contains("Additional packs"), !optionalPackIDs.isEmpty {
                        return optionalPackIDs.joined(separator: ", ") + "\n" // use \n as return key
                    }
                }

                if case .standardError = chunk.stream {
                    baseline.note(chunk.output)
                    handleDownloadManagerOutputProgress(for: chunk.output,
                                                        progress: progress,
                                                        baseline: baseline,
                                                        status: status)
                }

                return nil
            }
        }

        operation.downloadDestination = destination
        operation.isAutomatic = isAutomatic
        operation.qualityOfService = qualityOfService
        await Game.operationManager.queueOperation(operation)
        return operation
    }

    @discardableResult
    static func update(game: EpicGamesGame, qualityOfService: QualityOfService) async throws -> GameOperation {
        let arguments: [String] = ["-y", "install", game.id, "--update-only"]

        let status: DownloadStatus = .init()
        let operation: GameOperation = .init(game: game, type: .update) { progress in
            progress.totalUnitCount = 100
            progress.fileOperationKind = .downloading

            try await executeStreamedWaitingForLock(arguments: arguments) { chunk in
                if case .standardError = chunk.stream {
                    handleDownloadManagerOutputProgress(for: chunk.output,
                                                        progress: progress,
                                                        status: status)
                }

                return nil
            }
        }

        operation.qualityOfService = qualityOfService
        await Game.operationManager.queueOperation(operation)
        return operation
    }

    @discardableResult
    static func repair(game: EpicGamesGame, qualityOfService: QualityOfService) async throws -> GameOperation {
        let arguments: [String] = ["-y", "install", game.id, "--repair"]
        let status: DownloadStatus = .init()

        let operation: GameOperation = .init(game: game, type: .repair) { progress in
            progress.totalUnitCount = 100
            progress.fileOperationKind = .downloading

            // The way installs and updates go, which a repair is — it downloads whatever fails
            // verification — and which it had been missing all of: a quality of service of its
            // own rather than the operation queue's throttled one, a stop that reaches legendary's
            // download workers as well as legendary (and one that arrives before legendary has
            // started), the retry with a bigger download cache, a wait for legendary's lock, and
            // a failure read as one whether legendary exits non-zero or only says so.
            //
            // legendary's ERROR lines count again. They were ignored wholesale, because it reports
            // every file that fails verification at that level and finding those is what a repair
            // is for — but that also ignored a missing manifest and a lock held by somebody else,
            // and both finished as successful repairs of nothing. The verification lines are
            // excused one by one instead: see `isRecoverable(_:)`.
            try await executeStreamedWaitingForLock(arguments: arguments) { chunk in
                switch chunk.stream {
                case .standardError:
                    // if game files require redownload
                    handleDownloadManagerOutputProgress(for: chunk.output,
                                                        progress: progress,
                                                        status: status)
                case .standardOutput:
                    // this regex is not dynamic, so there's no reason why they should fail to initialise
                    // swiftlint:disable force_try
                    let verificationProgressRegex = try! Regex(#"Verification progress: (?<downloadedObjects>\d+)\/(?<totalObjects>\d+) \((?<percentage>[\d.]+)%\) \[(?<rawDownloadSpeed>[\d.]+) MiB\/s\]"#)
                    // swiftlint:enable force_try
                    
                    /*
                     SAMPLE LEGENDARY OUTPUT
                     Verification progress: 18053/18780 (98.7%) [1020.6 MiB/s] // main progress
                     => Verifying large file "TAGame/CookedPCConsole/Textures3.tfc": 45% (1151.0/2576.2 MiB) [1186.8 MiB/s] // progress for large files (unhandled)
                     */
                    
                    if let match = try? verificationProgressRegex.firstMatch(in: chunk.output) {
                        progress.completedUnitCount = Int64(Double(match["percentage"]?.substring ?? .init())?.rounded() ?? 0)
                        progress.fileCompletedCount = Int(match["downloadedObjects"]?.substring ?? .init()) ?? 0
                        progress.fileTotalCount = Int(match["totalObjects"]?.substring ?? .init()) ?? 0
                        
                        // convert raw download speed from MiB/s to B/s by multiplying by 1024^2
                        progress.throughput = (Int(Double(match["rawDownloadSpeed"]?.substring ?? .init()) ?? 0)) * Int(pow(1024.0, 2.0))
                    }
                }
                
                return nil
            }
        }

        operation.qualityOfService = qualityOfService
        await Game.operationManager.queueOperation(operation)
        return operation
    }

    /*
     usage: legendary uninstall [-h] [--keep-files] [--skip-uninstaller] <App Name>

     positional arguments:
       <App Name>          Name of the app

     optional arguments:
       -h, --help          show this help message and exit
       --keep-files        Keep files but remove game from Legendary database
       --skip-uninstaller  Skip running the uninstaller
     */
    @discardableResult
    static func uninstall(game: EpicGamesGame,
                          persistFiles: Bool,
                          runUninstallerIfPossible: Bool = true) async throws -> GameOperation {
        let operation: GameOperation = .init(game: game, type: .uninstall) { _ in
            var arguments: [String] = ["-y", "uninstall", game.id]

            if persistFiles { arguments.append("--keep-files") }
            if !runUninstallerIfPossible { arguments.append("--skip-uninstaller") }

            // legendary is inconsistent with this,
            // may have to use FileManager.default.removeItem(atPath:)
            let process: Process = .init()
            process.arguments = arguments
            await transformProcess(process)
            
            let processStandardErrorPipe: Pipe = .init()
            process.standardError = processStandardErrorPipe
            
            try process.run()
            
            do {
                try handleCLIErrorOutput(fromStandardErrorPipe: processStandardErrorPipe)
            } catch {
                // FIXME: dirtyfix for legendary bug resulting in unsuccessful game directory removal
                if let error = error as? GenericError,
                   error.reason.contains("OSError(66, 'Directory not empty')"),
                   case .installed(let location, _) = game.installationState {
                    try FileManager.default.removeItem(at: location)
                }
                
                throw error
            }
            
            game.installationState = .uninstalled
        }

        await Game.operationManager.queueOperation(operation)
        return operation
    }

    /*
     /Users/mihaicristianstoian/Library/Developer/Xcode/DerivedData/PorTalistic-dhppgsuuxtjwwgdqwgyhspxbyibm/SourcePackages/checkouts/Glur
     usage: legendary move [-h] [--skip-move] <App Name> <New Base Path>

     positional arguments:
       <App Name>       Name of the app
       <New Base Path>  Directory to move game folder to

     optional arguments:
       -h, --help       show this help message and exit
       --skip-move      Only change legendary database, do not move files (e.g. if
                        already moved)
     */
    @discardableResult
    static func move(game: EpicGamesGame, to newLocation: URL) async throws -> GameOperation {
        guard case .installed(let currentLocation, let platform) = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let operation: GameOperation = .init(game: game, type: .move) { _ in
            try FileManager.default.moveItem(at: currentLocation, to: newLocation)

            let process: Process = .init()
            process.arguments = ["move", game.id, newLocation.path, "--skip-move"]
            await transformProcess(process)
            
            let processStandardErrorPipe: Pipe = .init()
            process.standardError = processStandardErrorPipe
            
            try process.run()
            
            try handleCLIErrorOutput(fromStandardErrorPipe: processStandardErrorPipe)
            
            game.installationState = .installed(location: newLocation, platform: platform)
        }

        await Game.operationManager.queueOperation(operation)
        return operation
    }

    /*
     usage: legendary import [-h] [--disable-check] [--with-dlcs] [--skip-dlcs]
                             [--platform <Platform>]
                             <App Name> <Installation directory>

     positional arguments:
       <App Name>            Name of the app
       <Installation directory>
                             Path where the game is installed

     optional arguments:
       -h, --help            show this help message and exit
       --disable-check       Disables completeness check of the to-be-imported game
                             installation (useful if the imported game is a much older version
                             or missing files)
       --with-dlcs           Automatically attempt to import all DLCs with the base game
       --skip-dlcs           Do not ask about importing DLCs.
       --platform <Platform>
                             Platform for import (default: Mac on macOS, otherwise Windows)
     */
    @MainActor static func importGame(_ game: EpicGamesGame,
                                      in enclosingDirectory: URL,
                                      repairIfNecessary: Bool = true,
                                      withDLCs: Bool = true,
                                      platform: Game.Platform) async throws {
        guard let supportedPlatforms = game.getSupportedPlatforms(),
              supportedPlatforms.contains(platform) else {
            throw UnsupportedInstallationPlatformError()
        }

        var arguments: [String] = ["-y", "import"]

        if !repairIfNecessary { arguments.append("--disable-check") }
        if withDLCs { arguments.append("--with-dlcs") } else { arguments.append("--skip-dlcs") }

        // append arguments in order, as specified by legendary's '--help' argument
        arguments += ["--platform", matchPlatform(for: platform)]
        arguments.append(game.id)

        arguments.append(enclosingDirectory.path)
        
        let process: Process = .init()
        process.arguments = arguments
        await transformProcess(process)
        
        let processStandardErrorPipe: Pipe = .init()
        process.standardError = processStandardErrorPipe
        
        try process.run()
        
        try handleCLIErrorOutput(fromStandardErrorPipe: processStandardErrorPipe)
    }

    @discardableResult
    static func signIn(authKey: String) async throws -> String {
        let process: Process = .init()
        process.arguments = ["auth", "--code", authKey]
        // Authentication can't work offline, so never let the offline fallback apply here.
        await transformProcess(process, allowOfflineFallback: false)
        
        let result = try await process.runWrapped()
        
        if let successRegex = try? Regex(#"Successfully logged in as \"(?<username>[^\"]+)\""#),
           let standardError = result.standardError,
           let match = try? successRegex.firstMatch(in: standardError),
           let username = match["username"]?.substring {
            // refresh failure should not affect signin capability
            try? await GameDataStore.shared.refreshFromStorefronts()
            return String(username)
        }

        // Legendary explains itself on stderr. Throwing a bare `SignInError` here discarded
        // that explanation and left the user with "Unable to sign in to Epic Games." twice
        // over, with nothing to act on. Surface what it actually said.
        if let standardError = result.standardError {
            log.error("Epic sign-in failed. legendary output: \(standardError, privacy: .public)")
            try handleCLIErrorOutput(fromStandardErrorOutput: standardError)

            let detail = standardError
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces)

            if let detail, !detail.isEmpty {
                throw GenericError(reason: detail)
            }
        }

        throw SignInError()
    }

    static func signOut() async throws {
        let process: Process = .init()
        process.arguments = ["auth", "--delete"]
        await transformProcess(process)
        
        let processStandardErrorPipe: Pipe = .init()
        process.standardError = processStandardErrorPipe
        
        try process.run()
        
        try handleCLIErrorOutput(fromStandardErrorPipe: processStandardErrorPipe)
        
        UserDefaults.standard.removeObject(forKey: "epicGamesWebDataStore")
    }

    /// The WebKit data store that Epic's pages share, created once and remembered.
    ///
    /// The sign-in window and the Store view each declared
    /// `@CodableAppStorage("epicGamesWebDataStore") var … = UUID()`, and that property
    /// wrapper does not write its default back to `UserDefaults` — so with the key unset,
    /// each view evaluated `UUID()` for itself and got a *different* identifier. Two
    /// separate cookie jars: you signed in through the sign-in window, and the Store,
    /// browsing with the other one, still asked you to sign in.
    ///
    /// Persisting on first read is what makes them the same jar. ``signOut()`` still removes
    /// the key, which rotates the identifier and leaves the old store's cookies unreachable.
    static var webDataStoreIdentifier: UUID {
        let key = "epicGamesWebDataStore"

        if let stored = try? UserDefaults.standard.decodeAndGet(UUID.self, forKey: key) {
            return stored
        }

        let fresh: UUID = .init()
        _ = try? UserDefaults.standard.encodeAndSet(fresh, forKey: key)
        log.notice("Created a WebKit data store for Epic's pages.")
        return fresh
    }

    /**
     Launches games.
     */
    @discardableResult
    static func launch(game: EpicGamesGame) async throws -> GameOperation {
        guard case .installed(_, let platform) = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let operation: GameOperation = .init(game: game, type: .launch) { _ in
            var arguments: [String] = ["launch", game.id]
            var environment: [String: String] = .init()

            guard game.isFileVerificationRequired != true else { throw EpicGamesGame.VerificationRequiredError() }

            /// The container this launch borrowed, and the way to give it back. `nil` for a
            /// macOS-native game, which has no prefix to borrow — the old code demanded one
            /// of those too, before the platform was even looked at, so a native Epic game
            /// refused to start until the user made it a Windows container it would never use.
            var plan: Provisioner.LaunchPlan?

            /// The game's own executable, e.g. `HorizonChaseTurbo.exe`.
            ///
            /// Needed because `legendary` is not the game: it spawns Wine detached from itself,
            /// so the process this code starts is not the one that ends up owning a window.
            /// Wine names that application after the executable, which is the only handle on
            /// it. `nil` for a native macOS game, which macOS brings forward by itself.
            var gameExecutableName: String?

            // uses legendary's native launch process
            switch platform {
            case .macOS:
                do {} // no environment variables need to be assembled.
            case .windows:
                // Which runtime this game wants, the container belonging to that runtime, and
                // this game's own settings written into it — the same path GOG launches take.
                // It replaces reading `game.containerURL` and hoping: a game with no
                // container simply refused to start, and a game in a container built by the
                // wrong Wine had no way to say so.
                let resolved = try await Provisioner.shared.planLaunch(for: game)
                let containerURL = resolved.containerURL
                plan = resolved

                Self.log.notice("""
                    Launching \(game.title, privacy: .public) on \(resolved.runtimeName, privacy: .public): \
                    \(resolved.reasons.joined(separator: "; "), privacy: .public)
                    """)

                // `legendary` calls Wine itself, so what it needs is the *path* to a Wine and
                // an environment to hand down — not this process pointed at one.
                //
                // It used to be handed `Engine.wineExecutableURL` unconditionally, which made
                // the container assignment a lie for every Epic game: the provisioner could
                // put a game in a Wine 11 prefix and legendary would still open it with the
                // bundled 7.7. Same prefix, wrong server, and all the caller sees is
                //
                //     wine client error:0: version mismatch 762/930.
                // Windows-style, relative to the install directory — `Binaries\\Win64\\Game.exe`
                // as often as `Game.exe`, hence both separators.
                gameExecutableName = (try? Legendary.getGameInstallationData(gameID: game.id).executable)
                    .map { URL(filePath: $0.replacingOccurrences(of: "\\", with: "/")).lastPathComponent }

                if UserDefaults.standard.bool(forKey: "minimiseOnGameLaunch") {
                    await MainActor.run { NSApp.windows.first?.miniaturize(nil) }
                }

                let invocation = Wine.runtimeInvocation(forContainerAtURL: containerURL)

                environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: containerURL,
                                                                   overriding: resolved.settings)
                environment.merge(invocation.environment, uniquingKeysWith: { $1 })

                // legendary requires this, since it calls wine directly.
                environment["WINEPREFIX"] = containerURL.path(percentEncoded: false)

                // Not `invocation.executableURL`: legendary is signed, so the environment
                // assembled above loses every DYLD_* variable on the way into it, and Wine
                // needs one of those to find the freetype it dlopens. `launcherURL` hands
                // back a script that sets it on the other side of the stripping.
                arguments += ["--wine", Wine.launcherURL(forContainerAtURL: containerURL).path]
            }

            arguments.append(contentsOf: game.launchArguments.map({ "'\($0)'" }))

            let process: Process = .init()
            process.arguments = arguments
            process.environment = environment
            await transformProcess(process)
            
            // Wine's account of the launch, kept on disk. The pipe below survives only as a
            // fallback for the case where the file can't be opened: read to EOF and matched
            // against `ERROR:`, it throws away everything Wine actually said, which is all
            // there is to go on when a game starts no window and reports no error.
            let transcript = Wine.launchTranscript(named: game.title)
            let processStandardErrorPipe: Pipe = .init()

            if let transcript {
                let header = """
                    game: \(game.title) [\(game.id)]
                    runtime: \(plan?.runtimeName ?? "legendary's own")
                    container: \(plan?.containerURL.path(percentEncoded: false) ?? "none")
                    legendary: \(arguments.joined(separator: " "))
                    \(Wine.environmentSummary(environment))

                    """
                try? transcript.handle.write(contentsOf: Data(header.utf8))
                process.standardError = transcript.handle
            } else {
                process.standardError = processStandardErrorPipe
            }

            // An immutable copy, because `onCancel` runs concurrently and cannot capture a
            // `var`. Read here rather than inside the handler: by then `plan` may be being
            // written by the launch it belongs to.
            let launchedContainerURL: URL? = plan?.containerURL

            // How Force Quit reaches this launch, whenever it is pressed. Before `legendary` had
            // been started — while the container was still being set up — there was nothing for
            // it to stop, and the launch carried on and started the game anyway. Killed rather
            // than asked, because that is what Force Quit means: `legendary` launching a game
            // has nothing to write down, and SIGTERM lets it finish handing the game to Wine.
            let launch: StoppableLaunch = .init(halting: { $0.stopIfRunning(SIGKILL) })

            // And what reaches the prefix: begun the moment Force Quit is pressed, finished below.
            let forceQuit: Wine.ForceQuit? = launchedContainerURL.map(Wine.ForceQuit.init(containerAt:))

            do {
                try await withTaskCancellationHandler {
                    try launch.launch(process)

                    // Not a courtesy, and not only about focus. Wine's Mac driver won't change the
                    // display mode while its process isn't the active application — it records the
                    // request and applies it on activation — so a game left behind the library
                    // comes up windowed whatever its settings say. And the person pressed Play:
                    // the game is what they asked to be looking at.
                    //
                    // Epic games went without this while GOG games had it, which is why they
                    // opened behind the library.
                    //
                    // Its own task, and deliberately not awaited. It watches for up to a minute —
                    // an engine that re-launches itself hands the window to a second process, and
                    // that can be a while on a cold start — and awaiting that inside the launch
                    // meant the operation stayed "launching" long after the game was up, with a
                    // Stop button that could not work because nothing was checking for
                    // cancellation. Handing over the foreground is not part of launching; it is
                    // something that happens alongside it.
                    // Plain values, not the `Process`: this outlives the call that made it.
                    let launcherPID = process.processIdentifier
                    let launchedGameID = game.id
                    // A `let` of its own: `async let` captures a variable rather than its value,
                    // and `gameExecutableName` is a `var` belonging to the launch above.
                    let supervisedName = gameExecutableName

                    // The game itself, followed from here until it exits. `legendary` is gone
                    // seconds after this line, so this is the only thing that knows the game came
                    // up (the spinner on Play stops) or is still up (Play stays off, and
                    // Operations keeps a way to force it closed).
                    //
                    // `async let` rather than a detached task, so cancelling the launch — Stop, or
                    // force-quitting the game from Operations — cancels this with it.
                    // The plan and the transcript, hoisted for the same reason as the pid: the
                    // post-mortem runs after the game exits, and it has to read *this* launch's
                    // log against *this* launch's settings.
                    let launchedPlan = plan
                    let launchedTranscriptURL = transcript?.url

                    async let supervised: Void = Wine.superviseGame(named: supervisedName,
                                                                    startedAs: launcherPID,
                                                                    hidingLauncher: false,
                                                                    forGameWithID: launchedGameID,
                                                                    plan: launchedPlan,
                                                                    transcriptAt: launchedTranscriptURL)

                    guard let transcript else {
                        try handleCLIErrorOutput(fromStandardErrorPipe: processStandardErrorPipe)
                        await supervised
                        return
                    }

                    // Waiting is what the pipe did implicitly by reading to EOF.
                    await process.waitUntilExitOrCancellation()
                    try? transcript.handle.close()

                    // Deliberately *not* redacting here. `legendary` exiting is not the game
                    // exiting — see `Provisioner.apply(_:to:)` — so a pass at this point runs while
                    // the game is still writing, which is exactly how a bearer token survived one.
                    // `Wine.rotateLog(at:)` does it at the start of the next launch instead, when
                    // the file is genuinely finished.
                    Self.log.notice("Launch transcript: \(transcript.url.prettyPath, privacy: .public)")

                    // Not read for errors after a Force Quit. `legendary` was killed partway, so
                    // what it wrote says nothing about whether the game could have started — and
                    // a line from before the kill would have been thrown as a reason this launch
                    // failed, one the person hadn't been given and hadn't caused.
                    if !launch.hasBeenStopped, let output = try? String(contentsOf: transcript.url, encoding: .utf8) {
                        try handleCLIErrorOutput(fromStandardErrorOutput: output)
                    }

                    // Last: the operation is the game's life, not `legendary`'s.
                    await supervised
                } onCancel: {
                    // `legendary` spawns Wine completely detached from itself, so stopping the
                    // process this app started does not touch the game — which is why Stop used to
                    // do nothing at all. Stopping a game means stopping the prefix it is running in,
                    // as well as `legendary`, which may still be signing in when this is pressed.
                    //
                    // Through the launch, never `terminate()`: that raises an Objective-C exception
                    // on a process that isn't running, and Swift cannot catch it. That crash landed
                    // here, before the kill below — so Force Quit killed the app instead of the
                    // game.
                    launch.stop()
                    forceQuit?.begin()
                }
            } catch where launch.hasBeenStopped {
                // Force-quit. Whatever the launch threw on its way out — refusing to start
                // `legendary` because the stop came first, or anything that failed because it had
                // been killed — is the Force Quit, and not a failure to report. Nor a reason to
                // leave before the kill is made certain, below: an error thrown here used to skip
                // that, second pass and all.
            }

            // And made certain, before the launch is over. A Wine process that `legendary` had
            // already handed the game to can still be starting when the prefix is cleared, and
            // one that hasn't reached the server yet survives it — see
            // `Wine.forceQuit(containerAt:)`. Awaited, so Play stays unavailable until it has
            // finished and a new launch can't be the thing its second pass takes down.
            if launch.hasBeenStopped {
                await forceQuit?.finish()
            }

            // Nothing is put back. `legendary` exiting is *not* the game exiting — it spawns
            // Wine detached from itself, as the FIXME above says — so a revert here landed
            // while the game was still starting up. See `Provisioner.apply(_:to:)`.
        }

        await Game.operationManager.queueOperation(operation)
        return operation
    }

    /// The last answer worked out for this game, or `nil` if there isn't one yet.
    ///
    /// `Game.isUpdateAvailable` is synchronous and read while drawing a card — three times
    /// per card, in fact: once for the badge on the artwork and twice in the menu. It used to
    /// call ``fetchUpdateAvailability(gameID:)`` directly, which lists the whole metadata
    /// directory and JSON-decodes two files. Twenty visible cards at sixty frames a second
    /// made that a few thousand file reads a second, all of it on the main thread, and that
    /// is what made a full-screen library scroll badly.
    ///
    /// Read from anywhere, written only on the main actor.
    private nonisolated(unsafe) static var memoizedUpdateAvailability: [String: Bool] = .init()

    static func cachedUpdateAvailability(forGameID id: String) -> Bool? {
        memoizedUpdateAvailability[id]
    }

    /// Works the answer out and remembers it. Off the main actor: it is all file reading.
    @discardableResult
    @MainActor static func refreshUpdateAvailability(forGameID id: String) async -> Bool? {
        let answer = await Task.detached { try? fetchUpdateAvailability(gameID: id) }.value
        guard let answer else { return nil }

        memoizedUpdateAvailability[id] = answer
        return answer
    }

    @MainActor static func forgetUpdateAvailability(forGameID id: String) {
        memoizedUpdateAvailability[id] = nil
    }

    static func fetchUpdateAvailability(gameID: String) throws -> Bool {
        let metadata = try getGameMetadata(gameID: gameID)
        let installationData = try getGameInstallationData(gameID: gameID)

        guard let assetInfo = metadata.assetInfos[installationData._platform] else {
            throw CocoaError(.coderValueNotFound)
        }

        // it would be more ideal checking if upstreamVersion is greater than
        // installedVersion, but to do that, we'd need to convert them into
        // SemanticVersion, which is problematic because we have no guarantee
        // that the game uses semantic versioning.
        return assetInfo.buildVersion != installationData.version
    }

    /// What `legendary info --json` says about a game.
    private struct GameInfo: Decodable {
        struct Manifest: Decodable {
            /// Bytes to be pulled over the network — compressed, so smaller than `diskSize`.
            let downloadSize: Int64?
            /// Bytes the game occupies once installed.
            let diskSize: Int64?

            enum CodingKeys: String, CodingKey {
                case downloadSize = "download_size"
                case diskSize = "disk_size"
            }
        }

        /// Not optional on purpose. With every level optional, legendary renaming a key or
        /// nesting it differently decoded "successfully" into nothing — a blank size, no error,
        /// no log line, which is the exact failure this call was written to stop.
        let manifest: Manifest
    }

    /// How much room a game will take, before installing it.
    ///
    /// Asks `legendary info --json`, which is a read-only question with a machine-readable
    /// answer. What this did before was run `legendary install` and *scrape its output* for a
    /// line reading `Install size: N MiB`, interrupting the process once it had seen one — and
    /// that was wrong in three ways at once, which together are why some games showed no size
    /// at all:
    ///
    /// - `install` takes legendary's installed-data lock. Anything already downloading meant
    ///   the probe was refused outright, and the refusal was discarded;
    /// - it was run without `-y`, so after printing the size it sat at a prompt with nothing to
    ///   answer it, relying on that one line matching to interrupt it;
    /// - a game not available for the platform asked about produced an error rather than a
    ///   size, and the platform asked about was a default that had not been corrected yet.
    ///
    /// `info` has none of those properties. It takes no lock, asks nothing, and returns both
    /// sizes as JSON. It is what Heroic asks, which is why Heroic could answer for a game this
    /// app could not.
    ///
    /// - Note: selective-download packs came from reading `install`'s prompt and are no longer
    ///   collected here. They were only ever available at the cost of everything above, and an
    ///   install with none selected takes legendary's defaults — which is what `-y` did anyway.
    static func fetchPreInstallationMetadata(
        game: EpicGamesGame,
        platform: Game.Platform
    ) async throws -> (installSize: Int64?, optionalPacks: [String: String]) {
        guard case .uninstalled = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let process: Process = .init()
        process.arguments = ["info", game.id, "--platform", matchPlatform(for: platform), "--json"]
        await transformProcess(process)

        ChildProcesses.register(process)
        defer { ChildProcesses.forget(process) }

        // Generous on purpose. `info` itself is quick, but legendary renews the Epic login
        // first ("Trying to re-use existing login session…") and that round-trip is the slow
        // part — measured well past thirty seconds on a real machine for a game whose manifest
        // it also has to fetch.
        guard let result = await process.runWrapped(timeout: .seconds(180)) else {
            throw CocoaError(.fileReadUnknown)
        }

        // Surfaced rather than swallowed: "No app asset found for platform" is legendary
        // telling us the game has no build for what was asked, and that is worth saying.
        if let errorOutput = result.standardError {
            try handleCLIErrorOutput(fromStandardErrorOutput: errorOutput)
        }

        guard let json = result.standardOutput?.data(using: .utf8) else {
            throw CocoaError(.fileReadUnknown)
        }

        let info = try JSONDecoder().decode(GameInfo.self, from: json)

        // The disk size, not the download size: the caller compares it against free space.
        return (info.manifest.diskSize ?? info.manifest.downloadSize, .init())
    }

    static func isFileVerificationRequired(gameID: String) throws -> Bool {
        let installationData = try getGameInstallationData(gameID: gameID)
        return installationData.needsVerification
    }

    /// Queries for the user that is currently signed into epic games.
    static func retrieveUser() throws -> String? {
        let userURL: URL = configurationFolder.appending(path: "user.json")

        guard let userData = try? Data(contentsOf: userURL) else { return nil }

        do {
            return try JSONDecoder().decode(User.self, from: userData).displayName
        } catch {
            // Worth shouting about: legendary is authenticated (the file exists) but we
            // can't read it, so the app is about to claim the user is signed out and show
            // an empty library. Silently returning nil here made that indistinguishable
            // from never having signed in.
            log.error("legendary is signed in, but user.json couldn't be decoded: \(error, privacy: .public)")
            return nil
        }
    }

    /// Checks account signin state.
    static var isSignedIn: Bool { return (try? retrieveUser()) != nil }

    static func getInstalledGames() throws -> [EpicGamesGame] {
        guard isSignedIn else { throw NotSignedInError() }

        let installedJSONURL: URL = configurationFolder.appending(path: "installed.json")
        
        // if no games are installed, and the config folder is new, installed.json will not exist.
        guard FileManager.default.fileExists(atPath: installedJSONURL.path) else { return [] }
        
        let installedJSONData = try Data(contentsOf: installedJSONURL)
        let installedGames = try JSONDecoder().decode(Installed.self, from: installedJSONData)

        return installedGames.compactMap { (id, installedGame) -> EpicGamesGame? in
            // DLC sits in `installed.json` alongside the games. `getInstallableGames()` keeps
            // add-ons out of the catalogue, so an installed one has no counterpart to merge
            // with and entered the library as a game in its own right — with no metadata file
            // of its own, so nothing to read a download size from, and an Install button that
            // asks legendary to install an entitlement and is told there is nothing to do.
            guard !installedGame.isDLC else { return nil }

            guard let platform: Game.Platform = installedGame.platform else {
                // Said out loud. Dropped silently, this has exactly one symptom — an installed
                // game showing Download — and no way at all to tell it from the others.
                log.error("""
                    \(installedGame.title, privacy: .public) is installed for platform \
                    "\(installedGame._platform, privacy: .public)", which this app does not \
                    recognise, so it will look uninstalled
                    """)
                return nil
            }
            
            return .init(
                id: id,
                title: installedGame.title,
                installationState: .installed(location: .init(filePath: installedGame.installPath),
                                              platform: platform)
            )
        }
    }

    /// Asks legendary to fetch the signed-in account's catalogue from Epic and cache it
    /// into `metadata/`.
    ///
    /// This step is what actually populates the library. ``getInstallableGames()`` only
    /// *reads* that cache — so without this the app can be signed in perfectly happily and
    /// still show an empty library forever, which is exactly what it did.
    ///
    /// - Parameter forceRefresh: Bypass legendary's own caching and re-fetch from Epic.
    ///   Use for an explicit, user-initiated refresh; the default is enough on launch.
    static func refreshLibraryMetadata(forceRefresh: Bool = false) async throws {
        guard isSignedIn else { throw NotSignedInError() }

        // Whatever is about to be rewritten on disk.
        forgetMetadata()

        let process: Process = .init()
        process.arguments = ["list"] + (forceRefresh ? ["--force-refresh"] : [])
        await transformProcess(process)

        let result = try await process.runWrapped()

        if let standardError = result.standardError {
            try handleCLIErrorOutput(fromStandardErrorOutput: standardError)
        }
    }

    /// The app names in legendary's catalogue that are add-ons rather than games.
    ///
    /// Needed because a refresh only ever adds and updates: an add-on that an earlier version
    /// filed as a game is still sitting in the library, and nothing would ever take it out.
    static func addOnGameIDs() -> Set<String> {
        let metadataDirectory: URL = configurationFolder.appending(path: "metadata")

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: metadataDirectory.path) else {
            return .init()
        }

        return Set(
            contents
                .filter { $0.hasSuffix(".json") }
                .compactMap { fileName -> String? in
                    guard let data = try? Data(contentsOf: metadataDirectory.appending(path: fileName)),
                          let metadata = try? JSONDecoder().decode(GameMetadata.self, from: data),
                          isAddOn(metadata.storeMetadata) else { return nil }

                    return metadata.appName
                }
        )
    }

    static func getInstallableGames() throws -> [EpicGamesGame] {
        guard isSignedIn else { throw NotSignedInError() }

        let metadataDirectory: URL = configurationFolder.appending(path: "metadata")

        // A signed-in account that has never successfully fetched its catalogue has no
        // metadata directory at all. Treat that as "nothing cached yet" rather than an
        // error, so a failed refresh degrades to an empty library instead of taking the
        // whole storefront sync down with it.
        guard FileManager.default.fileExists(atPath: metadataDirectory.path) else { return [] }

        return try {
            try FileManager.default.contentsOfDirectory(atPath: metadataDirectory.path)
                .filter { $0.hasSuffix(".json") }
                .compactMap { fileName -> EpicGamesGame? in
                    let data = try Data(contentsOf: metadataDirectory.appending(path: fileName))

                    // One unparseable entry (a new field, a partial write) shouldn't blank
                    // out the entire library — skip it and keep the rest.
                    guard let metadata = try? JSONDecoder().decode(GameMetadata.self, from: data) else {
                        log.warning("Skipping unreadable Epic metadata file: \(fileName, privacy: .public)")
                        return nil
                    }

                    // A file per entitlement, not per game: DLC lives in here too. See
                    // ``isAddOn(_:)`` for why this is the discriminator.
                    guard !isAddOn(metadata.storeMetadata) else { return nil }

                    return .init(id: metadata.appName,
                                 title: metadata.appTitle,
                                 installationState: .uninstalled)
                }
        }()
    }

    /// Parsed `metadata/<id>.json`, kept for the life of the launch.
    ///
    /// These answers are read while views are drawn — `getSupportedPlatforms()` is asked once
    /// per Epic game by the library's platform filter — and each one used to cost a listing
    /// of the whole metadata directory plus a JSON decode. The files change only when the
    /// catalogue is refreshed, which empties this.
    private nonisolated(unsafe) static var memoizedMetadata: [String: GameMetadata] = .init()
    private static let metadataLock: NSLock = .init()

    static func forgetMetadata() {
        metadataLock.lock()
        memoizedMetadata = .init()
        metadataLock.unlock()
    }

    static func getGameMetadata(gameID: String) throws -> GameMetadata {
        metadataLock.lock()
        let memoized = memoizedMetadata[gameID]
        metadataLock.unlock()

        if let memoized { return memoized }

        // Named directly rather than found by listing the directory. The old version read
        // every filename in `metadata/` to pick the one it already knew the name of.
        let file = configurationFolder.appending(path: "metadata").appending(path: "\(gameID).json")

        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let metadata: GameMetadata = try JSONDecoder().decode(GameMetadata.self, from: try Data(contentsOf: file))

        metadataLock.lock()
        memoizedMetadata[gameID] = metadata
        metadataLock.unlock()

        return metadata
    }

    static func getGameInstallationData(gameID: String) throws -> InstalledGame {
        let installedJSONURL: URL = configurationFolder.appending(path: "installed.json")
        let installedJSONData: Data = try .init(contentsOf: installedJSONURL)
        let installedGames = try JSONDecoder().decode(Installed.self, from: installedJSONData)

        guard let installedGame = installedGames[gameID] else { throw CocoaError(.coderValueNotFound) }

        return installedGame
    }

    /**
     Retrieve a game's launch arguments from Legendary's `installed.json` file.
     ** This isn't compatible with Mythic'c current launch argument implementation, and likely will remain in this unimplemented state.
     */
    static func getGameLaunchParameters(gameID: String) throws -> [String] {
        let installationData = try getGameInstallationData(gameID: gameID)

        // FIXME: unverified that this is how it's implemented in Legendary
        return installationData.launchParameters.components(separatedBy: .whitespaces)
    }

    // TODO: refactor
    /// Create an asynchronous task to update Legendary's stored metadata.
    static func updateMetadata(forced: Bool = true) async {
        guard await !GameListViewModel.shared.isUpdatingLibrary else { return }
        var arguments: [String] = ["list"]
        if forced { arguments.append("--force-refresh") }
        
        Task {
            await MainActor.run {
                GameListViewModel.shared.isUpdatingLibrary = true
            }
            
            defer {
                Task { @MainActor in
                    GameListViewModel.shared.isUpdatingLibrary = false
                }
            }
            
            let process: Process = .init()
            process.arguments = arguments
            await transformProcess(process)
            
            try process.run()
            
            process.waitUntilExit()
        }
    }
    
    static func getImageMetadata(gameID: String, type: ImageType) -> KeyImage? {
        guard let metadata = try? getGameMetadata(gameID: gameID) else { return nil }

        let keyImages = metadata.storeMetadata.keyImages

        let prioritisedTypes: [String] = {
            switch type {
            case .normal: return ["DieselGameBoxWide", "DieselGameBox"]
            case .tall: return ["DieselGameBoxTall"]
            }
        }()

        return keyImages.first(where: { prioritisedTypes.contains($0.type) })
    }

    // TODO: CodingKeys
    static func matchPlatformString(for string: String) -> Game.Platform? {
        switch string {
        // `Win32` is legendary's own third value, for a 32-bit build. Unhandled, it made
        // every 32-bit game look uninstalled — and said nothing about why.
        case "Windows", "Win32":    .windows
        case "Mac":                 .macOS
        default:                    nil
        }
    }

    // TODO: CodingKeys
    static func matchPlatform(for platform: Game.Platform) -> String {
        switch platform {
        case .windows:  "Windows"
        case .macOS:    "Mac"
        }
    }

    /// Retrieves game thumbnail image from legendary's downloaded metadata.
    static func getImageURL(gameID: String, type: ImageType) -> URL? {
        if let imageMetadata = getImageMetadata(gameID: gameID, type: type) {
            return .init(string: imageMetadata.url)
        }

        // fallback #1 — attempt to fetch best matching image for specified image type
        guard let metadata = try? getGameMetadata(gameID: gameID) else { return nil }
        let keyImages = metadata.storeMetadata.keyImages

        if let bestImageMetadata = keyImages.first(where: {
            (type == .normal && $0.width >= $0.height) || (type == .tall && $0.height > $0.width)
        }) {
            return .init(string: bestImageMetadata.url)
        }

        // fallback #2 — use any available image
        if let firstKeyImage = keyImages.first {
            return .init(string: firstKeyImage.url)
        }

        // fallback #3 — 🪦
        return nil
    }

    // don't use or at least refactor 💔 i could not code back in 2023
    static func isAlias(game: String) throws -> (Bool?, of: String?) {
        guard isSignedIn else { throw NotSignedInError() }

        let aliasesFile: URL = configurationFolder.appending(path: "aliases.json")
        let aliasesData = try Data(contentsOf: aliasesFile)

        guard let aliases = try? JSONDecoder().decode(Aliases.self, from: aliasesData) else {
            return (nil, of: nil)
        }

        for (id, aliasList) in aliases {
            if id == game || aliasList.contains(game) {
                return (true, of: id)
            }
        }

        return (nil, of: nil)
    }
}
