//
//  LaunchLifecycleRegressionTests.swift
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
 How long a launch lasts, and what the interface is told while it does.

 A launch used to end with the process this app started, which on the Epic path is `legendary`
 handing the game to Wine and exiting seconds after Play. Four faults came out of that one
 fact: the spinner on Play was a fixed six seconds and stopped while the game was still
 loading; Play came back to life underneath a running game, so a second press started a second
 copy; a running game vanished from Operations with no way left to stop it; and — once the
 launch was made to last — pressing Play tore the library apart, because the same list that
 puts a downloading game at the top would have pinned the game being *played* there for the
 whole session.

 `Wine.superviseGame` is what follows the game now. What it reports is a phase, and these are
 the rules that hang off it. The watching itself needs a Windows game with a window and cannot
 run here; see `Scripts/check-invariants.sh` for what holds the call sites together.
 */
@Suite("Launch lifecycle")
@MainActor
struct LaunchLifecycleRegressionTests {
    private func game(id: String = "launch-test") -> LocalGame {
        .init(id: id,
              title: "Test Game",
              installationState: .installed(location: .temporaryDirectory.appending(path: "PorTalisticTests-Launch"),
                                            platform: .windows))
    }

    private func makeOperation(_ type: GameOperation.ActiveOperationType) -> GameOperation {
        .init(game: game(), type: type, function: { _ in })
    }

    @Test("A launch starts out preparing, and still says Starting")
    func aLaunchBeginsAsPreparing() {
        let launch = makeOperation(.launch)

        // Pressing Play is the container being set up before it is anything else: settings
        // applied, verbs installed, a prefix booted if it has never run — and a configuration
        // the recovery loop decided after the last failure put in place. What the person is
        // told is still "Starting", because from where they are it is.
        #expect(launch.launchPhase == .preparing)
        // "Running" beside a spinner is what made six seconds look like a signal.
        #expect(launch.statusDescription == String(localized: "Starting"))
    }

    @Test("The configuration being in place is what ends the preparing phase")
    func applyingTheConfigurationChangesThePhase() {
        let launch = makeOperation(.launch)
        launch.noteConfigurationApplied()

        #expect(launch.launchPhase == .starting)
        #expect(launch.statusDescription == String(localized: "Starting"))

        // And it never goes back: a game already on screen is not preparing again.
        launch.noteGameAppeared()
        launch.noteConfigurationApplied()

        #expect(launch.launchPhase == .running)
    }

    @Test("Force Quit is said the moment it is pressed")
    func forceQuittingIsSaidAtOnce() {
        let launch = makeOperation(.launch)
        launch.pendingConfigurationChange = "Tell the game it is running on Windows 10"

        launch.isForceQuitting = true

        // The launch takes a second longer to be gone — it makes sure of the kill first — and
        // "Starting" for that second is what somebody who has just pressed Force Quit on a game
        // that won't finish starting must not read.
        #expect(launch.statusDescription == String(localized: "Force quitting"))

        // Nor that a configuration is being applied to a launch that is being killed.
        #expect(!launch.isApplyingConfiguration)
    }

    /// Until the operation is over, or five seconds have gone.
    private func finish(_ operation: GameOperation) async throws {
        let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
        while !operation.isFinished, .now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(operation.isFinished)
    }

    private struct Complaint: Error {}

    /// Raised from inside an operation's function, so a test knows it is running.
    private final class Flag: @unchecked Sendable {
        private let lock: NSLock = .init()
        private var raised = false
        func raise() { lock.withLock { raised = true } }
        var isRaised: Bool { lock.withLock { raised } }
    }

    @Test("What a force-quit launch throws on its way out is not a failure")
    func whatAForceQuitThrowsIsNotAFailure() async throws {
        // Not every step ends in a `CancellationError` when it is cancelled. A runtime download
        // throws `URLError(.cancelled)`; `legendary`'s output, read after it was killed, can hold
        // an ERROR line. Either one was a failure, and a failure is an alert — for a Force Quit
        // the person had pressed a moment before.
        let running = Flag()
        let launch: GameOperation = .init(game: game(), type: .launch) { _ in
            running.raise()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            throw Complaint()
        }

        launch.start()

        // Inside the function, not merely started: cancelled before it gets there, the operation
        // stops at its own check with a `CancellationError`, and this would pass for any code.
        let entered: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
        while !running.isRaised, .now < entered {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(running.isRaised)

        launch.isForceQuitting = true
        launch.cancel()

        try await finish(launch)
        #expect(launch.error == nil)
    }

    @Test("A launch that fails by itself still says so")
    func aFailureIsStillAFailure() async throws {
        // The other side of the rule above: only a cancelled operation's error goes unreported.
        let launch: GameOperation = .init(game: game(), type: .launch) { _ in throw Complaint() }

        launch.start()

        try await finish(launch)
        #expect(launch.error is Complaint)
    }

    @Test("Only a launch is force-quit", arguments: [GameOperation.ActiveOperationType.install,
                                                     .update,
                                                     .uninstall])
    func onlyLaunchesAreForceQuit(type: GameOperation.ActiveOperationType) {
        let operation = makeOperation(type)
        operation.isForceQuitting = true

        #expect(operation.statusDescription == type.description)
    }

    @Test("A launch says when it is putting a new configuration in place, and when it has")
    func applyingAConfigurationIsAPhaseAndAChange() {
        let launch = makeOperation(.launch)

        // Nothing decided after the last launch: there is nothing being applied, whatever phase
        // this is in. Almost every launch is this one — a game that works is left alone.
        #expect(!launch.isApplyingConfiguration)

        launch.pendingConfigurationChange = "Tell the game it is running on Windows 10"

        #expect(launch.isApplyingConfiguration)

        // And once it is in place, what was new about it is just what the game runs with.
        launch.noteConfigurationApplied()

        #expect(!launch.isApplyingConfiguration)
        #expect(launch.pendingConfigurationChange != nil)
    }

    @Test("Only a launch has a configuration to apply", arguments: [GameOperation.ActiveOperationType.install,
                                                                    .update,
                                                                    .uninstall])
    func onlyLaunchesPrepare(type: GameOperation.ActiveOperationType) {
        let operation = makeOperation(type)
        operation.pendingConfigurationChange = "Tell the game it is running on Windows 10"
        operation.noteConfigurationApplied()

        #expect(operation.launchPhase == .preparing)
        #expect(operation.statusDescription == type.description)
        #expect(!operation.isApplyingConfiguration)
    }

    @Test("The game appearing is what makes it running")
    func theGameAppearingChangesThePhase() {
        let launch = makeOperation(.launch)
        launch.noteGameAppeared()

        #expect(launch.launchPhase == .running)
        #expect(launch.statusDescription == String(localized: "Running"))
    }

    @Test("Saying so twice changes nothing")
    func appearingIsIdempotent() {
        // A two-stage engine produces a second application a few seconds after the first, and
        // the game did not start twice.
        let launch = makeOperation(.launch)
        launch.noteGameAppeared()
        launch.noteGameAppeared()

        #expect(launch.launchPhase == .running)
    }

    @Test("A download is never a game on screen", arguments: [GameOperation.ActiveOperationType.install,
                                                              .update,
                                                              .repair,
                                                              .move,
                                                              .uninstall])
    func onlyLaunchesHavePhases(type: GameOperation.ActiveOperationType) {
        let operation = makeOperation(type)
        operation.noteGameAppeared()

        #expect(operation.launchPhase == .preparing)
        #expect(operation.statusDescription == type.description)
    }

    @Test("A launch is not work on a game's files")
    func aLaunchModifiesNothing() {
        // Three rules read this and only this: quitting stops what is writing to disk and
        // leaves running games alone, the library moves a game to the front only while it is
        // being written to, and Play and Install wait for anything that is.
        #expect(GameOperation.ActiveOperationType.launch.modifiesFiles == false)

        for type in [GameOperation.ActiveOperationType.install, .update, .repair, .move, .uninstall] {
            #expect(type.modifiesFiles, "\(type) writes to the game's files")
        }
    }
}

/**
 Installs that were interrupted by quitting.

 A download is a child process, and quitting used to leave it running, orphaned: it carried on,
 finished, and the game appeared as installed with nothing ever having said it was working.
 Reopening the app showed a game that was neither installed nor installing — the same picture
 as a download that had failed. Quitting now stops the download and `PendingInstalls` is the
 note left behind, so the next launch starts it again where it left off and *shows* it.

 The rules for what a note means are pure; starting the download again needs a storefront.
 */
@Suite("Interrupted installs")
struct InterruptedInstallRegressionTests {
    @Test("An install that was interrupted is started again")
    func interruptedInstallResumes() {
        #expect(PendingInstalls.decision(gameIsInLibrary: true,
                                         gameIsInstalled: false,
                                         gameHasAnOperation: false) == .resume)
    }

    @Test("A game that finished anyway is not installed a second time")
    func finishedInstallIsForgotten() {
        // The case this was found in: the download was orphaned by quitting, finished in the
        // background, and the game was already installed by the time the app reopened.
        #expect(PendingInstalls.decision(gameIsInLibrary: true,
                                         gameIsInstalled: true,
                                         gameHasAnOperation: false) == .forget)
    }

    @Test("A game that has left the library takes its note with it")
    func missingGameIsForgotten() {
        #expect(PendingInstalls.decision(gameIsInLibrary: false,
                                         gameIsInstalled: false,
                                         gameHasAnOperation: false) == .forget)
    }

    @Test("A download already running is not started a second time")
    func operatingGameIsLeftAlone() {
        // Two copies of the same download writing to the same files is worse than a note that
        // waits for the next launch.
        #expect(PendingInstalls.decision(gameIsInLibrary: true,
                                         gameIsInstalled: false,
                                         gameHasAnOperation: true) == .wait)
    }

    // MARK: - The lock a download holds

    @Test("The lock legendary refuses on is told apart from everything else it says")
    func theLockIsTyped() {
        // The line a real machine produced, with a download an earlier session had left
        // running holding the lock. It arrived as a modal at startup, in front of an install
        // nobody had asked for by hand.
        #expect(throws: Legendary.InstalledDataLockError.self) {
            try Legendary.handleCLIErrorOutput(fromStandardErrorOutput: """
                [cli] ERROR: Failed to acquire installed data lock, only one instance of \
                Legendary may install/import/move applications at a time.
                """)
        }
    }

    @Test("Every other error is still an error, and not that one")
    func otherFailuresAreNotTheLock() {
        #expect(throws: (any Error).self) {
            try Legendary.handleCLIErrorOutput(fromStandardErrorOutput: "[cli] ERROR: Login failed.")
        }

        #expect(throws: Never.self) {
            // Progress is not a failure, and reading it as one would fail every download.
            try Legendary.handleCLIErrorOutput(fromStandardErrorOutput: "[DLManager] INFO: = Progress: 47.28% (261/552), Running for 00:00:14, ETA: 00:00:15")
        }
    }

    @Test("A note carries everything the install was asked for")
    func recordSurvivesStorage() throws {
        // It is re-read after a quit, so what it holds has to outlive the process: the
        // platform and the folder especially, since resuming into the wrong place would
        // download the game again beside itself.
        let record: PendingInstalls.Record = .init(gameID: "epic-game",
                                                   storefront: .epicGames,
                                                   platform: .windows,
                                                   baseDirectory: .temporaryDirectory.appending(path: "Games"),
                                                   optionalPackIDs: ["highres"])

        let decoded = try JSONDecoder().decode(PendingInstalls.Record.self,
                                               from: try JSONEncoder().encode(record))

        #expect(decoded == record)
    }
}

/// `legendary cleanup` deletes legendary's temporary files, and one of those is the `.resume`
/// that records which files a download has already finished. The app ran it on every quit,
/// immediately after quitting had stopped the downloads *so that they could write that file*.
///
/// Both halves worked perfectly. Together they meant every interrupted install downloaded the
/// whole game again, and the fault presented as "resume is broken" — which it was not.
@Suite("Housekeeping")
struct LegendaryHousekeepingTests {
    @Test("With nothing downloading there is nothing to lose")
    func cleanUpWhenIdle() {
        #expect(Legendary.mayCleanUp(pendingEpicInstalls: 0, fileOperationsInFlight: 0))
    }

    @Test("An install waiting to be picked up is exactly what this would destroy")
    func pendingInstallStopsIt() {
        // The reported fault, stated as a rule: the note saying "resume this" and the file that
        // makes resuming possible are two halves of one thing, and this used to delete one of
        // them while keeping the other — so the app faithfully resumed a download from zero.
        #expect(!Legendary.mayCleanUp(pendingEpicInstalls: 1, fileOperationsInFlight: 0))
    }

    @Test("Work in progress is writing the files this deletes")
    func runningOperationStopsIt() {
        #expect(!Legendary.mayCleanUp(pendingEpicInstalls: 0, fileOperationsInFlight: 1))
    }

    @Test("A resumed install counts as both, and still only has to count once")
    func resumedInstallStopsIt() {
        // The moment after `PendingInstalls.resumeInterrupted()`: the note has not been
        // forgotten yet and the download it started is already queued.
        #expect(!Legendary.mayCleanUp(pendingEpicInstalls: 1, fileOperationsInFlight: 1))
    }

    @Test("Everything that touches a game's files counts, not just installs",
          arguments: [GameOperation.ActiveOperationType.install,
                      .update,
                      .repair,
                      .move,
                      .uninstall])
    func everyFileOperationCounts(type: GameOperation.ActiveOperationType) {
        // What the guard actually counts. An update and a repair are legendary downloads in
        // their own right — `--repair` is `install --repair` — and they write the same resume
        // state an install does. Counting installs alone left Settings' cleanup button able to
        // wipe a repair's progress, which is the original fault with a different name on it.
        #expect(type.modifiesFiles)
    }

    @Test("Playing a game is not a reason to leave the caches alone")
    func launchDoesNotCount() {
        // The other half: a launch stays in the queue for as long as the game is up, so
        // counting it would mean the housekeeping never ran again for anyone who plays games.
        #expect(!GameOperation.ActiveOperationType.launch.modifiesFiles)
    }
}


/// `Process.terminate()` and `Process.interrupt()` are Objective-C methods that *raise* when
/// the process has not been launched, and an `NSException` is not something Swift can catch.
/// Every call to them in this app was in a `withTaskCancellationHandler`'s `onCancel` — which
/// is precisely where a not-yet-launched process is reachable.
///
/// Force-quitting a running game from Operations hit it: `legendary` had exited seconds after
/// handing the game to Wine, `onCancel` terminated it anyway, and the app died on
/// `*** -[NSConcreteTask terminate]: task not launched`. The crash landed *before* the
/// `Wine.killAll(at:)` on the next line — the only call that actually stops a game — so the
/// launcher became unresponsive and the game carried on running.
///
/// The first test here is the one that matters: before the fix it did not fail, it took the
/// whole test run down with it.
@Suite("Stopping a process")
struct ProcessStopTests {
    @Test("A process that was never launched is left alone, not terminated")
    func neverLaunched() {
        let process: Process = .init()
        process.executableURL = .init(filePath: "/bin/echo")

        process.stopIfRunning()

        // Two things are being claimed. That the line above returned at all — `terminate()`
        // there raises — and that it sent nothing: an unlaunched `Process` reports pid 0, and
        // `kill(0, SIGTERM)` signals every process in this one's group, which includes the
        // test runner doing the asking.
        #expect(!process.isRunning)
    }

    @Test("A process that has already exited is left alone too")
    func alreadyExited() throws {
        // The ordinary case at Force Quit: `legendary` spawns Wine detached and exits, so by
        // the time anyone presses the button the process this app started is long gone.
        let process: Process = .init()
        process.executableURL = .init(filePath: "/bin/echo")
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        process.stopIfRunning()

        #expect(process.terminationStatus == 0)
        #expect(process.terminationReason == .exit)
    }

    @Test("A process that is running is stopped")
    func running() throws {
        // And the guard has not made the whole thing a no-op, which is the way a fix like this
        // fails quietly.
        let process: Process = .init()
        process.executableURL = .init(filePath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()

        process.stopIfRunning()
        process.waitUntilExit()

        #expect(process.terminationReason == .uncaughtSignal)
    }
}


/// A stop can arrive before there is anything to stop. A cancellation handler runs at once, ahead
/// of the task's body, when the task was cancelled before it got there, and while a download's
/// attempt is still being prepared there is no process yet. Two faults came out of that. The stop
/// was lost and the task launched the download anyway, leaving it running with nothing in the app
/// able to stop it. And `interruptThenInsist` took the unlaunched process's pid of 0 for a real
/// one: `pgrep -P 0` is launchd, whose descendants are every app the person has open.
///
/// Nothing here signals a process it did not start. A test that exercised the pid guard for real
/// would, on the day the guard regressed, interrupt everything on the machine running it — so
/// that guard is held by `Scripts/check-invariants.sh`, and these hold everything around it.
@Suite("A stop that comes early")
struct EarlyStopTests {
    /// A `Process` handed to another task. Starting it in one and stopping it from another is
    /// the point of these tests, so the compiler cannot be asked to prove it safe.
    private final class Handed: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    private func sleeper() -> Process {
        let process: Process = .init()
        process.executableURL = .init(filePath: "/bin/sleep")
        process.arguments = ["30"]
        return process
    }

    /// Which processes a launch halted, in order.
    private final class Halted: @unchecked Sendable {
        private let lock: NSLock = .init()
        private var noted: [pid_t] = []
        func note(_ pid: pid_t) { lock.withLock { noted.append(pid) } }
        var pids: [pid_t] { lock.withLock { noted } }
    }

    /// Gone — or dead and not yet reaped, which is gone for every purpose here, and which is for
    /// ever in a container whose first process never reaps.
    private func hasEnded(_ pid: pid_t) async -> Bool {
        let ps: Process = .init()
        ps.executableURL = .init(filePath: "/bin/ps")
        ps.arguments = ["-o", "stat=", "-p", String(pid)]

        guard let state = await ps.runWrapped(timeout: .seconds(5))?.standardOutput else { return false }
        let trimmed = state.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("Z")
    }

    @Test("A stop before the launch means there is no launch")
    func stopFirst() {
        let launch: StoppableLaunch = .init()
        let process = sleeper()
        defer { process.stopIfRunning(SIGKILL) }

        launch.stop()

        #expect(throws: CancellationError.self) { try launch.launch(process) }
        #expect(process.processIdentifier == 0)
    }

    @Test("A stop after the launch reaches the process")
    func stopAfter() async throws {
        let launch: StoppableLaunch = .init()
        let process = sleeper()
        defer { process.stopIfRunning(SIGKILL) }

        try launch.launch(process)
        #expect(process.isRunning)

        launch.stop()

        let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
        while process.isRunning, .now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!process.isRunning)
    }

    @Test("A stop halts the process the way the launch was told to")
    func aStopUsesTheGivenHalt() throws {
        // A download is interrupted, then insisted upon, so that it writes down how far it got.
        // A game being force-quit is killed: there is nothing to write down, and a polite
        // request let `legendary` finish handing the game to Wine while the person watched.
        let halted = Halted()
        let launch: StoppableLaunch = .init(halting: { process in
            halted.note(process.processIdentifier)
            process.stopIfRunning(SIGKILL)
        })

        let process = sleeper()
        defer { process.stopIfRunning(SIGKILL) }

        try launch.launch(process)
        launch.stop()

        #expect(halted.pids == [process.processIdentifier])
        #expect(launch.hasBeenStopped)

        // And a stop that comes first halts nothing, because nothing was launched.
        let early: StoppableLaunch = .init(halting: { halted.note($0.processIdentifier) })
        early.stop()

        let never = sleeper()
        defer { never.stopIfRunning(SIGKILL) }

        #expect(throws: CancellationError.self) { try early.launch(never) }
        #expect(halted.pids.count == 1)
    }

    @Test("A stop that lands while the process is being launched still reaches it")
    func stopDuringLaunch() async throws {
        let launch: StoppableLaunch = .init()
        let process = sleeper()
        defer { process.stopIfRunning(SIGKILL) }

        // After the launch has looked for a stop and before it has recorded what it launched,
        // so the stop finds nothing to interrupt. The launch has to notice it on the way out.
        try launch.launch(process) { launched in
            try launched.run()
            launch.stop()
        }

        let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
        while process.isRunning, .now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!process.isRunning)
    }

    @Test("A stop that lands mid-launch halts it the way the launch was told to")
    func aStopDuringLaunchUsesTheGivenHalt() throws {
        // The stop finds nothing recorded yet, so the launch halts what it launched on its own
        // way out — and has to do it the way it was told to, not the way a download is stopped.
        // A Force Quit landing there was otherwise a polite interrupt, and ten seconds' grace.
        let halted = Halted()
        let launch: StoppableLaunch = .init(halting: { process in
            halted.note(process.processIdentifier)
            process.stopIfRunning(SIGKILL)
        })

        let process = sleeper()
        defer { process.stopIfRunning(SIGKILL) }

        try launch.launch(process) { launched in
            try launched.run()
            launch.stop()
        }

        // Once, by the launch: the stop itself had nothing to halt.
        #expect(halted.pids == [process.processIdentifier])
    }

    @Test("Killing a tree takes what the process started with it")
    func killingATreeTakesItsChildren() async throws {
        // winetricks force-quit mid-verb: the script is a shell, and what it is doing at that
        // moment is a child of it. Killing the script alone left that child to finish.
        let process: Process = .init()
        process.executableURL = .init(filePath: "/bin/sh")
        process.arguments = ["-c", "sleep 30 & sleep 30 & wait"]
        defer { process.stopIfRunning(SIGKILL) }

        try process.run()

        var children: [pid_t] = []
        let started: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
        while children.count < 2, .now < started {
            try await Task.sleep(for: .milliseconds(50))
            children = await ChildProcesses.descendants(of: process.processIdentifier)
        }
        try #require(children.count == 2)

        process.killTree()

        var survivors: [pid_t] = children
        let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
        while process.isRunning || !survivors.isEmpty, .now < deadline {
            try await Task.sleep(for: .milliseconds(50))

            var remaining: [pid_t] = []
            for pid in survivors {
                if !(await hasEnded(pid)) { remaining.append(pid) }
            }
            survivors = remaining
        }

        #expect(!process.isRunning)
        #expect(survivors.isEmpty)

        // Tidied up after a failure — only what was just seen alive, so that a pid freed and
        // handed to somebody else's process in the meantime is never the one signalled.
        survivors.forEach { kill($0, SIGKILL) }
    }

    @Test("A Force Quit is one pair of passes, begun at the press and waited for at the end")
    func aForceQuitIsOnePairOfPasses() async throws {
        // Every cancellation handler a launch has begins it, and the launch finishes it as it
        // ends. That has to be the same passes: a second pair, started by the launch once it had
        // unwound, is what used to come too late — and could land on the next launch.
        final class Passes: @unchecked Sendable {
            private let lock: NSLock = .init()
            private var started = 0
            private var ended = 0
            func start() { lock.withLock { started += 1 } }
            func end() { lock.withLock { ended += 1 } }
            var counts: (started: Int, ended: Int) { lock.withLock { (started, ended) } }
        }

        let passes = Passes()
        let forceQuit: Wine.ForceQuit = .init(running: {
            passes.start()
            try? await Task.sleep(for: .milliseconds(200))
            passes.end()
        })

        forceQuit.begin()
        forceQuit.begin()

        // Begun by the press itself, not when the launch gets round to finishing: a launch stuck
        // on its way out — reading a pipe a surviving Wine process held open — never got there.
        let begun: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
        while passes.counts.started == 0, .now < begun {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(passes.counts.started == 1)

        // Finished from a cancelled task, which is what a force-quit launch is — and still waited
        // for, rather than returning the moment it is asked.
        let finishing = Task { await forceQuit.finish() }
        finishing.cancel()
        await finishing.value

        // Once, and over by the time the launch is.
        #expect(passes.counts.started == 1)
        #expect(passes.counts.ended == 1)

        // And a launch that finishes a Force Quit nothing had begun still gets its passes.
        let unbegun = Passes()
        await Wine.ForceQuit(running: { unbegun.start(); unbegun.end() }).finish()
        #expect(unbegun.counts.ended == 1)
    }

    @Test("pid 0 and launchd are nobody's download")
    func noSuchProcess() async {
        // `kill(pid, 0)` sends nothing, and `descendants(of:)` only asks pgrep, so a regression
        // here fails the test rather than acting on what it finds.
        #expect(!ChildProcesses.isAlive(0))
        #expect(!ChildProcesses.isAlive(-1))
        #expect(await ChildProcesses.descendants(of: 0).isEmpty)
        #expect(await ChildProcesses.descendants(of: 1).isEmpty)
    }

    @Test("A cancelled stream throws rather than returning with its process still running")
    func cancelledStreamThrows() async throws {
        let handed = Handed(sleeper())
        defer { handed.process.stopIfRunning(SIGKILL) }

        let streaming = Task { try await handed.process.runStreamed { _ in nil } }
        try await Task.sleep(for: .milliseconds(300))
        streaming.cancel()

        // Returning instead is what let a caller read `terminationStatus` from a process that
        // was still running — which raises, and cannot be caught.
        await #expect(throws: CancellationError.self) { try await streaming.value }
        #expect(handed.process.isRunning)
    }
}


/// The library is a `Set<Game>` whose `==` is by id alone, and `Set.update(with:)` *replaces*
/// the member it matches rather than keeping it. So a freshly built catalogue entry — which
/// carries nothing but id, title and "not installed" — silently took the place of the
/// library's own object on every refresh, for every game not currently installed.
@Suite("Refreshing the library")
struct LibraryRefreshTests {
    @Test("legendary's third platform string is a Windows game, not an unknown one")
    func win32IsWindows() {
        // Unhandled, `Win32` made a 32-bit game look uninstalled for good: it was dropped from
        // the installed list by a `compactMap` that said nothing, so the interface offered to
        // download a game that was already on disk.
        #expect(Legendary.matchPlatformString(for: "Win32") == .windows)
        #expect(Legendary.matchPlatformString(for: "Windows") == .windows)
        #expect(Legendary.matchPlatformString(for: "Mac") == .macOS)
        #expect(Legendary.matchPlatformString(for: "Linux") == nil)
    }

    @MainActor
    @Test("The catalogue keeps what the person did to a game, and still records an uninstall")
    func catalogueIsAbsorbedRatherThanImposed() throws {
        // Both halves of the rule at once. The library's own object has a favourite on it and
        // a game that legendary has stopped listing; the catalogue entry has neither, because
        // a catalogue entry never does — it is built fresh from Epic's metadata every time.
        //
        // These assertions guard two different regressions and do not all fail together.
        // Favourite and identity catch a return to replacing. Demotion catches somebody
        // deciding the `installationState` assignment is redundant next to the merge rule —
        // replacing would *also* leave the game uninstalled, so demotion passing on its own
        // says nothing about whether the merge is still there.
        let loved: EpicGamesGame = .init(id: "loved",
                                         title: "Loved",
                                         installationState: .uninstalled)
        loved.isFavourited = true

        let removed: EpicGamesGame = .init(id: "removed",
                                           title: "Removed",
                                           installationState: .installed(location: .temporaryDirectory,
                                                                         platform: .windows))

        var library: Set<Game> = [loved, removed]

        try GameDataStore.absorb(catalogue: [
            .init(id: "loved", title: "Loved", installationState: .uninstalled),
            .init(id: "removed", title: "Removed", installationState: .uninstalled),
            .init(id: "new", title: "New", installationState: .uninstalled)
        ] as [EpicGamesGame], into: &library)

        // Kept, and it is still the same object — the interface is holding a reference to it.
        #expect(library.first { $0.id == "loved" }?.isFavourited == true)
        #expect(library.first { $0.id == "loved" } === loved)

        // Demoted, because legendary no longer lists it. The merge rule alone would have kept
        // `.installed` here, which is why the assignment is not redundant.
        #expect(library.first { $0.id == "removed" }?.isInstalled == false)

        // And something the library had never seen is simply added.
        #expect(library.contains { $0.id == "new" })
    }

    @Test("Updating a set swaps the object out — which is why a refresh has to merge")
    func updateReplacesTheMember() {
        // Not a test of our code so much as of the assumption underneath it, written down
        // because getting this backwards is what caused the fault: `insert` keeps the member
        // it finds, `update` replaces it, and with id-only equality "equal" does not mean
        // "interchangeable".
        let kept: EpicGamesGame = .init(id: "game", title: "Game", installationState: .uninstalled)
        kept.isFavourited = true

        var library: Set<Game> = [kept]
        let fresh: EpicGamesGame = .init(id: "game", title: "Game", installationState: .uninstalled)

        library.update(with: fresh)

        #expect(library.first?.isFavourited == false)
        #expect(library.first !== kept)
    }
}

/// An install the person stops is deliberately never resumed, so whatever it had written is
/// dead weight — and it was being left on disk with nothing in the interface to say so. Finding
/// it again means knowing where the tool put it, and for Epic that is not derivable: legendary
/// names the folder itself.
@Suite("Where a download went")
struct DownloadDestinationTests {
    private static let base: URL = .init(filePath: "/Volumes/Games")

    @Test("legendary's own announcement is where the folder name comes from")
    func readsLegendarysInstallPath() {
        let destination: DownloadDestination = .init(under: Self.base)

        destination.note(.init(stream: .standardError,
                               output: "[Core] INFO: Install path: /Volumes/Games/BioshockInfiniteCompleteEdition"))

        // Note the folder: "BioShock Infinite: Complete Edition" became
        // "BioshockInfiniteCompleteEdition". Not the title with the spaces taken out — the
        // capital S is gone — which is exactly why this is read rather than derived.
        #expect(destination.url?.path == "/Volumes/Games/BioshockInfiniteCompleteEdition")
    }

    @Test("A path with spaces survives, and trailing whitespace does not")
    func trimsWithoutLosingSpaces() {
        let destination: DownloadDestination = .init(under: Self.base)
        destination.note(.init(stream: .standardError,
                               output: "[Core] INFO: Install path: /Volumes/Games/Street Racing Syndicate  \r"))

        // The path arrives down a pipe, and this codebase already deals with `\r`-terminated
        // lines elsewhere. A trailing space is the difference between removing a folder and
        // removing nothing at all.
        #expect(destination.url?.path == "/Volumes/Games/Street Racing Syndicate")
    }

    @Test("Everything else legendary says is not a path", arguments: [
        "[Core] INFO: Trying to re-use existing login session...",
        "[DLManager] INFO: = Progress: 47.28% (261/552), Running for 00:00:14, ETA: 00:00:15",
        "[cli] INFO: Preparing download for \"Control\"..."
    ])
    func ignoresEverythingElse(line: String) {
        // Guessing wrong here means deleting the wrong folder, so it only ever believes the
        // one line that names the destination.
        let destination: DownloadDestination = .init(under: Self.base)
        destination.note(.init(stream: .standardError, output: line))

        #expect(destination.url == nil)
    }

    @Test("Standard output is not where legendary says this")
    func ignoresStandardOutput() {
        let destination: DownloadDestination = .init(under: Self.base)
        destination.note(.init(stream: .standardOutput, output: "Install path: /tmp/somewhere"))

        #expect(destination.url == nil)
    }

    @Test("Nothing outside the install directory is this download's to name", arguments: [
        "/Volumes/Games",           // the install directory itself: every game in it
        "/Volumes",                 // above it
        "/Volumes/GamesElsewhere",  // a sibling that merely starts the same way
        "/tmp/somewhere"
    ])
    func refusesAnythingOutsideTheBase(path: String) {
        // The one that matters: the GOG path builds `baseDirectory + folderName`, and a
        // `folderName` that is empty, "." or "/" resolves to the install directory itself.
        // Removing that removes every game in it — and it needs no bug here to happen, only a
        // malformed field in somebody else's metadata.
        let destination: DownloadDestination = .init(under: Self.base)
        destination.set(.init(filePath: path))

        #expect(destination.url == nil)
    }

    @Test("A folder name that resolves to nothing resolves to the install directory",
          arguments: ["", ".", "/"])
    func refusesAnEmptyFolderName(folderName: String) {
        let destination: DownloadDestination = .init(under: Self.base)
        destination.set(Self.base.appending(path: folderName))

        #expect(destination.url == nil)
    }
}

/// Removing a stopped install's download is the only thing in this app that destroys something
/// irreversibly, and unlike every other fault in this area it would do it silently and look
/// correct doing it. So the rule is asserted directly: of the sixteen ways the four facts can
/// come out, exactly one permits deleting anything.
@Suite("Discarding a stopped download")
struct DiscardDecisionTests {
    @Test("Only one combination of facts permits removing anything")
    func exactlyOneAllClear() {
        var permitting: [[Bool]] = .init()

        for settled in [true, false] {
            for claimed in [true, false] {
                for installed in [true, false] {
                    for exists in [true, false] where GameOperationManager.mayDiscardPartialDownload(
                        folderHasSettled: settled,
                        isClaimed: claimed,
                        isInstalled: installed,
                        exists: exists
                    ) {
                        permitting.append([settled, claimed, installed, exists])
                    }
                }
            }
        }

        // Settled, unclaimed, not installed, and there. Nothing else.
        #expect(permitting == [[true, false, false, true]])
    }

    @Test("A folder still being written to is never removed")
    func stillWritingIsNeverRemoved() {
        // The case that matters most: `hasSettled` returns false both when the folder is
        // changing and when the wait ran out, and neither is permission. A download the person
        // restarted writes into this very folder.
        #expect(!GameOperationManager.mayDiscardPartialDownload(folderHasSettled: false,
                                                               isClaimed: false,
                                                               isInstalled: false,
                                                               exists: true))
    }

    @Test("legendary's record goes whenever the download does — even when the folder already has")
    func resumeRecordFollowsTheDecisionNotTheFolder() {
        var permitting: [[Bool]] = .init()

        for settled in [true, false] {
            for claimed in [true, false] {
                for installed in [true, false] where GameOperationManager.mayDiscardResumeState(
                    folderHasSettled: settled,
                    isClaimed: claimed,
                    isInstalled: installed
                ) {
                    permitting.append([settled, claimed, installed])
                }
            }
        }

        // The same facts as the folder rule, without "does the folder exist". A folder removed
        // by hand is the case that matters: the record then lists files that are not there,
        // and a later download trusts it and skips a half-written one as finished.
        #expect(permitting == [[true, false, false]])
    }

    @Test("A game that is actually installed is never removed")
    func installedIsNeverRemoved() {
        #expect(!GameOperationManager.mayDiscardPartialDownload(folderHasSettled: true,
                                                               isClaimed: false,
                                                               isInstalled: true,
                                                               exists: true))
    }
}

/// legendary reports progress over what is left to fetch in *this* run. A download quit at 15%
/// and resumed kept its bytes and carried on growing its folder from where it was — the resume
/// worked — while the progress bar started again from 1%, because 1% of the remainder is what
/// legendary was reporting.
///
/// The fixtures are what legendary actually prints, including the thing that makes this easy
/// to get wrong: on a resumed run `Install size` is what is *left*, not the whole game. The first
/// version of these tests printed the whole game there, and so agreed perfectly with a formula
/// that showed 100% for any download resumed past halfway.
@Suite("Resumed download progress")
struct ResumeBaselineTests {
    /// A resumed run's analysis, as legendary prints it.
    private static func resumed(remainingMiB: Double, skippedMiB: Double, files: Int = 1234) -> Legendary.ResumeBaseline {
        let baseline: Legendary.ResumeBaseline = .init()
        baseline.note("[DLM] INFO: Skipping \(files) files based on resume data.")
        baseline.note("[cli] INFO: Install size: \(String(format: "%.2f", remainingMiB)) MiB")
        baseline.note("[cli] INFO: Reusable size: 0.00 MiB (chunks) / \(String(format: "%.2f", skippedMiB)) MiB (unchanged / skipped)")
        return baseline
    }

    /// BioShock Infinite: 45,336.52 MiB in all, 6,841.20 already down — about fifteen percent.
    private static let atFifteenPercent = resumed(remainingMiB: 38_495.32, skippedMiB: 6_841.20)

    @Test("A resumed download starts where it stopped, not at zero")
    func resumeStartsWhereItStopped() {
        // The reported fault, exactly: this run is at 0%, the game is at ~15%.
        #expect(abs(Self.atFifteenPercent.overall(fromRun: 0) - 15.09) < 0.01)
    }

    @Test("And finishes at a hundred, not past it")
    func finishesAtAHundred() {
        #expect(abs(Self.atFifteenPercent.overall(fromRun: 100) - 100) < 0.0001)
    }

    @Test("Half of what was left is half of the rest")
    func halfOfTheRemainder() {
        #expect(abs(Self.atFifteenPercent.overall(fromRun: 50) - 57.545) < 0.01)
    }

    @Test("Resumed past halfway is not already finished")
    func pastHalfwayIsNotFinished() {
        // What dividing by the remainder alone produced: 60% done, and the bar read 100% for
        // the whole of the rest of the download.
        let baseline = Self.resumed(remainingMiB: 18_134.61, skippedMiB: 27_201.91)

        #expect(abs(baseline.overall(fromRun: 0) - 60) < 0.01)
        #expect(abs(baseline.overall(fromRun: 50) - 80) < 0.01)
    }

    @Test("A fresh install is reported exactly as legendary reports it")
    func freshInstallIsUntouched() {
        let baseline: Legendary.ResumeBaseline = .init()
        baseline.note("[cli] INFO: Install size: 45336.52 MiB")
        baseline.note("[cli] INFO: Reusable size: 0.00 MiB (chunks) / 0.00 MiB (unchanged / skipped)")

        #expect(baseline.overall(fromRun: 37) == 37)
    }

    @Test("Optional packs left out are not progress")
    func selectiveDownloadIsNotAResume() {
        // Files an install tag or a prefix leaves out land in the same "skipped" figure. Without
        // the resume line to say otherwise, a fresh selective download would open at 30%.
        let baseline: Legendary.ResumeBaseline = .init()
        baseline.note("[DLM] INFO: Found 812 files to skip based on install tag.")
        baseline.note("[cli] INFO: Install size: 30000.00 MiB")
        baseline.note("[cli] INFO: Reusable size: 0.00 MiB (chunks) / 13000.00 MiB (unchanged / skipped)")

        #expect(baseline.overall(fromRun: 5) == 5)
    }

    @Test("A resume file that skipped nothing is not a resume")
    func staleResumeFileIsNotAResume() {
        // legendary prints the resume line whenever a resume file exists — including one whose
        // files are all gone — so it is the count that decides, not the line.
        let baseline = Self.resumed(remainingMiB: 45_336.52, skippedMiB: 900, files: 0)

        #expect(baseline.overall(fromRun: 12) == 12)
    }

    @Test("Without the figures, nothing is guessed")
    func missingFiguresPassThrough() {
        let neither: Legendary.ResumeBaseline = .init()
        #expect(neither.overall(fromRun: 42) == 42)
    }
}

/// The Dock icon kept a stopped download's badge — its ring and its count — until the app quit.
/// DockProgress redraws only when the progress it follows changes, and a stopped download's never
/// changes again, so nothing ever took it down.
///
/// Taking it down is `GameOperationManager.updateDockProgress()`, which draws on the real Dock and
/// is held in place by `Scripts/check-invariants.sh`. What it follows and what it counts is
/// decided here.
@Suite("The Dock icon's download badge")
@MainActor
struct DockBadgeTests {
    private func makeOperation(_ type: GameOperation.ActiveOperationType,
                               function: @escaping (Progress) async throws -> Void = { _ in }) -> GameOperation {
        .init(game: LocalGame(id: "dock-badge-test",
                              title: "Test Game",
                              installationState: .installed(location: .temporaryDirectory.appending(path: "PorTalisticTests-Dock"),
                                                            platform: .windows)),
              type: type,
              function: function)
    }

    @Test("A download that is stopped takes the badge down at once")
    func stoppingTakesTheBadgeDown() {
        let download = makeOperation(.install)
        #expect(GameOperationManager.dockBadge(for: [download])?.count == 1)

        download.cancel()

        // The moment Stop is pressed, not when the download finally ends — that waits for the
        // tool to stop, which takes seconds, and the badge left standing is what was reported.
        #expect(GameOperationManager.dockBadge(for: [download])?.count == nil)
    }

    @Test("The badge counts what is still going, and follows it")
    func theCountDropsWithEachStop() {
        let first = makeOperation(.install)
        let second = makeOperation(.update)
        #expect(GameOperationManager.dockBadge(for: [first, second])?.count == 2)

        first.cancel()
        let badge = GameOperationManager.dockBadge(for: [first, second])

        #expect(badge?.count == 1)
        #expect(badge?.following.id == second.id)
    }

    @Test("A game being played is not a download")
    func aLaunchHasNoBadge() {
        #expect(GameOperationManager.dockBadge(for: [makeOperation(.launch)])?.count == nil)
    }

    @Test("The badge follows the download that is running, not the one queued first")
    func followsTheRunningDownload() async throws {
        let waiting = makeOperation(.install)
        let running = makeOperation(.update) { _ in try await Task.sleep(for: .seconds(30)) }

        running.start()
        defer { running.cancel() }

        let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
        while !running.isExecuting, .now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(running.isExecuting)

        #expect(GameOperationManager.dockBadge(for: [waiting, running])?.following.id == running.id)
    }

    @Test("An uninstall running first doesn't hide a download's ring")
    func downloadsComeBeforeWorkWithoutProgress() async throws {
        // An uninstall or a move never reports progress. Following one because it happened to
        // be running, or queued, ahead of a download left the download with no ring at all.
        let uninstall = makeOperation(.uninstall) { _ in try await Task.sleep(for: .seconds(30)) }
        let download = makeOperation(.install)

        uninstall.start()
        defer { uninstall.cancel() }

        let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
        while !uninstall.isExecuting, .now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(uninstall.isExecuting)

        let badge = GameOperationManager.dockBadge(for: [uninstall, download])
        #expect(badge?.following.id == download.id)
        #expect(badge?.count == 2)
    }
}

/// legendary logs at ERROR level for trouble it deals with itself, and exits 0 after trouble it
/// does not. So neither "any ERROR line fails" nor "exit 0 succeeds" is right, and the lines are
/// judged one by one — each list below is verbatim from this build of legendary.
@Suite("legendary's error lines")
struct LegendaryErrorLineTests {
    @Test("Trouble legendary recovers from by itself is not a failure", arguments: [
        "[DLManager] ERROR: Download for 0A1B2C3D4E5F failed, retrying...",
        "[DLManager] ERROR: Job for BioShockInfinite.exe failed with: TimeoutError(), fetching next one...",
        "[cli] ERROR: Unable to get SDL data for Fortnite",
        "[Core] ERROR: Could not load old manifest, patching will not work!",
        "[cli] ERROR: File does not match hash: Binaries/Win32/XGame.exe",
        "[cli] ERROR: File is missing: Content/Movies/intro.bik",
        "[cli] ERROR: Other failure (see log), treating file as missing: Content/a.upk",
        "[cli] ERROR: Verification failed, 3 file(s) corrupted, 1 file(s) are missing."
    ])
    func recoverableLinesPass(line: String) {
        // Before the pipe was drained to the end, the first of these stopped the app reading
        // legendary's output at all — and a download blocked on a full pipe never finishes.
        #expect(throws: Never.self) {
            try Legendary.handleCLIErrorOutput(fromStandardErrorOutput: line)
        }
    }

    @Test("Trouble legendary gives up on is still a failure, even though it exits 0", arguments: [
        "[cli] ERROR: The selected title has to be installed via a third-party store: Origin",
        "[DLManager] CRITICAL: Writing for Binaries/Win32/XGame.exe failed!",
        "[cli] CRITICAL: Manifest appears to be missing! To repair, run \"legendary repair BioShock --repair-and-update\"",
        "[cli] ERROR: Install path \"/Volumes/Games/BioShock\" does not exist, make sure all necessary mounts are available."
    ])
    func fatalLinesStillFail(line: String) {
        // The case against trusting the exit code: legendary logs each of these and then exits
        // 0. Treated as success, a third-party title "installed" with nothing on disk, its
        // pending note was forgotten and the app announced it was ready.
        #expect(throws: (any Error).self) {
            try Legendary.handleCLIErrorOutput(fromStandardErrorOutput: line)
        }
    }

    @Test("The lock is still its own thing, and still waited out")
    func lockIsStillTheLock() {
        #expect(throws: Legendary.InstalledDataLockError.self) {
            try Legendary.handleCLIErrorOutput(fromStandardErrorOutput: """
                [cli] ERROR: Failed to acquire installed data lock, only one instance of \
                Legendary may install/import/move applications at a time.
                """)
        }
    }
}

/**
 How a bounded run ended — exited, stopped, or never started.

 The last two used to be one `false`, so a Wine that failed to launch in its first millisecond
 was reported as a first boot that had been working for five minutes, and nothing it said was
 kept either way. That is how "Container unable to boot" arrived on a virtual Mac with no log
 anywhere to explain it.
 */
@Suite("A bounded run says how it ended")
struct BoundedRunOutcomeTests {
    @Test("A process that can't be started is not reported as one that ran out of time")
    func couldNotStartIsNotATimeout() async throws {
        let process: Process = .init()
        process.executableURL = URL(filePath: "/nonexistent/PorTalisticTests-\(UUID().uuidString)")

        let run = try #require(await process.runWrappedKeepingOutput(timeout: .seconds(5)))

        guard case .couldNotStart = run.outcome else {
            Issue.record("expected couldNotStart, got \(run.outcome)")
            return
        }
    }

    @Test("A process that finishes keeps its output")
    func exitedKeepsOutput() async throws {
        let process: Process = .init()
        process.executableURL = URL(filePath: "/bin/echo")
        process.arguments = ["portalistic"]

        let run = try #require(await process.runWrappedKeepingOutput(timeout: .seconds(10)))

        #expect(run.outcome == .exited)
        #expect(run.result.standardOutput?.contains("portalistic") == true)
    }

    @Test("A process that runs past its budget is stopped, and what it said by then is kept")
    func killedKeepsWhatItSaid() async throws {
        let process: Process = .init()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "echo started; sleep 30"]

        let run = try #require(await process.runWrappedKeepingOutput(timeout: .seconds(1)))

        #expect(run.outcome == .killed)
        #expect(run.result.standardOutput?.contains("started") == true,
                "a boot that ran out of time used to leave nothing behind")
    }
}
