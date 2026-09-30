//
//  Process.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 25/3/2024.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

extension Process {
    /// Verify that a process' termination status is 0, which is conventionally returned upon successful process execution.
    /// - Throws: ``NonZeroTerminationStatusError`` if the termination status is not 0.
    func checkTerminationStatus() throws {
        guard !self.isRunning else {
            Logger.app.error("Attempted to check termination status of running process [\(self.processIdentifier)].")
            return
        }
        
        if self.terminationStatus != 0 {
            throw NonZeroTerminationStatusError(self.terminationStatus)
        }
    }
    
    /// Synchronously executes a process, and immediately attempts to collect complete stdout/stderr.
    /// - Attention: Don't use this for larger outputs — instead use `execute` (async) or `stream` to avoid potential pipe back-pressure.
    /// - Note: If you don't require output, use `.run()` instead.
    func runWrapped() throws -> CommandResult {
        let stderr: Pipe = .init(); self.standardError = stderr
        let stdout: Pipe = .init(); self.standardOutput = stdout
        
        let log: Logger = .custom(category: "Process[\(self.processIdentifier)] (wrapped) @ \(self.executableURL?.pathComponents.suffix(3).joined(separator: "/") ?? .init())")
        
        try self.run()
        
        var decodedStandardOutput: String? = nil
        if let data = try stdout.fileHandleForReading.readToEnd() {
            decodedStandardOutput = .init(data: data, encoding: .utf8)
        }
        
        var decodedStandardError: String? = nil
        if let data = try stderr.fileHandleForReading.readToEnd() {
            decodedStandardError = .init(data: data, encoding: .utf8)
        }
        
        return .init(standardOutput: decodedStandardOutput,
                     standardError: decodedStandardError)
    }
    
    // allow the compiler to automatically choose execute overload depending on async/sync context
    /// Asynchronously executes a process, and concurrently collects stdout and stderr.
    /// - Note: If you don't require output, use `.run()` instead.
    func runWrapped() async throws -> CommandResult {
        let stderr: Pipe = .init(); self.standardError = stderr
        let stdout: Pipe = .init(); self.standardOutput = stdout
        
        let log: Logger = .custom(category: "Process[\(self.processIdentifier)] (wrapped, async) @ \(self.executableURL?.pathComponents.suffix(3).joined(separator: "/") ?? .init())")
        
        try self.run()
        
        func spawnReadTask(for handle: FileHandle, for stream: Process.Stream) -> Task<String?, Error> {
            Task.detached(priority: .utility) {
                guard let data = try handle.readToEnd() else { return nil }
                let text: String? = .init(data: data, encoding: .utf8)
                
                if let text, !text.isEmpty {
                    log.debug("[\(stream.rawValue)] \(text, privacy: .public)")
                }
                
                return text
            }
        }
        
        // accumulate piped data asynchronously
        let standardErrorReadTask = spawnReadTask(for: stderr.fileHandleForReading, for: .standardError)
        let standardOutputReadTask = spawnReadTask(for: stdout.fileHandleForReading, for: .standardOutput)
        
        self.waitUntilExit()
        
        return .init(standardOutput: try await standardOutputReadTask.value,
                     standardError: try await standardErrorReadTask.value)
    }
    
    func runWrappedAsync() async throws -> CommandResult {
        try await runWrapped()
    }

    // MARK: - Bounded execution

    /// Whether the process has exited by `deadline`, without blocking a thread while waiting.
    ///
    /// Deliberately polling rather than `waitUntilExit()`. That call blocks whichever thread
    /// it lands on, including a cooperative-pool one, and the processes this exists for are
    /// precisely the ones that never exit.
    private func hasExited(by deadline: ContinuousClock.Instant) async -> Bool {
        while .now < deadline {
            if !isRunning { return true }

            // Not `Task.sleep` on the caller's task: on a cancelled one it returns at once, and
            // after a Force Quit the launch's task is exactly that. This then polled flat out, a
            // core at full tilt for as long as the process took — which, for a prefix still
            // booting when its launch was force-quit, can be minutes.
            await Task.detached { try? await Task.sleep(for: .milliseconds(200)) }.value
        }

        return !isRunning
    }

    /// Stop the process, if there is a process there to stop.
    ///
    /// `terminate()` and `interrupt()` are Objective-C methods, and they *raise* when the
    /// process has not been launched: `*** -[NSConcreteTask terminate]: task not launched`.
    /// That is an `NSException`, which Swift cannot catch — so it is not an error to handle,
    /// it is a crash.
    ///
    /// Every call to that pair in this app is made from a `withTaskCancellationHandler`'s
    /// `onCancel`, which is exactly where an unlaunched process is possible: `onCancel` runs
    /// on whatever thread cancelled, concurrently with the body, and it runs *instead of
    /// waiting for* the body when the task was already cancelled on entry — so it can land
    /// before the `try process.run()` on the body's first line.
    ///
    /// Force-quitting a running game from Operations died here, and the crash took the
    /// `Wine.killAll(at:)` on the following line with it — so the one call that actually stops
    /// a game never ran. What the person saw was a launcher that stopped responding and a game
    /// that carried on: it had not hung, it had died.
    ///
    /// `kill(2)` rather than the raising pair even behind the guard, because the guard on its
    /// own is still a race: the child may exit between the check and the call, and `kill` to a
    /// process that has gone is `ESRCH` where `terminate()` would have raised.
    ///
    /// What that leaves, stated rather than glossed: `onCancel` runs on whatever thread
    /// cancelled, so `isRunning` and `processIdentifier` are read unsynchronised, and if
    /// Foundation reaps the child and the system recycles its pid inside that window the signal
    /// lands on a stranger. It needs pid-space wraparound within a few microseconds. Closing it
    /// properly means never signalling through a `Process` at all — holding the pid in a box
    /// that the process's own `terminationHandler` empties — which is worth it for one path, not
    /// for a general helper.
    ///
    /// - Parameter signal: `SIGTERM` by default. Pass `SIGINT` for `legendary` and `gogdl`:
    ///   both write down where a download got to when they are interrupted, and start again
    ///   from nothing when they are not.
    func stopIfRunning(_ signal: Int32 = SIGTERM) {
        // A process that was never launched reports 0, and `kill(0, ...)` signals every
        // process in the caller's own process group — which is to say, this app.
        let pid = processIdentifier
        guard pid > 0, isRunning else { return }

        kill(pid, signal)
    }

    /// Interrupt the process, and insist if it does not go.
    ///
    /// `legendary` and `gogdl` are asked with `SIGINT`, because that is what makes them write
    /// down where a download had got to. But asking is not being obeyed: stopping a download
    /// means stopping its worker processes — eighteen of them, in the case that prompted this —
    /// and when that hangs, the process this app is waiting on never exits.
    ///
    /// What that looked like: cancelling a download stopped the download, and then nothing
    /// else happened. `runStreamed` sat in `waitUntilExit()`, the operation never finished, its
    /// completion block never ran, so it was never taken out of the queue — and a progress bar
    /// for a download that had already stopped sat there looking paused until the app was
    /// restarted.
    ///
    /// Detached on purpose: it is started from a cancellation handler, and it has to outlive
    /// the task being cancelled. Escalating costs nothing when the process has already gone,
    /// because each step checks first.
    func interruptThenInsist(within grace: Duration = .seconds(10)) {
        let pid = processIdentifier

        // Nothing to stop — and 0 is not "nothing" to anything below. A process that has not
        // been launched reports a pid of 0: `pgrep -P 0` answers with launchd, whose descendants
        // are every app the person has open, and each of them was about to be interrupted, then
        // terminated, then killed. `kill(0, …)` adds this app's own process group, and
        // `isAlive(0)` is always true, which switched the stopped-download clean-up off for the
        // rest of the session. A Stop pressed while an attempt was still being prepared went
        // exactly there. A process that has already exited is no better: its workers belong to
        // launchd by then, and its pid may already be somebody else's. A stop that arrives before
        // the launch is not lost — see ``StoppableLaunch``.
        guard pid > 0, isRunning else { return }

        // Noted synchronously, before anything else happens: the clean-up that follows a
        // cancellation waits for these to die, and it can start before the task below has run
        // a single line.
        ChildProcesses.noteStopping([pid])

        Task.detached(priority: .utility) { [self] in
            // Before the interrupt, not after. A download is a fleet of processes, and they are
            // children of the *tool* rather than of this app — so the instant the tool exits
            // they re-parent to `launchd` and `pgrep -P` can no longer name them. Asking
            // afterwards meant a tool that shut down quickly left its workers downloading with
            // nothing able to identify them, and the folder a cancellation had just cleaned up
            // filled straight back in. The `pgrep` costs tens of milliseconds; a download that
            // never stops costs rather more.
            let workers = await ChildProcesses.descendants(of: pid)
            ChildProcesses.noteStopping(workers)

            // Whatever has actually gone by the time this gives up is no longer being stopped.
            defer { ChildProcesses.noteStopped([pid] + workers) }

            // The workers are interrupted alongside the tool, not left until the escalation.
            // Signalling only the parent left them writing for the whole grace period.
            stopIfRunning(SIGINT)
            workers.forEach { kill($0, SIGINT) }

            try? await Task.sleep(for: grace)

            let survivors = workers.filter(ChildProcesses.isAlive)
            guard isRunning || !survivors.isEmpty else { return }

            Logger.app.notice("""
                A download did not stop when asked; terminating it and \
                \(survivors.count, privacy: .public) worker(s)
                """)
            stopIfRunning(SIGTERM)
            survivors.forEach { kill($0, SIGTERM) }

            try? await Task.sleep(for: .seconds(5))

            let remaining = workers.filter(ChildProcesses.isAlive)
            guard isRunning || !remaining.isEmpty else { return }

            Logger.app.warning("A download did not stop when terminated; killing it")
            stopIfRunning(SIGKILL)
            remaining.forEach { kill($0, SIGKILL) }
        }
    }

    /// Kill the process and everything it has started, now.
    ///
    /// For a Force Quit that finds a launch installing what its game needs. winetricks is a shell
    /// script, and at any moment the work is one of its children — a download, an extraction, an
    /// installer under Wine — so killing the script alone leaves that child to finish by itself.
    /// The script is stopped where it is first, so that it can't start anything new while its
    /// family is counted, and the family is counted before anything dies: once the script has
    /// gone, its children belong to launchd and nothing can say whose they were.
    ///
    /// Wine's server is never among them — it detaches as it starts — which is why a Force Quit
    /// clears the prefix as well. See `Wine.forceQuit(containerAt:)`.
    func killTree() {
        let pid = processIdentifier

        // Never pid 0, and never launchd: see ``interruptThenInsist(within:)``.
        guard pid > 1, isRunning else { return }

        kill(pid, SIGSTOP)

        Task.detached(priority: .userInitiated) { [self] in
            let family = await ChildProcesses.descendants(of: pid)

            stopIfRunning(SIGKILL)
            family.forEach { kill($0, SIGKILL) }
        }
    }

    /// `waitUntilExit()` that a cancelled `Task` can get out of.
    ///
    /// `waitUntilExit()` blocks whichever thread it lands on and knows nothing about tasks, so
    /// a launch sitting inside it ignores cancellation completely: pressing Stop set the flag,
    /// nothing ever read it, and the game's entry stayed on "launching" for as long as the
    /// process lived. Polling, for the same reason ``hasExited(by:)`` does.
    ///
    /// Returning on cancellation means the process may still be running: a return from here is
    /// not an exit, and `terminationStatus` raises on a process that has not exited. Which is
    /// why ``runStreamed(throwsOnChunkError:launchingWith:chunkHandler:)`` throws rather than
    /// returns when it stops waiting early.
    func waitUntilExitOrCancellation() async {
        while isRunning {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Runs the process, and kills it at `timeout` rather than waiting forever.
    ///
    /// ``runWrapped()`` cannot be used for anything in a Wine container, and the reason isn't
    /// obvious: it collects output through a `Pipe` and reads to end-of-file, but the write
    /// end of that pipe is inherited by the wineserver and by every Windows process under it.
    /// EOF therefore doesn't arrive when the process we launched exits — it arrives when the
    /// last of its unrelated descendants does. `steam.exe -shutdown` against a client wedged
    /// before its UI came up never reaches that point, which is how "Restart Steam" came to
    /// sit on "Shutting Steam down" forever.
    ///
    /// - Returns: `true` if the process exited on its own, `false` if it had to be killed.
    @discardableResult
    func runBounded(timeout: Duration) async -> Bool {
        await runBoundedReporting(timeout: timeout) == .exited
    }

    /// How a bounded run ended.
    ///
    /// Two of these used to be one `false`: a process that could not be started at all, and one
    /// that ran out of time. Reported as the same thing, a Wine that failed to launch in the
    /// first millisecond read as a first boot that had been working for five minutes.
    enum BoundedRunOutcome: Equatable, Sendable {
        case exited
        case killed
        case couldNotStart(String)
    }

    /// ``runBounded(timeout:)``, saying which way it ended.
    func runBoundedReporting(timeout: Duration) async -> BoundedRunOutcome {
        standardInput = FileHandle.nullDevice
        if standardOutput == nil { standardOutput = FileHandle.nullDevice }
        if standardError == nil { standardError = FileHandle.nullDevice }

        do {
            try run()
        } catch {
            Logger.app.error("Couldn't start \(self.executableURL?.lastPathComponent ?? "process"): \(error.localizedDescription)")
            return .couldNotStart(error.localizedDescription)
        }

        if await hasExited(by: .now.advanced(by: timeout)) { return .exited }

        Logger.app.notice("\(self.executableURL?.lastPathComponent ?? "process", privacy: .public) outlived its \(timeout, privacy: .public) budget; terminating it.")
        terminate()

        if await hasExited(by: .now.advanced(by: .seconds(2))) { return .killed }
        kill(processIdentifier, SIGKILL)

        return .killed
    }

    /// ``runBounded(timeout:)``, keeping the output.
    ///
    /// Output goes to files rather than pipes, so reading it never waits on anyone: whatever
    /// was written by the deadline is what comes back, and descendants still holding the
    /// handles are free to keep writing into a file nobody is waiting on.
    ///
    /// - Returns: `nil` if the process had to be killed.
    func runWrapped(timeout: Duration) async -> CommandResult? {
        guard let run = await runWrappedKeepingOutput(timeout: timeout), run.outcome == .exited else { return nil }
        return run.result
    }

    /// ``runWrapped(timeout:)``, keeping whatever was written before the end however it came.
    ///
    /// For the caller whose failure *is* the thing to explain: a first boot that ran out of time,
    /// or never started, used to leave nothing behind, because its output went with it.
    ///
    /// - Returns: `nil` only if there was nowhere to put the output.
    func runWrappedKeepingOutput(timeout: Duration) async -> (result: CommandResult, outcome: BoundedRunOutcome)? {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "\(Branding.name)Process-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let outputURL = scratch.appending(path: "stdout")
        let errorURL = scratch.appending(path: "stderr")

        for url in [outputURL, errorURL] {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let outputHandle = try? FileHandle(forWritingTo: outputURL),
              let errorHandle = try? FileHandle(forWritingTo: errorURL) else { return nil }

        standardOutput = outputHandle
        standardError = errorHandle

        let outcome = await runBoundedReporting(timeout: timeout)

        try? outputHandle.close()
        try? errorHandle.close()

        return (.init(standardOutput: try? String(contentsOf: outputURL, encoding: .utf8),
                      standardError: try? String(contentsOf: errorURL, encoding: .utf8)),
                outcome)
    }
    
    func runStreamed(throwsOnChunkError: Bool = true) -> AsyncThrowingStream<OutputChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runStreamed(throwsOnChunkError: throwsOnChunkError) { chunk in
                        continuation.yield(chunk)
                        return nil // `AsyncThrowingStream` can't return replies
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Starts a process and issues a `chunkHandler` callback of incremental ``OutputChunk``s,
    /// With support for responding to input by returning a value to the callback.
    ///
    /// Returns only once the process has exited, so `terminationStatus` is safe to read
    /// afterwards. A task cancelled while the process runs stops waiting and throws
    /// `CancellationError` instead; stopping the process is the caller's business.
    ///
    /// - Parameter launch: How to launch it when a stop can arrive before it has started — see
    ///   ``StoppableLaunch``. Without one, the process is launched whatever has happened.
    func runStreamed(throwsOnChunkError: Bool = true,
                     launchingWith launch: StoppableLaunch? = nil,
                     chunkHandler: (@Sendable (OutputChunk) throws -> String?)? = nil) async throws {
        let stderr: Pipe = .init(); self.standardError = stderr
        let stdout: Pipe = .init(); self.standardOutput = stdout
        let stdin: Pipe = .init(); self.standardInput = stdin
        
        let log = Logger.custom(
            category: "Process[\(self.processIdentifier)] (streamed) @ \(self.executableURL?.pathComponents.suffix(3).joined(separator: "/") ?? "")"
        )
        
        actor StandardInputWriter {
            let handle: FileHandle
            
            init(handle: FileHandle) {
                self.handle = handle
            }
            
            func write(_ string: String) async {
                guard let data = string.data(using: .utf8) else { return }

                // The throwing spelling. `FileHandle.write(_:)` raises on `EPIPE`, which is
                // reachable here and not exotic: this writes legendary's stdin, the only
                // caller is `install`'s reply to the optional-packs prompt, and `fetchMetadata`
                // deliberately interrupts legendary at that same prompt. Writing to a process
                // that has gone is a lost reply; it is not a reason to take the app down.
                try? handle.write(contentsOf: data)
            }
        }
        let writer: StandardInputWriter = .init(handle: stdin.fileHandleForWriting)
        
        func attachReadabilityStream(to handle: FileHandle, for stream: Process.Stream) async throws {
            // Kept rather than thrown on the spot, and thrown once the output has ended.
            //
            // Throwing here stopped this loop reading — and a process whose output nobody reads
            // fills the pipe and then blocks on its next write, for good. legendary logs at ERROR
            // level for things it recovers from by itself (a chunk whose download failed and is
            // being fetched again), so a long download that hit one of those carried on for a
            // minute or two until its stderr filled, and then simply stopped: no progress, no
            // exit, nothing to say why. The caller still gets the error; it just no longer costs
            // the process its ability to speak.
            var firstError: (any Error)?

            for await data in handle.readabilityDataStream {
                guard !Task.isCancelled else { break }
                
                guard let text: String = .init(data: data, encoding: .utf8) else { continue }
                
                for line in text.split(whereSeparator: \.isNewline) {
                    let chunk: OutputChunk = .init(stream: stream, output: String(line))
                    
                    do {
                        if let chunkHandler, let reply = try chunkHandler(chunk) {
                            await writer.write(reply)
                        }
                    } catch {
                        log.error("[\(stream.rawValue)] caller threw an error: \(error)")
                        if throwsOnChunkError, firstError == nil { firstError = error }
                    }
                    
                    log.debug("[\(stream.rawValue)] \(line, privacy: .public)")
                }
            }

            if let firstError { throw firstError }
        }
        
        @Sendable func closeFileHandlesForReading() {
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForReading.close()
            try? stdin.fileHandleForWriting.close()
        }
        
        self.terminationHandler = { _ in closeFileHandlesForReading() }
        defer { closeFileHandlesForReading() }

        // Through the caller's launch when there is one, so that a stop which got here first
        // means nothing is launched — rather than a download that nobody is left to stop.
        if let launch {
            try launch.launch(self)
        } else {
            try self.run()
        }
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(priority: .utility) {
                try await attachReadabilityStream(to: stderr.fileHandleForReading,
                                                  for: .standardError)
            }
            
            group.addTask(priority: .utility) {
                try await attachReadabilityStream(to: stdout.fileHandleForReading,
                                                  for: .standardOutput)
            }
            
            // Cancellable, not blocking. `waitUntilExit()` blocks whichever thread it lands on
            // and knows nothing about tasks, so cancelling a download returned nobody: the
            // download stopped, this call did not, the operation never finished, and its
            // progress bar sat there looking paused until the app was restarted. Ending the
            // process is `interruptThenInsist`'s job — it is not what the interface should be
            // waiting on.
            await self.waitUntilExitOrCancellation()
            
            // cancel the readability tasks since task has exited
            group.cancelAll()
            
            // throw errors collected by the tasks
            try await group.waitForAll()
        }

        // A return from here says the process has exited, and callers act on it: they read
        // `terminationStatus` next, which raises — uncatchably — on a process still running.
        // The wait above ends early when the task is cancelled, which is the one way to arrive
        // here with it still running, so that way out throws. winetricks reads the status
        // straight after streaming, and a cancelled install took the app down with it.
        if isRunning { throw CancellationError() }
    }
}

extension Process {
    struct NonZeroTerminationStatusError: LocalizedError {
        init(_ terminationStatus: Int32? = nil) {
            self.terminationStatus = terminationStatus
        }
        
        var terminationStatus: Int32?
        var errorDescription: String? = String(localized: "Process execution was unsuccessful. (Non-zero exit code)")
    }
    
    enum Stream: String, Sendable {
        case standardError = "stderr"
        case standardOutput = "stdout"
    }
    
    struct OutputChunk: Sendable {
        public let stream: Stream
        public let output: String
    }
    
    struct CommandResult: Sendable {
        public let standardOutput: String?
        public let standardError: String?
    }
}

/// Launching a process that a stop can reach whenever it arrives.
///
/// A cancellation handler runs on whichever thread cancelled, concurrently with the task it
/// cancels — or straight away, ahead of the task's body, when the task was cancelled before it
/// got there. Either way it can run before anything has been launched. A stop delivered to a
/// process that does not exist yet did nothing, and the task then launched the download anyway:
/// the operation ended as stopped and left it running, with nobody reading its output and
/// nothing in the app able to stop it. It was worse than lost, too — `interruptThenInsist` took
/// the unlaunched process's pid of 0 for a real one. See the guard there.
///
/// No lock is held across the launch itself, which can take seconds the first time a binary is
/// assessed, because the one waiting on it would be whoever pressed Stop. Instead each side
/// checks the other afterwards, which delivers exactly one stop in every order: before the
/// launch, and there is no launch; after it, and the stop finds the process; in between, and
/// the launch finds the stop.
final class StoppableLaunch: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var process: Process?
    private var isStopped = false

    /// What stopping does to a process that was launched.
    private let halt: @Sendable (Process) -> Void

    /// - Parameter halt: how to stop what was launched. A download is interrupted, then insisted
    ///   upon, because that is what makes `legendary` and `gogdl` write down how far they got. A
    ///   game being force-quit is killed outright: there is nothing to write down, and "Force
    ///   Quit" that asks politely is a launch that goes on starting while the person watches.
    init(halting halt: @escaping @Sendable (Process) -> Void = { $0.interruptThenInsist() }) {
        self.halt = halt
    }

    /// Whether a stop has been asked for.
    ///
    /// For the steps around a launch that are not the launch itself — anything that would
    /// otherwise carry on setting up a game somebody has already force-quit.
    var hasBeenStopped: Bool { lock.withLock { isStopped } }

    /// Launch `process`, unless a stop has already been asked for.
    ///
    /// It is also what a stop reaches from then on, so one of these can see a download through
    /// several attempts: only the latest is ever running.
    ///
    /// - Throws: `CancellationError`, having launched nothing, if a stop came first.
    func launch(_ process: Process) throws {
        try launch(process) { try $0.run() }
    }

    /// ``launch(_:)`` with its middle step handed in — only so that a test can put a stop
    /// exactly there, after the check for one and before what was launched is recorded.
    func launch(_ process: Process, running run: (Process) throws -> Void) throws {
        guard lock.withLock({ !isStopped }) else { throw CancellationError() }

        try run(process)

        let stoppedMeanwhile = lock.withLock {
            self.process = process
            return isStopped
        }

        if stoppedMeanwhile { halt(process) }
    }

    /// Stop what was launched, and refuse anything launched after this.
    func stop() {
        let launched = lock.withLock {
            isStopped = true
            return process
        }

        if let launched { halt(launched) }
    }
}
