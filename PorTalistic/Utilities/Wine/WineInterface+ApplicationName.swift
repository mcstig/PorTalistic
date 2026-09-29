//
//  WineInterface+ApplicationName.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import AppKit
import OSLog

extension Wine {
    /// What macOS calls a Windows program this app runs — the name in Force Quit, the Dock and
    /// ⌘-Tab — and how that name is corrected.
    ///
    /// The name isn't chosen here at launch. Wine's Mac driver registers a Windows process with
    /// LaunchServices when the process opens its first window, and the bundled engine's driver
    /// carries a patch from Whisky ("Whisky hack #9") that registers it as `<executable> (Mythic)`
    /// — so a game started from PorTalistic sat in Force Quit as `BioshockHD.exe (Mythic)`. The
    /// format is compiled into the engine's `winemac.drv`, spelt `@"%@ (Myt" @"hic)"` so that a
    /// search of the engine for the word finds nothing, and the engine is upstream's prebuilt
    /// download rather than something this project builds.
    ///
    /// So the name is corrected afterwards, by ``ApplicationNaming``: once a Windows program is
    /// an application, LaunchServices is told its name again, through `lsappinfo`. The rules for
    /// what that name is live here, apart from the watching, so they can be tested without a
    /// Windows program on screen.
    enum ApplicationName {
        static let log: Logger = .custom(category: "ApplicationNaming")

        /// `lsappinfo` ships with macOS, and is how a running application's LaunchServices record
        /// is changed from outside that application.
        static let launchServicesToolURL: URL = .init(filePath: "/usr/bin/lsappinfo")

        /// How many passes a program gets before it is given up on.
        ///
        /// More than one, because the engine names a program in the same moment it becomes an
        /// application, and nothing says which of the two requests LaunchServices hears last.
        /// Not unbounded, because a macOS that refuses the change would otherwise be asked
        /// forever.
        static let attemptLimit = 3

        /// How long a process without a window is polled for before only events are listened to.
        ///
        /// Wine registers a process with LaunchServices well before it has a window, and some
        /// never get one — `explorer.exe` sits there for as long as the prefix is up. Polling
        /// those for as long as they live would be a timer with nothing to do.
        static let windowlessWatchLimit: Duration = .seconds(120)

        /// What a program's current name calls for.
        enum Verdict: Equatable, Sendable {
            case rename(to: String)
            case alreadyNamed
            /// "Wine", say: there's no executable to keep, so nothing to rename it to.
            case notAProgramName
        }

        /// What one pass over a program found.
        enum Outcome: Equatable, Sendable {
            /// LaunchServices already calls it what it should be called.
            case settled
            /// LaunchServices was asked for the new name. The next pass reads it back.
            case requested(from: String, to: String)
            /// Not named after a program, so there is nothing to put this app's name beside.
            case unchanged(String)
            /// Asked for as often as ``attemptLimit`` allows, and still called this.
            case refused(String)
            /// `lsappinfo` couldn't be run, or didn't know the process.
            case unanswered
        }

        /// What a program's LaunchServices name should become.
        ///
        /// The executable's name is kept and whatever launcher is named beside it is replaced
        /// with `brand`: `BioshockHD.exe (Mythic)` becomes `BioshockHD.exe (PorTalistic)`, and a
        /// bare `steam.exe` gets the brand beside it. The executable's name is how a person tells
        /// two Windows programs apart in Force Quit, and it is how
        /// ``Wine/handOverForeground(toGameNamed:startedAs:hidingLauncher:)`` recognises a game.
        ///
        /// A name that isn't a program's is left as it is, because the brand on its own would
        /// give Force Quit two rows called PorTalistic — one of them the game, and nothing to say
        /// which.
        static func verdict(forDisplayName displayName: String, brand: String) -> Verdict {
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !brand.isEmpty else { return .notAProgramName }

            let program: Substring
            if let owned = name.wholeMatch(of: #/(?<program>.+?\.[A-Za-z0-9]{1,4}) \([^()]+\)/#) {
                program = owned.output.program
            } else if name.wholeMatch(of: #/.+?\.[A-Za-z0-9]{1,4}/#) != nil {
                program = name[...]
            } else {
                return .notAProgramName
            }

            let preferred = "\(program) (\(brand))"
            return preferred == name ? .alreadyNamed : .rename(to: preferred)
        }

        /// Whether an executable lives in one of the directories this app installs Wine into.
        ///
        /// Only a Wine this app installed counts — the engine and the managed runtimes. CrossOver's
        /// or Whisky's Wine runs that app's own games too, and renaming those would be this app
        /// claiming them. A path test on a directory boundary, so `Engine-old/` isn't `Engine/`.
        static func isRunningOnOwnWine(executableURL: URL?, ownWineDirectories: [URL]) -> Bool {
            guard let executable = executableURL?.standardizedFileURL.path else { return false }

            return ownWineDirectories.contains { directory in
                let root = directory.standardizedFileURL.path
                return executable.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
        }

        static func readNameArguments(forProcess pid: pid_t) -> [String] {
            ["info", "-only", "LSDisplayName", "-app", String(pid)]
        }

        /// The value is quoted for `lsappinfo`'s own parser, which reads a string with spaces in it
        /// only in double quotes. A Windows file name can't contain one, but a stray quote is
        /// dropped rather than trusted to that.
        static func writeNameArguments(_ name: String, forProcess pid: pid_t) -> [String] {
            ["setinfo", "-app", String(pid), "LSDisplayName=\"\(name.replacingOccurrences(of: "\"", with: ""))\""]
        }

        /// The name in `lsappinfo info -only LSDisplayName`'s answer: `"LSDisplayName"="steam.exe"`.
        static func displayName(inInfoOutput output: String) -> String? {
            guard let match = output.firstMatch(of: #/"LSDisplayName"\s*=\s*"(?<name>[^"]*)"/#) else { return nil }
            return String(match.output.name)
        }

        /// Reads what LaunchServices calls a program and, when allowed to, asks for better.
        static func name(processIdentifier pid: pid_t, brand: String, mayRequest: Bool) async -> Outcome {
            guard let output = await runLaunchServicesTool(readNameArguments(forProcess: pid))?.standardOutput,
                  let current = displayName(inInfoOutput: output) else {
                return .unanswered
            }

            switch verdict(forDisplayName: current, brand: brand) {
            case .alreadyNamed:
                return .settled
            case .notAProgramName:
                return .unchanged(current)
            case .rename(to: let preferred):
                guard mayRequest else { return .refused(current) }

                let result = await runLaunchServicesTool(writeNameArguments(preferred, forProcess: pid))
                if let complaint = result?.standardError?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !complaint.isEmpty {
                    log.warning("lsappinfo, renaming [\(pid, privacy: .public)]: \(complaint, privacy: .public)")
                }

                return .requested(from: current, to: preferred)
            }
        }

        private static func runLaunchServicesTool(_ arguments: [String]) async -> Process.CommandResult? {
            let process: Process = .init()
            process.executableURL = launchServicesToolURL
            process.arguments = arguments

            return await process.runWrapped(timeout: .seconds(5))
        }
    }

    /// Watches for Windows programs running on this app's Wine, and puts this app's name on them.
    /// See ``ApplicationName`` for why, and for the rules.
    @MainActor
    final class ApplicationNaming {
        static let shared: ApplicationNaming = .init()

        private struct NamingState {
            let firstSeen: ContinuousClock.Instant
            /// Renames asked for. Bounded by ``ApplicationName/attemptLimit``.
            var requests: Int = 0
            /// Passes that found nothing to rename, or got no answer. Counted apart from
            /// `requests`, so a slow start can't use up a program's renames before it has a name.
            var misses: Int = 0
            var isSettled: Bool = false
            var hasGivenUp: Bool = false
        }

        private var states: [pid_t: NamingState] = [:]
        private var ownWineDirectories: [URL] = []
        private var workspaceObservation: NSKeyValueObservation?
        private var activationObserver: NSObjectProtocol?
        private var pendingSweep: Task<Void, Never>?
        private var pendingSweepDeadline: ContinuousClock.Instant?
        private var isSweeping: Bool = false

        private init() {}

        /// Starts watching. Calling it again does nothing.
        func start() {
            guard workspaceObservation == nil else { return }

            // Resolved as well as written: Wine execs its loader from the real path of its own
            // `bin` directory, so a support folder moved behind a symlink would otherwise never
            // match a single process.
            ownWineDirectories = [Engine.directory, Runtime.managedDirectory]
                .compactMap { $0 }
                .flatMap { [$0, $0.resolvingSymlinksInPath()] }

            // Both handlers are `@Sendable`, so neither inherits this method's main-actor
            // isolation. AppKit calls them from wherever the change happened, and a closure the
            // compiler believes is main-actor isolated trips Swift's runtime isolation check when
            // it runs anywhere else — see `SparkleUpdateController.manageBackgroundTask(_:)`.

            // A program starting or exiting. `.initial`, so that games still running from before
            // this app was opened are named too.
            workspaceObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.initial]) { @Sendable _, _ in
                Task { @MainActor in ApplicationNaming.shared.sweep() }
            }

            // A program being given the front: by the foreground hand-off, by the person, or by
            // itself.
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { @Sendable _ in
                Task { @MainActor in ApplicationNaming.shared.sweep() }
            }
        }

        /// Looks over the running programs and names any that need it.
        ///
        /// A walk over `runningApplications` in memory when there's nothing to do, which is
        /// nearly always, so it runs on every event rather than guessing which ones matter.
        private func sweep() {
            // A pass already out asking `lsappinfo` schedules the next one when it's back.
            guard !isSweeping else { return }

            let now: ContinuousClock.Instant = .now
            let running = NSWorkspace.shared.runningApplications

            let alive = Set(running.map(\.processIdentifier))
            states = states.filter { alive.contains($0.key) }

            var due: [(pid: pid_t, mayRequest: Bool)] = []
            var nextPoll: Duration?

            for application in running {
                guard ApplicationName.isRunningOnOwnWine(executableURL: application.executableURL,
                                                         ownWineDirectories: ownWineDirectories) else { continue }

                let pid = application.processIdentifier
                let state = states[pid] ?? NamingState(firstSeen: now)
                states[pid] = state

                guard !state.isSettled, !state.hasGivenUp else { continue }

                // Wine makes a process an application, and the engine names it, when the process
                // opens its first window. Until then there's nothing to correct — so it's looked at
                // again soon while it's new, and now and then after that, in case a window comes
                // late and nothing else happens to prompt a pass.
                guard application.activationPolicy == .regular else {
                    let interval: Duration = state.firstSeen.duration(to: now) < ApplicationName.windowlessWatchLimit
                        ? .seconds(2) : .seconds(15)
                    nextPoll = min(nextPoll ?? interval, interval)
                    continue
                }

                // Out of renames, one last pass that only reads: whether the final request took.
                due.append((pid: pid, mayRequest: state.requests < ApplicationName.attemptLimit))
            }

            guard !due.isEmpty else {
                if let nextPoll { scheduleSweep(after: nextPoll) }
                return
            }

            isSweeping = true

            let queue = due
            let brand = Branding.name

            Task.detached(priority: .utility) {
                var outcomes: [pid_t: ApplicationName.Outcome] = [:]
                for entry in queue {
                    outcomes[entry.pid] = await ApplicationName.name(processIdentifier: entry.pid,
                                                                     brand: brand,
                                                                     mayRequest: entry.mayRequest)
                }

                let finished = outcomes
                await MainActor.run {
                    ApplicationNaming.shared.record(finished)
                }
            }
        }

        private func record(_ outcomes: [pid_t: ApplicationName.Outcome]) {
            isSweeping = false

            let log = ApplicationName.log
            let attemptLimit = ApplicationName.attemptLimit

            for (pid, outcome) in outcomes {
                guard var state = states[pid] else { continue }

                switch outcome {
                case .settled:
                    state.isSettled = true
                case .requested(from: let previous, to: let requested):
                    state.requests += 1
                    log.notice("""
                        Asked LaunchServices to call [\(pid, privacy: .public)] \
                        "\(requested, privacy: .public)" rather than "\(previous, privacy: .public)"
                        """)
                case .refused(let name):
                    state.hasGivenUp = true
                    // Said once, and loudly enough to find: a macOS that won't take the change
                    // looks exactly like this working, until somebody opens Force Quit.
                    log.warning("""
                        LaunchServices still calls [\(pid, privacy: .public)] "\(name, privacy: .public)" \
                        after \(attemptLimit, privacy: .public) requests; giving up on it
                        """)
                case .unchanged(let name):
                    state.misses += 1
                    if state.misses > attemptLimit {
                        state.hasGivenUp = true
                        log.notice("[\(pid, privacy: .public)] is called \"\(name, privacy: .public)\", which doesn't name a program; leaving it")
                    }
                case .unanswered:
                    state.misses += 1
                    if state.misses > attemptLimit {
                        state.hasGivenUp = true
                        // If this is every program, `lsappinfo`'s answer has changed shape, and
                        // nothing is being renamed at all.
                        log.warning("lsappinfo never gave a name for [\(pid, privacy: .public)]; giving up on it")
                    }
                }

                states[pid] = state
            }

            // Whatever was just asked for is read back on the next pass, which is what settles
            // it — and anything that turned up while this pass was out is picked up there too.
            scheduleSweep(after: .seconds(2))
        }

        /// One pass at a time, at the earliest time anything asked for.
        private func scheduleSweep(after delay: Duration) {
            let deadline: ContinuousClock.Instant = .now.advanced(by: delay)
            if let pendingSweepDeadline, pendingSweepDeadline <= deadline { return }

            pendingSweep?.cancel()
            pendingSweepDeadline = deadline

            pendingSweep = Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                // Replaced by a sooner pass, which now owns `pendingSweep`.
                guard !Task.isCancelled else { return }

                self.pendingSweep = nil
                self.pendingSweepDeadline = nil
                self.sweep()
            }
        }
    }
}
