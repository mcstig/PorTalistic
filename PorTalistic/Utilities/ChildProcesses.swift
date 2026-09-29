//
//  ChildProcesses.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import Foundation
import OSLog

/**
 The child processes this app has running, so that quitting can be sure none outlive it.

 `legendary` and `gogdl` write down where they got to when they are interrupted, and that takes
 a moment — so quitting asks them to stop and then waits (see
 ``GameOperationManager/stopFileOperationsForQuit()``). What it could not do was be *sure*: a
 download still shutting down when the app terminated carried on without it, finished with
 nothing to report it, and — in legendary's case — kept its installed-games lock, so the next
 launch's resumed install was refused outright with "only one instance of Legendary may
 install/import/move applications at a time", in a modal, at startup.

 This is the end of that wait: whatever is still running gets terminated, and then killed.
 */
enum ChildProcesses {
    private static let log: Logger = .custom(category: "ChildProcesses")

    private static let lock: NSLock = .init()
    nonisolated(unsafe) private static var live: [Process] = .init()

    static func register(_ process: Process) {
        lock.withLock { live.append(process) }
    }

    static func forget(_ process: Process) {
        lock.withLock { live.removeAll { $0 === process } }
    }

    /// Whether anything this app started is still running.
    ///
    /// Quitting used to ask the operation queue this question, and the queue does not know:
    /// the app starts `legendary` for its own errands — housekeeping, cloud saves — and none
    /// of those is an operation. An empty queue is not an empty machine, and quitting past one
    /// of these is how the app orphaned its own child.
    static var hasLiveProcesses: Bool {
        lock.withLock { live.contains(where: \.isRunning) }
    }

    /// Stop anything still running: terminate, and kill what doesn't take the hint.
    ///
    /// - Returns: how many processes had to be stopped this way, which is a number that should
    ///   be zero on an ordinary quit.
    @discardableResult
    static func stopSurvivors(within grace: Duration = .seconds(2)) async -> Int {
        let survivors = lock.withLock { live.filter(\.isRunning) }
        guard !survivors.isEmpty else { return 0 }

        log.notice("\(survivors.count, privacy: .public) child process(es) outlived the wait; stopping them")
        // Interrupted, not terminated. These are `legendary` and `gogdl`, which are Python:
        // `SIGINT` raises `KeyboardInterrupt`, which both catch to write down where a download
        // got to, and `SIGTERM` does not — so terminating here is how a download that quitting
        // had carefully stopped still came back from nothing. `stopOrphans` below has always
        // known this; the quit path did not. (`SIGKILL` still follows for anything that
        // ignores it.)
        //
        // And `stopIfRunning` rather than `terminate()`, which raises on a process that is not
        // running: between the filter above and this line one of them may have exited on its
        // own.
        survivors.forEach { $0.stopIfRunning(SIGINT) }

        let deadline: ContinuousClock.Instant = .now.advanced(by: grace)
        while .now < deadline, survivors.contains(where: \.isRunning) {
            try? await Task.sleep(for: .milliseconds(100))
        }

        for survivor in survivors where survivor.isRunning {
            log.notice("Killing [\(survivor.processIdentifier, privacy: .public)]")
            kill(survivor.processIdentifier, SIGKILL)
        }

        return survivors.count
    }

    // MARK: - Left over from a previous session

    /// Stop the downloads an earlier session left behind.
    ///
    /// The case this exists for, found on a real machine: `legendary` still installing a game
    /// into an external drive, with eighteen worker processes under it, started by a build of
    /// this app that had long since quit. It was downloading where nobody could see it, and it
    /// held legendary's installed-games lock — so the install this app resumed on the next
    /// launch was refused outright, in a modal, at startup.
    ///
    /// Recognised by parentage rather than by name: a process running one of our own tools
    /// whose parent is `launchd` belonged to an app that is gone. Our own children are parented
    /// to us, so nothing of this session's is ever touched — and this runs before anything is
    /// started anyway.
    ///
    /// Matched on the tool's own last two path components (`legendary/cli`, `gogdl/gogdl_arm64`)
    /// rather than on its full path, because the orphan is by definition from an *earlier*
    /// build: a rebuild, an update, or Gatekeeper's translocated copy all run the same tool from
    /// a different absolute path, and the full path matched none of them. The cost of the looser
    /// match is that a download orphaned by some *other* app built on the same tools would be
    /// stopped too — it is a download nobody is looking after either, and it is resumable.
    ///
    /// Interrupted first, because both tools write down where they got to when asked to stop,
    /// and a download killed outright starts again from nothing.
    ///
    /// In rounds, because a download is not one process: legendary had eighteen helpers under
    /// it, and those are children of *it*, not of `launchd` — they only become visible to this
    /// once their parent has gone. Each round scans again rather than re-using what the last
    /// one found, which is also what stops a signal landing on a pid macOS has recycled in the
    /// meantime.
    ///
    /// - Returns: how many actually went away.
    @discardableResult
    static func stopOrphans(of executables: [URL], within grace: Duration = .seconds(8)) async -> Int {
        let paths = Set(executables.map { $0.pathComponents.suffix(2).joined(separator: "/") })
        var stopped = 0

        for round in 1...3 {
            let orphans = await parentlessProcesses(running: paths)
            guard !orphans.isEmpty else { break }

            log.notice("""
                \(orphans.count, privacy: .public) process(es) left running by an earlier session \
                (round \(round, privacy: .public)); stopping them
                """)

            // One chance to stop tidily, then not.
            let signal = round == 1 ? SIGINT : SIGKILL

            for orphan in orphans {
                // `errno` is read once and kept: it is global, and the log line that reports it
                // is built after the call — by which time anything in between has overwritten it.
                let outcome = kill(orphan, signal)
                let code = errno

                // `ESRCH` is the one that means it went away on its own, which is not a problem.
                guard outcome != 0, code != ESRCH else { continue }
                log.warning("Couldn't signal [\(orphan, privacy: .public)]: \(String(cString: strerror(code)), privacy: .public)")
            }

            let deadline: ContinuousClock.Instant = .now.advanced(by: round == 1 ? grace : .seconds(2))
            while .now < deadline, orphans.contains(where: isAlive) {
                try? await Task.sleep(for: .milliseconds(250))
            }

            let survivors = orphans.filter(isAlive)
            stopped += orphans.count - survivors.count

            // Nothing died and nothing will: a process this app may not signal, or a zombie.
            // Waiting out the remaining rounds would only delay the install that is waiting for
            // this.
            if survivors.count == orphans.count, round > 1 {
                log.warning("\(survivors.count, privacy: .public) process(es) could not be stopped; leaving them")
                break
            }
        }

        return stopped
    }

    /// Every process descended from `pid`, children first.
    ///
    /// Downloads are not one process. `legendary` runs a fleet of workers and `gogdl` does the
    /// same, and they are children of *the tool*, not of this app — so stopping the tool and
    /// stopping the download are two different things. Signalling only the parent left the
    /// workers writing: a cancelled download carried on filling its folder, and the clean-up
    /// that followed deleted files out from under processes that promptly wrote them again.
    ///
    /// Has to be asked *before* the parent goes. Once it does, its workers are reparented to
    /// `launchd` and are no longer attributable to the download they belonged to — which is
    /// what leaves ``stopOrphans(of:within:)`` to sweep them up at the next launch instead.
    static func descendants(of pid: pid_t) async -> [pid_t] {
        // Never launchd's family, which is everyone's. A process that has not been launched
        // reports a pid of 0, and `pgrep -P 0` answers with launchd — so asking about one
        // named every app the person had open as a download's workers.
        guard pid > 1 else { return [] }

        var found: [pid_t] = .init()
        var frontier: [pid_t] = [pid]

        // Bounded: a download's worker tree is one level deep, and anything claiming to be
        // deeper than a handful is a cycle nobody should be following.
        for _ in 1...4 {
            guard !frontier.isEmpty else { break }

            var next: [pid_t] = .init()
            for parent in frontier {
                next += await children(of: parent)
            }

            next.removeAll { found.contains($0) || $0 == pid || $0 <= 1 || $0 == getpid() }
            guard !next.isEmpty else { break }

            found += next
            frontier = next
        }

        return found
    }

    private static func children(of pid: pid_t) async -> [pid_t] {
        let process: Process = .init()
        process.executableURL = .init(filePath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]

        guard let output = await process.runWrapped(timeout: .seconds(5))?.standardOutput else {
            return .init()
        }

        return output.split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    nonisolated(unsafe) private static var stopping: [pid_t] = .init()

    /// Note that these processes are being stopped, so that whatever wants to clean up after
    /// them can wait for exactly them.
    static func noteStopping(_ pids: [pid_t]) {
        lock.withLock { stopping += pids.filter { $0 > 0 && !stopping.contains($0) } }
    }

    /// Stop tracking these, once whatever was stopping them has finished trying.
    ///
    /// Only the ones that have actually gone: a pid still alive is still worth waiting for.
    /// Without this the set only ever grew — a cancelled *update* notes pids and never
    /// triggers a clean-up to prune them — and macOS recycles pids, so in a long session
    /// `stoppingProcessesRemain` would start answering yes about somebody else's process and
    /// quietly switch the clean-up off for good.
    static func noteStopped(_ pids: [pid_t]) {
        lock.withLock { stopping.removeAll { pids.contains($0) && !isAlive($0) } }
    }

    /// Whether anything a cancellation is stopping is still alive.
    ///
    /// The precise question, and the reason it replaced "is any legendary running anywhere":
    /// this app starts legendary for its own errands too — cloud saves at launch, with a
    /// ten-minute budget — so the broad question answered yes for reasons that had nothing to
    /// do with the download being stopped, and the clean-up that waited on it gave up and
    /// silently did nothing.
    static var stoppingProcessesRemain: Bool {
        lock.withLock {
            stopping.removeAll { !isAlive($0) }
            return !stopping.isEmpty
        }
    }

    /// Whether any of `executables` is running at all, whoever started it.
    ///
    /// Deliberately not ``hasLiveProcesses``, which only knows what this app has registered —
    /// and registration ends the moment a cancelled download returns, which is *before* the
    /// tool has gone. Nor the folder's modification date, which a download does not touch while
    /// it fills files that already exist: a lull read as "finished", the folder was removed, and
    /// the download that had never stopped created it again and carried on.
    ///
    /// Answers for every download, not just this one, so a second game downloading means this
    /// says yes. That is the safe way round — the caller declines to delete — and declining
    /// costs disk space, where the alternative costs somebody their download.
    static func anyIsRunning(of executables: [URL]) async -> Bool {
        let paths = Set(executables.map { $0.pathComponents.suffix(2).joined(separator: "/") })
        guard !paths.isEmpty else { return false }

        let process: Process = .init()
        process.executableURL = .init(filePath: "/usr/bin/pgrep")
        process.arguments = ["-l", "-f", "."]

        guard let output = await process.runWrapped(timeout: .seconds(5))?.standardOutput else {
            // Couldn't look. "I don't know" is not "nothing is running".
            log.warning("pgrep didn't answer; assuming a download is still in progress")
            return true
        }

        return output.split(whereSeparator: \.isNewline).contains { line in
            paths.contains { line.contains($0) }
        }
    }

    /// Whether anything on this Mac is running a command line containing `needle` and none of
    /// `ignoring`.
    ///
    /// The question the end of a launch turns on. When the supervision gives up waiting for a
    /// game's window, "it never started" and "it is still starting" look identical from where
    /// it stands — a large game off a slow disk, building shaders, with its window still to
    /// come — and one of those is a game the app would otherwise reconfigure while the person
    /// is watching it load.
    ///
    /// Matching is done here, as text and without case, rather than by a pattern handed to the
    /// tool: a build directory called "Wine 11.16 (DXMT)" is not a valid regular expression,
    /// and a Windows path is spelled however the program that wrote it felt like spelling it.
    ///
    /// Three details in the invocation, each of which has a way of failing silently:
    ///
    /// - `ps` rather than `pgrep -l -f .`, because `-l` prints the whole command line only on
    ///   BSD and only next to `-f`. A version printing process names would answer "nothing is
    ///   running" every time, to a question whose safe answer is the opposite.
    /// - `-ww`, because BSD `ps` truncates the last column to the terminal width and falls back
    ///   to 79 characters when its output isn't a terminal — which is exactly how this runs. A
    ///   needle further along the line than that would never be found, for ever, with nothing
    ///   in the log to say why.
    /// - not being able to look at all is not "nothing is running": that answer is `true`, and
    ///   `true` is what concludes nothing.
    static func anyCommandLineContains(_ needle: String, ignoring: [String] = []) async -> Bool {
        guard !needle.isEmpty else { return false }

        let process: Process = .init()
        process.executableURL = .init(filePath: "/bin/ps")
        process.arguments = ["-Axww", "-o", "args="]

        guard let output = await process.runWrapped(timeout: .seconds(5))?.standardOutput else {
            log.warning("ps didn't answer; assuming what was started is still running")
            return true
        }

        let needle = needle.lowercased()
        let ignoring = ignoring.map { $0.lowercased() }

        return output.split(whereSeparator: \.isNewline).contains { line in
            let line = line.lowercased()
            return line.contains(needle) && !ignoring.contains(where: { line.contains($0) })
        }
    }

    /// Processes parented by `launchd` — so nobody this app knows is looking after them — that
    /// are running one of `paths`.
    ///
    /// The matching is done here rather than by `pgrep`: `-f` takes an extended regular
    /// expression, and a path interpolated into one means a bracket or a plus sign in wherever
    /// the app happens to live changes what it matches. So `pgrep` is asked for every
    /// launchd-parented process and its command line, and the paths are compared as text.
    private static func parentlessProcesses(running paths: Set<String>) async -> [pid_t] {
        let process: Process = .init()
        process.executableURL = .init(filePath: "/usr/bin/pgrep")
        process.arguments = ["-P", "1", "-l", "-f", "."]

        guard let output = await process.runWrapped(timeout: .seconds(5))?.standardOutput else {
            // Said out loud: "nothing was left running" and "we never managed to look" are the
            // same silence otherwise, and the second one ends in a download nobody can see.
            log.warning("pgrep didn't answer; anything an earlier session left running is still running")
            return .init()
        }

        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)

            guard parts.count == 2,
                  let pid = pid_t(parts[0]),
                  paths.contains(where: { parts[1].contains($0) }) else { return nil }

            return pid
        }
    }

    /// Whether a process still exists. Signal 0 checks without sending anything.
    ///
    /// Not private: stopping a download has to ask it about the download's workers, which are
    /// children of the tool rather than of this app. See
    /// ``Foundation/Process/interruptThenInsist(within:)``.
    ///
    /// Only for a pid above 0, which `kill` reads as a process group or as everyone: `kill(0, 0)`
    /// succeeds for as long as this app exists, so pid 0 was alive for ever, and a clean-up
    /// waiting for it to go waited out its whole budget and then gave up.
    static func isAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }
}
