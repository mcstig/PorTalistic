//
//  WineInterface.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 30/10/2023.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import AppKit
import OSLog
import SemanticVersion

final class Wine { // TODO: https://forum.winehq.org/viewtopic.php?t=15416
    internal static let log = Logger(subsystem: Logger.subsystem, category: "wineInterface")
    internal static func formatLog(containerURL: URL, description: String, error: Error? = nil) -> String {
        return "(\(containerURL.prettyPath)) \(description)" + (error != nil ? ": \(error!.localizedDescription)" : (description.hasSuffix(".") ? "" : "."))
    }
    
    internal static func retrieveVersion(forContainerAtURL containerURL: URL? = nil) -> SemanticVersion? {
        let process: Process = .init()
        process.arguments = ["--version"]
        process.executableURL = containerURL
            .map { runtime(forContainerAtURL: $0).executableURL }
            ?? Runtime.bundled.executableURL
        
        let result = try? process.runWrapped()
        
        if let standardOutput = result?.standardOutput,
           let match = try? Regex(#"wine-(\S+)"#).firstMatch(in: standardOutput),
           let extractedVersion = match.last?.substring {
            return SemanticVersion(fromRelaxedString: .init(extractedVersion))
        } else {
            return nil
        }
    }

    /// The directory where all wine prefixes/containers related to Mythic are stored.
    static var containersDirectory: URL? {
        let directory = Bundle.appContainer!.appending(path: "Containers")
        if FileManager.default.fileExists(atPath: directory.path) {
            return directory
        } else {
            do {
                Logger.file.info("Creating containers directory")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                return directory
            } catch {
                Logger.app.error("Error creating Containers directory: \(error.localizedDescription)")
                return nil
            }
        }
    }

    static var containerURLs: Set<URL> {
        get {
            // FIXME: [URL] as opposed to Set<URL> for backward compatibility, will be migrated in the future
            return .init((try? UserDefaults.standard.decodeAndGet([URL].self, forKey: "containerURLs")) ?? [])
        }
        set {
            let filteredNewValue = newValue.filter({ containerExists(at: $0) })
            do {
                try UserDefaults.standard.encodeAndSet(Array(filteredNewValue), forKey: "containerURLs")
            } catch {
                log.error("Unable to encode and/or set/update containerURLs array to UserDefaults: \(error.localizedDescription)")
            }
        }
    }

    static func containerExists(at url: URL) -> Bool {
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path).contains("drive_c")) ?? false
    }

    static func getContainerObject(at containerURL: URL) throws -> Container {
        let decoder = PropertyListDecoder()
        let container = try decoder.decode(Container.self,
                                           from: .init(contentsOf: containerURL.appending(path: "Properties.plist")))

        // A container records its own path, and that record goes stale the moment anything
        // moves it — which the rebrand did to every prefix on disk. Every container then came
        // back describing `~/Library/Containers/xyz.blackxfiied.Mythic/…`: harmless in the
        // list, not harmless in `Provisioner.apply(_:to:)`, which writes registry keys to
        // `container.url` and would have been writing them into a directory that no longer
        // exists.
        //
        // Trusting the path it was read from fixes it for anything that moves a prefix, not
        // just for this one migration — including a user moving one by hand. The correction
        // is written back so it only ever happens once per container.
        if container.url != containerURL {
            log.notice("Container \"\(container.name, privacy: .public)\" had moved; repointing it.")
            container.url = containerURL
            container.saveProperties()
        }

        return container
    }

    static var containerObjects: [Container] {
        return containerURLs.compactMap { try? getContainerObject(at: $0) }
    }

    private static func constructEnvironment(with containerURL: URL?, additionalVariables: [String: String] = .init()) -> [String: String] {
        // Inherit the parts of Mythic's environment that Wine actually wants, and nothing
        // else. Two failures bracket this:
        //
        // Building from an empty dictionary handed every wine process a world with no HOME,
        // no PATH and no TMPDIR — not a configuration Wine is tested in, and the reason
        // `wineserver -k` silently did nothing.
        //
        // Inheriting *everything* is worse. A debug session injects `DYLD_INSERT_LIBRARIES`
        // and friends, those dylibs load into wine's preloader, and they take the low
        // address space it needs to reserve for 32-bit Windows code:
        //
        //     preloader: Warning: failed to reserve range 0000000000010000-0000000000110000
        //     wine: failed to start L"C:\\Program Files (x86)\\Steam\\steam.exe"
        //
        // So: an allowlist. Anything not named here is Mythic's business, not Wine's.
        let inheritedKeys: Set<String> = [
            "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR",
            "LANG", "LC_ALL", "LC_CTYPE"
        ]

        // `CX_ROOT` is deliberately absent: Mythic sets it to its own bundle for the bundled
        // engine's sake, and it is added back per-runtime in ``transformProcess(_:containerURL:)``.

        var constructedEnvironment = ProcessInfo.processInfo.environment
            .filter { inheritedKeys.contains($0.key) }

        if let containerURL {
            constructedEnvironment["WINEPREFIX"] = containerURL.path
        }

        return constructedEnvironment.merging(additionalVariables, uniquingKeysWith: { $1 })
    }
    
    /// Modify a process' properties to call `wine`.
    /// This will modify `executableURL`, and `environment`, and will passthrough existing values.
    /// The runtime a container runs on, falling back to the bundled engine.
    ///
    /// A container records its runtime by id. If that runtime has since been removed, we
    /// fall back rather than refusing to launch — a missing runtime shouldn't make an
    /// existing container permanently unusable — but say so, because the prefix was
    /// migrated by the other build and may misbehave.
    static func runtime(forContainerAtURL containerURL: URL) -> Runtime {
        guard let settings = try? getContainerObject(at: containerURL).settings,
              let runtimeID = settings.runtimeID else {
            return .bundled
        }

        guard let resolved = Runtime.discoverAll().first(where: { $0.id == runtimeID }) else {
            log.warning("Container at \(containerURL.prettyPath) wants runtime '\(runtimeID, privacy: .public)', which isn't installed. Falling back to the bundled engine.")
            return .bundled
        }

        return resolved
    }

    /// Which Wine a container belongs to, and what that Wine needs in its environment.
    ///
    /// Two callers want this, and they want it in two shapes.
    /// ``transformProcess(_:containerURL:)`` runs a process that *is* Wine, so it takes both
    /// halves and sets `executableURL` itself. `legendary` is not Wine — it calls Wine on our
    /// behalf and is told which one on the command line — so it needs the executable as a
    /// path to pass along and the environment to inherit. Splitting it here is what keeps the
    /// two from drifting; they did, and Epic launches spent months on the bundled engine no
    /// matter which container they were in.
    static func runtimeInvocation(forContainerAtURL containerURL: URL) -> (executableURL: URL, environment: [String: String]) {
        let runtime = runtime(forContainerAtURL: containerURL)
        var environment: [String: String] = .init()

        // Where a runtime keeps the Unix libraries it links against, if it doesn't carry them
        // itself. Wineskin-derived engines are built to sit inside a wrapper application that
        // supplies these; installed on their own they can't start a single Windows process,
        // and the only sign of it is a dyld message on a stderr the caller turns into a
        // generic "couldn't boot":
        //
        //     dyld: Library not loaded: @rpath/libinotify.0.dylib
        //       Referenced from: .../bin/wineserver
        //       Reason: no LC_RPATH's found
        //
        // Fallback rather than `DYLD_LIBRARY_PATH`, so a runtime that does ship its own
        // libraries, or finds them on the system, still prefers those.
        let root = runtime.executableURL.deletingLastPathComponent().deletingLastPathComponent()
        environment.merge(supportLibraryEnvironment(forRuntimeAt: root), uniquingKeysWith: { $1 })

        // A CrossOver-derived Wine resolves its own tree from `CX_ROOT`, and the app sets that
        // to its own bundle at launch for the bundled engine. Handing it to any *other*
        // runtime points that runtime at a tree with no Wine in it, and the failure is silent
        // in the worst way: `wine --version` answers fine, because it needs nothing from the
        // tree, while every attempt to start a Windows process ends as a loader Wine forked,
        // could not exec, and reported only as
        //
        //     err:environ:run_wineboot failed to start wineboot 1
        //
        // So each runtime gets its own root, and only the bundled engine keeps the app's.
        if case .bundledEngine = runtime.origin, let cxRoot = ProcessInfo.processInfo.environment["CX_ROOT"] {
            environment["CX_ROOT"] = cxRoot
        }

        return (runtime.executableURL, environment)
    }

    static func transformProcess(_ process: Process, containerURL: URL) {
        let invocation = runtimeInvocation(forContainerAtURL: containerURL)
        process.executableURL = invocation.executableURL

        var capturedEnvironment = process.environment ?? [:]
        capturedEnvironment.merge(invocation.environment, uniquingKeysWith: { $1 })

        // Every Wine this app starts gets the overrides that keep it from asking for wine-mono
        // — not only the ones built from an assembled environment. The boot that *creates* a
        // container comes through here with nothing but `WINEDEBUG`, and that is the boot the
        // question is asked on: the "Wine Mono Installer" dialog came back on every new
        // container, with `wineboot` waiting behind it for its five minutes and then failing.
        // See ``baseDLLOverrides``.
        capturedEnvironment["WINEDLLOVERRIDES"] = withBaseDLLOverrides(capturedEnvironment["WINEDLLOVERRIDES"])

        process.environment = constructEnvironment(with: containerURL, additionalVariables: capturedEnvironment)
    }

    /// `overrides` with ``baseDLLOverrides`` in front, unless they are already there.
    ///
    /// In front because an assembled environment starts with them too, and because a caller's
    /// own overrides are extra DLLs to add, not a reason to let the wine-mono dialog back in.
    static func withBaseDLLOverrides(_ overrides: String?) -> String {
        guard let overrides, !overrides.isEmpty else { return baseDLLOverrides }
        guard !overrides.contains(baseDLLOverrides) else { return overrides }

        return baseDLLOverrides + ";" + overrides
    }

    /// The variables a runtime needs regardless of which of its binaries is being run.
    private static func supportLibraryEnvironment(forRuntimeAt runtimeRoot: URL) -> [String: String] {
        let frameworks = runtimeRoot.appending(path: RuntimeInstaller.supportLibrariesDirectoryName)
        guard FileManager.default.fileExists(atPath: frameworks.path) else { return [:] }

        return ["DYLD_FALLBACK_LIBRARY_PATH":
                    [frameworks.path, "/usr/local/lib", "/usr/lib"].joined(separator: ":")]
    }

    /// A path another program can exec to get this runtime's Wine *with* its own libraries.
    ///
    /// Handing out `bin/wine` is not enough when the caller is someone else's launcher.
    /// `legendary` is a signed binary, so dyld strips every DYLD_* variable from its
    /// environment before it starts — children included — and a runtime that keeps its Unix
    /// libraries in `Frameworks` has no other way to find them. Wine then comes up without
    /// freetype, draws no text in any game, and mentions it only on stderr:
    ///
    ///     Wine cannot find the FreeType font library.
    ///
    /// Rewriting install names in the build does not help: Wine reaches freetype through
    /// `dlopen("libfreetype.6.dylib")` rather than linking it, so there is no load command
    /// to change, and a bare `dlopen` name is resolved through exactly that variable.
    ///
    /// A shell script sets it *after* the stripping has happened and `exec`s Wine, which is
    /// ad-hoc signed and keeps what it is handed. `/bin/sh` losing the inherited copy on the
    /// way in costs nothing, because the script writes its own.
    ///
    /// Falls back to the executable itself for a runtime that ships no support libraries, or
    /// if the script can't be written — which is no worse than before this existed.
    static func launcherURL(forContainerAtURL containerURL: URL) -> URL {
        let runtime = runtime(forContainerAtURL: containerURL)
        let executableURL = runtime.executableURL
        let root = executableURL.deletingLastPathComponent().deletingLastPathComponent()
        let frameworks = root.appending(path: RuntimeInstaller.supportLibrariesDirectoryName)

        guard FileManager.default.fileExists(atPath: frameworks.path),
              let directory = Bundle.appHome?.appending(path: "Launchers") else {
            return executableURL
        }

        let fileName = runtime.id
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let script = directory.appending(path: "\(fileName).sh")

        let contents = """
            #!/bin/sh
            #
            # Written by PorTalistic, and rewritten whenever it changes. Runs \(runtime.name)
            # with the libraries that shipped with it.
            #
            # This exists because a launcher that takes a path to Wine — legendary's `--wine`
            # — cannot be handed DYLD_FALLBACK_LIBRARY_PATH: it is signed, so dyld strips the
            # variable before it starts. Setting it here is the only place it survives to
            # reach Wine, which needs it to dlopen freetype.
            DYLD_FALLBACK_LIBRARY_PATH="\(frameworks.path):/usr/local/lib:/usr/lib"
            export DYLD_FALLBACK_LIBRARY_PATH
            exec "\(executableURL.path)" "$@"

            """

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            if (try? String(contentsOf: script, encoding: .utf8)) != contents {
                try contents.write(to: script, atomically: true, encoding: .utf8)
            }

            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                 ofItemAtPath: script.path)
            return script
        } catch {
            log.warning("""
                Couldn't write a launcher for \(runtime.description, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return executableURL
        }
    }

    /// Whether the container's selected runtime can actually talk to the `wineserver` that
    /// currently owns this prefix.
    ///
    /// A prefix is served by one long-lived `wineserver`, and each `wineserver` speaks one
    /// protocol version. Switching a container from the bundled Wine 7.7 to Wine 11 while
    /// the 7.7 server is still alive means every subsequent `wine` call dies with
    ///
    /// ```
    /// wine client error:0: version mismatch 762/930.
    /// ```
    ///
    /// — on stderr, with no window, no dialog and no exit code anyone looks at. Choosing a
    /// runtime in the UI and then watching Steam refuse to open, silently, was exactly this.
    ///
    /// Probing costs one short subprocess, which is worth paying to avoid launching into a
    /// failure that reports itself nowhere.
    static func isPrefixServerCompatible(containerURL: URL) async -> Bool {
        let process: Process = .init()
        process.arguments = ["cmd", "/c", "ver"]
        transformProcess(process, containerURL: containerURL)

        guard let result = try? await process.runWrapped() else { return true }
        return !(result.standardError?.contains("version mismatch") ?? false)
    }

    // `ensureServerMatches` used to live here: it shut a container's wineserver down before a
    // launch whose msync differed from the one it was started with. Two things were wrong
    // with it. No profile sets msync at all — only a curated manifest entry could, and none
    // does — so the divergence it guarded against isn't reachable; and it ran `wineserver -k`
    // for every installed runtime, eight seconds apiece, on the first launch into a container
    // in a session, which is a long time to stand in front of a game that hasn't started yet.
    //
    // The real way a prefix ends up with a server that has no msync is a wine invocation
    // that builds its own environment instead of the container's. `winetricks` was doing
    // exactly that; see `runWinetricks`.

    /// Shuts down whichever `wineserver` is holding this prefix, whatever runtime it came from.
    ///
    /// The runtime that started the server may no longer be the container's selected one —
    /// that mismatch is the whole reason we're here — so asking the *current* runtime's
    /// `wineserver -k` to do it finds nothing and changes nothing. Every known runtime gets
    /// asked instead; the ones that aren't serving this prefix simply do nothing.
    static func shutdownPrefix(at containerURL: URL) async {
        for runtime in Runtime.discoverAll() where runtime.isInstalled {
            guard FileManager.default.isExecutableFile(atPath: runtime.wineserverURL.path) else { continue }

            let result = await serverKill(by: runtime, prefix: containerURL).runWrapped(timeout: .seconds(8))
            if let stderr = result?.standardError, !stderr.isEmpty {
                log.debug("wineserver -k (\(runtime.name, privacy: .public)): \(stderr, privacy: .public)")
            } else if result == nil {
                log.warning("wineserver -k (\(runtime.name, privacy: .public)) had to be killed.")
            }
        }

        log.notice("Asked every known wineserver to release \(containerURL.lastPathComponent, privacy: .public)")
    }

    struct PrefixRuntimeMismatchError: LocalizedError {
        let containerName: String

        var errorDescription: String? {
            String(localized: "\"\(containerName)\" is still being held by an older version of Wine than the one it's set to use, so nothing can start in it.")
        }

        var recoverySuggestion: String? {
            String(localized: "Quit and reopen PorTalistic. If that doesn't clear it, the container was built by the older Wine and needs to be recreated.")
        }
    }

    static func tasklist(for containerURL: URL) async throws -> [Container.Process] {
        var list: [Container.Process] = .init()
        
        let process: Process = .init()
        // Ask for CSV explicitly. Plain `tasklist` prints a human-readable table whose
        // column layout changed between Wine 7 and Wine 11, and guessing which one you're
        // going to get from the runtime's version number gets it wrong in both directions:
        // the container looked empty on 7.7 *and* on 11, at different times, and everything
        // built on top of it — "is Steam running?" included — silently answered no.
        process.arguments = ["tasklist", "/fo", "csv"]
        transformProcess(process, containerURL: containerURL)
        
        // Bounded: `tasklist` is a Windows process, so asking a broken prefix what is running
        // in it can hang exactly as hard as the thing we're asking about.
        guard let commandResult = await process.runWrapped(timeout: .seconds(15)) else {
            log.warning("tasklist didn't answer for \(containerURL.lastPathComponent, privacy: .public)")
            return list
        }

        if let standardOutput = commandResult.standardOutput {
            // One shape for every Wine version, because we asked for one.
            // The header row is quoted too, but its PID column isn't digits, so it simply
            // doesn't match and needs no special case.
            // swiftlint:disable force_try
            let tasklistRegex: Regex<AnyRegexOutput> = try! Regex(
                #"^"(?<ImageName>[^"]*)","(?<PID>\d+)","(?<SessionName>[^"]*)","(?<SessionNum>\d+)","(?<MemUsage>[^"]*)"$"#
            )
            // swiftlint:enable force_try
            
            for line in standardOutput.split(whereSeparator: \.isNewline) {
                guard let match = try tasklistRegex.wholeMatch(in: line.trimmingCharacters(in: .whitespaces)) else { continue }
                
                guard let extractedImageName = match["ImageName"]?.substring,
                      let extractedPID = match["PID"]?.substring,
                      let castPID = Int(extractedPID) else { continue }
                
                list.append(
                    .init(imageName: String(extractedImageName),
                          pid: castPID,
                          sessionName: match["ImageName"]?.substring.flatMap(String.init),
                          sessionNumber: match["SessionNum"]?.substring.flatMap({ Int($0) }),
                          memoryUsage: match["MemUsage"]?.substring.flatMap({ Int($0) }))
                )
            }
        }
        
        return list
    }
    
    @discardableResult
    static func boot(at containerURL: URL, parameters: BootParameter...) async throws -> Process.CommandResult {
        let process: Process = .init()
        process.arguments = ["wineboot"] + parameters.map(\.rawValue)

        // Creating a prefix is the one boot whose failure leaves nothing to inspect, and the
        // errors are all about how the engine was built and where it looks for things — a
        // missing unix library, a loader that can't find the builtin it needs to start. Wine
        // will say which, but only if asked, so ask on this boot alone: it happens once per
        // container and the answer goes in the transcript below.
        if parameters.contains(.prefixInit) {
            process.environment = ["WINEDEBUG": "+environ,+process,+loaddll"]
        }

        transformProcess(process, containerURL: containerURL)

        // Bounded. A `wineboot` waiting on a dialog nobody is going to click never returns,
        // and every launch into that container waits behind it — which is how a game came to
        // show two wine icons in the Dock and then nothing at all. Five minutes is far more
        // than a prefix needs and far less than forever; a boot that overruns it is reported
        // as a failure, which at least says something.
        guard let result = await process.runWrapped(timeout: .seconds(300)) else {
            log.error("""
                wineboot in \(containerURL.lastPathComponent, privacy: .public) did not finish                 within five minutes and was stopped
                """)

            preserveBootFailureLog(from: containerURL,
                                   named: runtime(forContainerAtURL: containerURL).name)
            throw Container.UnableToBootError()
        }

        // Kept next to the container, because a prefix that fails to boot is the one case
        // where there's no prefix to look inside afterwards, and the reason only ever appears
        // on a stderr the caller turns into `UnableToBootError`.
        // Wine's debug channels are chatty enough to bury the failure they were turned on to
        // find, and the interesting lines are always the last ones.
        func tail(_ output: String?, _ limit: Int = 60_000) -> String {
            guard let output, output.count > limit else { return output ?? "" }
            return "…(first \(output.count - limit) characters omitted)…\n"
                + String(output.suffix(limit))
        }

        let transcript = """
            wine: \(process.executableURL?.path ?? "?")
            arguments: \(process.arguments ?? [])
            environment: \(process.environment?.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } ?? [])
            exit: \(process.terminationStatus)

            stdout:
            \(tail(result.standardOutput))

            stderr:
            \(tail(result.standardError))
            """
        var report = transcript
        if process.terminationStatus != 0 {
            let diagnostics = await runtimeDiagnostics(for: containerURL)
            report += "\n\n" + diagnostics
        }

        try? report.write(to: containerURL.appending(path: "wineboot.log"),
                          atomically: true, encoding: .utf8)

        return result
    }

    /// What a failed boot needs to say about the engine that failed it.
    ///
    /// Wine reports a loader it couldn't start as `failed to start wineboot 1` and nothing
    /// else — the exit code of a grandchild whose `execv` never returned. The interesting
    /// facts are all about the engine's own files, so gather them: which binary Wine derives
    /// as its loader (the directory holding `ntdll.so`, not `bin/wine`), whether that binary
    /// can run at all, and what it says when it can't.
    private static func runtimeDiagnostics(for containerURL: URL) async -> String {
        let runtime = runtime(forContainerAtURL: containerURL)
        let root = runtime.executableURL.deletingLastPathComponent().deletingLastPathComponent()

        var lines = ["--- runtime diagnostics ---",
                     "runtime: \(runtime.name) [\(runtime.id)]",
                     "root: \(root.path)"]

        for relative in ["bin", "lib/wine/x86_64-unix", "lib/wine/x86_64-windows", "Frameworks"] {
            let directory = root.appending(path: relative)
            let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            lines.append("\(relative): \(contents.map { "\($0.count) entries" } ?? "missing")")
        }

        // Wine 11 ignores `WINELOADER`: it derives the loader from wherever `ntdll.so` sits,
        // so this — not the executable Mythic invokes — is what has to be able to start.
        let loader = root.appending(path: "lib/wine/x86_64-unix/wine")
        lines.append("derived loader: \(loader.path)")
        lines.append("  exists=\(FileManager.default.fileExists(atPath: loader.path))"
                     + " executable=\(FileManager.default.isExecutableFile(atPath: loader.path))")

        if FileManager.default.isExecutableFile(atPath: loader.path) {
            let probe: Process = .init()
            probe.executableURL = loader
            probe.arguments = ["--version"]
            probe.environment = supportLibraryEnvironment(forRuntimeAt: root)

            if let output = try? await probe.runWrapped() {
                lines.append("  --version exit=\(probe.terminationStatus)")
                lines.append("  stdout: \(output.standardOutput ?? "")")
                lines.append("  stderr: \(output.standardError ?? "")")
            } else {
                lines.append("  couldn't be run at all")
            }

            // The failure above is a loader that Wine forked and exec'd and that died before
            // it could report anything. Run the same boot through that loader ourselves: it
            // is the one process in the chain whose output nothing swallows.
            let direct: Process = .init()
            direct.executableURL = loader
            direct.arguments = ["wineboot", "--init"]
            // The same overrides as every other boot, and a bound: a diagnosis that gets further
            // than the failure it is diagnosing reaches the wine-mono question too, and without
            // either this waited on that dialog forever — after the launch had already failed.
            direct.environment = constructEnvironment(
                with: containerURL,
                additionalVariables: supportLibraryEnvironment(forRuntimeAt: root)
                    .merging(["WINEDEBUG": "+server,+seh,+process",
                              "WINEDLLOVERRIDES": baseDLLOverrides], uniquingKeysWith: { $1 })
            )

            if let output = await direct.runWrapped(timeout: .seconds(60)) {
                lines.append("derived loader, wineboot --init: exit=\(direct.terminationStatus)")
                lines.append("  stdout: \(String((output.standardOutput ?? "").suffix(4_000)))")
                lines.append("  stderr: \(String((output.standardError ?? "").suffix(40_000)))")
            } else {
                lines.append("derived loader, wineboot --init: couldn't be run, or didn't finish within a minute")
            }
        }

        lines.append(contentsOf: recentCrashReports(matching: ["wine", "wineboot", "wineserver"]))

        return lines.joined(separator: "\n")
    }

    /// The headline of any crash report macOS wrote for the engine in the last few minutes.
    ///
    /// A Wine process that dies inside its own start-up says nothing at all — the traces stop
    /// mid-sentence and the parent reports an exit code. macOS, meanwhile, has already written
    /// down the signal, the fault address and the library it came from. Reading the first
    /// dozen lines back turns "it exited 1" into something diagnosable.
    private static func recentCrashReports(matching names: [String]) -> [String] {
        let directory = URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Logs/DiagnosticReports")

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return ["crash reports: \(directory.path) isn't readable"] }

        let cutoff: Date = .now.addingTimeInterval(-600)
        let recent = entries
            .filter { entry in names.contains { entry.lastPathComponent.lowercased().hasPrefix($0) } }
            .compactMap { entry -> (URL, Date)? in
                guard let date = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, date > cutoff else { return nil }
                return (entry, date)
            }
            .sorted { $0.1 > $1.1 }

        guard let newest = recent.first?.0 else {
            return ["crash reports: none for \(names.joined(separator: ", ")) in the last 10 minutes"]
        }

        var report = ["crash report: \(newest.lastPathComponent)"]
        if let contents = try? String(contentsOf: newest, encoding: .utf8) {
            report.append(contentsOf: contents.split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(60)
                .map { "  " + $0 })
        }

        return report
    }

    /**
     Create a wine prefix (container).

     - Parameters:
     - baseURL: The URL where the container should be booted from.
     - name: The name that should be given to the container.
     - settings: Default settings the container should be booted with, if none already exist.
     - completion: A closure to call with the result (Container or Error).
     */
    @discardableResult
    static func createContainer(
        baseURL: URL? = containersDirectory,
        name: String,
        settings: Container.Settings = .init()
    ) async throws -> Container {
        guard let baseURL, FileManager.default.fileExists(atPath: baseURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard FileLocations.isWritableFolder(url: baseURL) else { throw CocoaError(.fileWriteUnknown) }
        guard Engine.isInstalled else { throw Engine.NotInstalledError() }

        let url: URL = baseURL.appending(path: name)

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        defer {
            Task { @MainActor in
                VariableManager.shared.setVariable("booting", value: false)
            }
        }

        await MainActor.run {
            VariableManager.shared.setVariable("booting", value: true)
        }

        do {
            guard !containerExists(at: url) else {
                log.notice("Container already exists at \(url.prettyPath)")
                let container = try Container(knownURL: url)

                // if container is found, insert in case it's not already present
                // welcome to alpha software
                containerURLs.insert(url)

                return container
            }

            let newContainer = Container(name: name, url: url, settings: settings)
            let result = try await boot(at: url, parameters: .prefixInit)

            // swiftlint:disable:next force_try
            guard result.standardError?.contains(try! Regex(#"wine: configuration in (.*?) has been updated\."#)) == true else {
                // `wineboot --init` gets far enough to create `drive_c`, `system.reg` and
                // friends before it gives up, and `containerExists(at:)` looks for exactly
                // `drive_c` — so a half-built prefix left here is handed back as a finished
                // container by the *next* call, which takes the early return above, reports
                // success, and launches the game into a Windows that was never finished
                // being installed. Worse than the failure it followed, and invisible.
                //
                // So the failure cleans up after itself. Nothing in here is the user's: this
                // call created the directory seconds ago, and a retry wants to start from
                // nothing anyway.
                preserveBootFailureLog(from: url, named: name)
                try? FileManager.default.removeItem(at: url)

                throw Container.UnableToBootError()
            }

            containerURLs.insert(url)

            try await toggleRetinaMode(containerURL: url, toggle: settings.retinaMode)
            try await setWindowsVersion(containerURL: url, version: settings.windowsVersion)
            try await setCaptureDisplaysForFullscreen(containerURL: url,
                                                      enabled: settings.captureDisplaysForFullscreen)
            // Derived from the mode, not the stored number — see `Settings.displayScaling`.
            try await setDisplayScaling(containerURL: url, dpi: settings.displayScaling)

            // An empty root store makes every HTTPS request inside the container fail in a
            // way that doesn't mention certificates. See ``Wine/Certificates``.
            try? await Certificates.installIfMissing(inContainerAtURL: url)

            // A container asked for DXVK and never got it.
            //
            // Only the container settings sheet ever called `DXVK.install`, so a container
            // created with `dxvk: true` came up with the DLL override set and no DLLs to
            // override with — Direct3D 11 silently on wined3d, in a prefix whose settings said
            // otherwise. Nothing reported it; you had to read a GPU log to find out.
            if settings.dxvk {
                try? await DXVK.install(toContainerAtURL: url)
            }

            log.error("\(formatLog(containerURL: url, description: "Created container"))")
            return newContainer
        } catch {
            log.error("\(formatLog(containerURL: url, description: "Unable to create container", error: error))")
            throw error
        }
    }

    /// Moves a failed prefix's `wineboot.log` up beside the containers, before the prefix goes.
    ///
    /// The transcript is the only record of *why* a container couldn't be created, and it is
    /// written inside the container — which the failure path then deletes. Keeping it one
    /// level up, named after the attempt, is what makes the next question answerable.
    private static func preserveBootFailureLog(from containerURL: URL, named name: String) {
        guard let destination = containersDirectory?
            .appending(path: "\(name) — failed wineboot.log") else { return }

        let source = containerURL.appending(path: "wineboot.log")
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: source, to: destination)

        log.notice("Kept the failed wineboot transcript at \(destination.prettyPath, privacy: .public)")
    }

    /// Opens a file beside the containers to take a launch's Wine transcript.
    ///
    /// Wine explains why a game didn't start on stderr and nowhere else, and every launch
    /// path here handed that stderr to a pipe that was read only for lines matching
    /// `ERROR:` and then dropped. A game that opens no window and writes no `ERROR:` line —
    /// the most common shape of this failure — therefore left no evidence at all.
    ///
    /// Truncated per launch rather than appended to: the interesting transcript is always
    /// the last one, and a game started twice a day should not leave a file whose top
    /// nobody will ever read.
    static func launchTranscript(named name: String) -> (url: URL, handle: FileHandle)? {
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard let url = containersDirectory?.appending(path: "\(safe) — launch.log") else {
            return nil
        }

        // Keeps the previous one, redacted. This is also the only reliable moment to redact an
        // Epic transcript — see ``rotateLog(at:)``.
        rotateLog(at: url)

        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            log.warning("Couldn't open a launch transcript at \(url.prettyPath, privacy: .public)")
            return nil
        }

        return (url, handle)
    }

    /// - Returns: Relevant environment variables as configured in a container for game launch.
    /// The environment a container's settings ask for, with a game allowed the last word.
    ///
    /// `overrides` is how a per-game setting reaches a launch at all. Five of the eight
    /// settings a profile can express — `msync`, `avx2`, `dxvk`, `dxvkAsync` and `metalHUD` —
    /// don't live in the prefix's registry; they are read from the container's *persisted*
    /// settings right here, every launch. Applying them per game by writing to the container
    /// and writing back afterwards would leave someone's container changed by any crash mid
    /// game. Passing them through instead means nothing has to be put back.
    ///
    /// They are resolved as `the game's opinion ?? the container's own setting`, and resolved
    /// *before* the rules below run, because these settings are not independent: which
    /// variable turns the HUD on depends on whether DXVK is in play, and `DXVK_ASYNC` means
    /// nothing without it. Overlaying finished variables afterwards would get both wrong.
    /// What is turned off in every container, before anything else is said about it.
    ///
    /// `mscoree` is Wine's .NET shim and `mshtml` its Internet Explorer one. Left enabled,
    /// the first `wineboot` in a fresh prefix puts up a modal dialog —
    ///
    ///     Wine could not find a wine-mono package which is needed for .NET applications
    ///
    /// — and *waits*. Nothing in this app clicks it, `wineboot` doesn't return until someone
    /// does, and `boot(at:)` has no timeout, so a launch would sit there forever behind a
    /// window the person may not even see. Two wine icons in the Dock and a game that never
    /// appears is what that looks like from the outside.
    ///
    /// Disabling them is what every other Wine front end does, and it costs almost nothing:
    /// a game that genuinely needs .NET ships its own runtime, and nothing here wants IE.
    /// Any container that does need them can be given the DLLs through winetricks, which
    /// installs real ones rather than asking Wine to fetch them mid-boot.
    static let baseDLLOverrides: String = "mscoree=d;mshtml=d"

    static func assembleEnvironmentVariables(forContainerAtURL containerURL: URL,
                                             container: Container? = nil,
                                             overriding overrides: RuntimeProfile.SettingsOverride = .init()) throws -> [String: String] {
        guard containerExists(at: containerURL) else { throw Wine.Container.DoesNotExistError() }

        let container = try container ?? getContainerObject(at: containerURL)
        var environmentVariables: [String: String] = .init()

        // Composed, not assigned. `WINEDLLOVERRIDES` is a single string and this used to be
        // written twice — once with the base overrides and again for DXVK — which is how the
        // second write silently dropped the first and let `wineboot` ask for wine-mono again.
        // Built up in order instead, base first so it applies to every container including the
        // `wineboot` that creates one. See ``baseDLLOverrides``.
        var dllOverrides: [String] = [Self.baseDLLOverrides]

        let msync = overrides.msync ?? container.settings.msync
        let avx2 = overrides.avx2 ?? container.settings.avx2
        let dxvk = overrides.dxvk ?? container.settings.dxvk
        let dxvkAsync = overrides.dxvkAsync ?? container.settings.dxvkAsync
        let metalHUD = overrides.metalHUD ?? container.settings.metalHUD

        environmentVariables["WINEMSYNC"] = msync.numericalValue.description
        environmentVariables["ROSETTA_ADVERTISE_AVX"] = avx2.numericalValue.description

        if dxvk {
            // `dxgi` is listed for completeness rather than because a file is expected: the
            // macOS DXVK builds are compiled against Wine's own DXGI and ship no dxgi.dll, so
            // this half of the override normally falls straight through to `b`. It matters
            // only for prefixes that were given an upstream DXVK, where d3d11 and dxgi have to
            // come from the same build or `D3D11CreateDevice` rejects the adapter.
            //
            // Worth saying plainly: this line is a promise, not a guarantee. `n,b` means
            // "native if it's there, builtin otherwise", so a container whose settings say DXVK
            // but whose prefix never received the DLLs runs on builtin d3d11 over wined3d and
            // says nothing about it. That reports Direct3D feature level 9_3 and an NVIDIA
            // GeForce 6800 that is not in any Mac — enough for ANGLE to cap GLES at 2.0 and for
            // the Steam client to give up on drawing. ``createContainer`` installing DXVK when
            // the setting asks for it is what makes the promise true.
            dllOverrides.append("dxgi,d3d10core,d3d11=n,b")
            environmentVariables["DXVK_ASYNC"] = dxvkAsync.numericalValue.description
        }

        if metalHUD {
            if dxvk {
                environmentVariables["DXVK_HUD"] = "full"
            } else {
                environmentVariables["MTL_HUD_ENABLED"] = "1"
            }
        }

        // Last, so a game's own entry can override anything above it — including the base
        // overrides, if a game ever turns out to need one of them back. Sorted so the string
        // is the same on every launch, which matters only because a test reads it.
        if let perGame = overrides.dllOverrides, !perGame.isEmpty {
            dllOverrides += perGame.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }

        environmentVariables["WINEDLLOVERRIDES"] = dllOverrides.joined(separator: ";")

        return environmentVariables
    }

    static func deleteContainer(containerURL: URL) throws {
        log.notice("Deleting container \(containerURL.lastPathComponent) (\(containerURL))")
        guard containerExists(at: containerURL) else { throw Container.DoesNotExistError() }

        try FileManager.default.removeItem(at: containerURL)
        containerURLs.remove(containerURL)
    }

    /// Stop everything running in a container, now, and make sure of it a moment later.
    ///
    /// What Force Quit means. `wineserver -k` takes down every process attached to the prefix's
    /// server — which is every process of a game that is running, and not a Wine process that was
    /// still starting when the request went out: one that hasn't reached the server yet isn't
    /// attached to it, and simply starts a fresh one. `legendary` hands a game to Wine and exits, so
    /// a Force Quit landing in that moment killed `legendary`, cleared the prefix, and then watched
    /// the game come up anyway. So it is asked twice, a second apart, by which point anything that
    /// was starting has attached — the second time of every runtime's server rather than only the
    /// container's own, the way ``shutdownPrefix(at:)`` asks, in case the prefix is being held by
    /// another build of Wine.
    ///
    /// Both are waited for. This used to be ``killAll(at:)`` twice, which starts `wineserver -k`
    /// and returns — so the launch could be over, and Play live again, with the kill still on its
    /// way, and a game started straight away would be starting in a prefix being shut down.
    ///
    /// Awaited by the launch it ends, which keeps Play unavailable until it is done: a launch
    /// started inside that second would otherwise be the thing the second pass takes down.
    static func forceQuit(containerAt url: URL) async {
        // A task of its own, because this is only ever run by a launch that has been cancelled,
        // and on that task nothing waits: a sleep returns the instant it starts, and so does
        // waiting for a process to finish.
        await Task.detached(priority: .userInitiated) {
            await Wine.stopServer(ofContainerAt: url)
            try? await Task.sleep(for: .seconds(1))
            await Wine.shutdownPrefix(at: url)
        }.value
    }

    /// One Force Quit of one launch's container: begun the moment it is pressed, and finished —
    /// waited for — by the launch.
    ///
    /// Begun by the launch's cancellation handler, which can't wait for anything, so that both of
    /// ``forceQuit(containerAt:)``'s passes are timed from the press and nothing the launch is
    /// caught up in can hold them back. They used to be run by the launch itself once it had
    /// unwound, and unwinding is not always quick: on the Epic path without a transcript, the
    /// launch reads `legendary`'s stderr to its end, every Wine process the game started holds that
    /// open, and one that dodged the first kill kept the read — and so the launch — where it was.
    /// The pass that would have caught it was the one that never came.
    ///
    /// Finished by the launch as it ends: the same passes, not a second pair, waited for so that
    /// Play stays unavailable until they are done.
    final class ForceQuit: @unchecked Sendable {
        private let lock: NSLock = .init()
        private var passes: Task<Void, Never>?
        private let run: @Sendable () async -> Void

        convenience init(containerAt url: URL) {
            self.init(running: { await Wine.forceQuit(containerAt: url) })
        }

        /// - Parameter run: what the passes are — only so that a test can count them.
        init(running run: @escaping @Sendable () async -> Void) {
            self.run = run
        }

        /// Starts the passes. Once, however often it is called: a launch has more than one
        /// cancellation handler, and each of them calls this.
        func begin() {
            _ = started()
        }

        /// Waits for the passes, starting them if nothing has.
        func finish() async {
            await started().value
        }

        private func started() -> Task<Void, Never> {
            lock.withLock {
                if let passes { return passes }

                let run = run
                let started = Task.detached(priority: .userInitiated) { await run() }
                passes = started
                return started
            }
        }
    }

    /// `wineserver -k` for one prefix, by the server of the runtime it belongs to, waited for.
    ///
    /// `-k` doesn't return until the server has gone, or until it has waited about ten seconds
    /// for it to, so the budget here is only for a `wineserver` that never answers at all.
    private static func stopServer(ofContainerAt url: URL) async {
        let runtime = runtime(forContainerAtURL: url)

        if await serverKill(by: runtime, prefix: url).runWrapped(timeout: .seconds(12)) == nil {
            log.warning("wineserver -k (\(runtime.name, privacy: .public)) had to be killed.")
        }
    }

    /// A `wineserver -k` for the prefix at `containerURL`, by `runtime`'s own server, in an
    /// environment that server can start in.
    ///
    /// Inherited rather than replaced: a bare `["WINEPREFIX": …]` strips HOME, PATH and TMPDIR,
    /// and wineserver without those exits having done nothing at all — which is
    /// indistinguishable, from here, from a kill that worked. And with the runtime's own library
    /// path, which no kill used to have: a Wineskin-derived engine's binaries link libraries the
    /// engine doesn't carry, `wineserver` among them — see
    /// ``runtimeInvocation(forContainerAtURL:)`` — so its kill ended in dyld before it began,
    /// which looks exactly the same.
    private static func serverKill(by runtime: Runtime, prefix containerURL: URL) -> Process {
        let process: Process = .init()
        process.executableURL = runtime.wineserverURL
        process.arguments = ["-k"]

        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = containerURL.path

        let runtimeRoot = runtime.executableURL.deletingLastPathComponent().deletingLastPathComponent()
        environment.merge(supportLibraryEnvironment(forRuntimeAt: runtimeRoot), uniquingKeysWith: { $1 })

        process.environment = environment
        process.qualityOfService = .userInitiated

        return process
    }

    static func killAll(at urls: URL...) throws {
        let urls: [URL] = urls.isEmpty ? .init(containerURLs) : urls

        for url in urls {
            // wineserver has to be the one belonging to the container's own runtime.
            // Shutting a Wine 11 prefix down with the 7.7 engine's wineserver won't find
            // the running processes, and the container would appear to hang.
            let process = serverKill(by: runtime(forContainerAtURL: url), prefix: url)

            // Started and not waited for: this is what cancellation handlers call, and they
            // can't wait. Off this thread even so, because the first run of a binary can take
            // seconds while macOS assesses it, and a cancellation handler runs on whichever thread
            // cancelled — for Force Quit, the main one. ``forceQuit(containerAt:)`` is the version
            // that waits.
            Task { try process.run() }
        }
    }

    static func purgeD3DMetalShaderCache() throws {
        let process: Process = .init()
        process.executableURL = .init(filePath: "/usr/bin/getconf")
        process.arguments = ["DARWIN_USER_CACHE_DIR"]

        let output = try process.runWrapped()
        
        guard let cachePath = output.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw CocoaError(.coderValueNotFound)
        }
        let d3dMetalCacheURL: URL = URL(filePath: cachePath).appendingPathComponent("d3dm")

        // although success may be limited, this is MUCH less risky than using applescript w/ string interpolation
        try FileManager.default.removeItem(at: d3dMetalCacheURL)
    }

    private static func addRegistryKey(containerURL: URL, key: String, name: String, data: String, type: RegistryType) async throws {
        guard containerExists(at: containerURL) else { throw Container.DoesNotExistError() }

        let process: Process = .init()
        process.arguments = ["reg", "add", key, "-v", name, "-t", type.rawValue, "-d", data, "-f"]
        transformProcess(process, containerURL: containerURL)
        
        try process.run()
        
        process.waitUntilExit()
        
        try process.checkTerminationStatus()
    }

    /// The value of a registry entry, as `reg query` reports it.
    ///
    /// Returns the value alone, not the line it sits on. `reg query` answers with a header
    /// and then a row — `    RetinaMode    REG_SZ    y` — and this used to hand back that
    /// whole row. Every caller then compared it against what it expected the value to be, so
    /// every caller was wrong in the same silent way: ``getRetinaMode(containerURL:)`` always
    /// answered `false`, and the container settings sheet has been showing Retina Mode as off
    /// on prefixes where it is on, which makes the toggle write the value it already has.
    static func queryRegistryKey(containerURL: URL, key: String, name: String, type: RegistryType) async throws -> String {
        let process: Process = .init()
        process.arguments = ["reg", "query", key, "-v", name]
        transformProcess(process, containerURL: containerURL)
        
        let commandResult = try await process.runWrapped()

        try process.checkTerminationStatus()

        // The row naming the value, which is the last non-empty line reg query prints.
        let row = commandResult.standardOutput?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty && $0.contains(type.rawValue) })

        // Name, type, value — separated by runs of whitespace. The value is what's left after
        // the type, which keeps this correct for a value that itself contains spaces.
        guard let row,
              let typeRange = row.range(of: type.rawValue) else {
            throw UnableToQueryRegistryError()
        }

        let value = row[typeRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { throw UnableToQueryRegistryError() }

        return value
    }

    static func toggleRetinaMode(containerURL: URL, toggle: Bool) async throws {
        do {
            try await addRegistryKey(containerURL: containerURL,
                                     key: RegistryKey.macDriver.rawValue,
                                     name: "RetinaMode",
                                     data: toggle ? "y" : "n",
                                     type: .string)

            // The DPI is not a separate decision — see `Settings.displayScaling`. Asked for
            // rather than restated, so this can't drift away from what a container's own
            // settings say the pair should be.
            try await setDisplayScaling(containerURL: containerURL,
                                        dpi: Container.Settings.displayScaling(forRetinaMode: toggle))
        } catch {
            log.error("\(formatLog(containerURL: containerURL, description: "Unable to toggle retina mode \(toggle)", error: error))")
            throw error
        }
    }

    /// Turns wined3d's command-stream thread on or off for a container.
    ///
    /// wined3d hands GL work to a worker thread by default, which is usually faster and is
    /// also where a good share of wined3d's crashes live. It matters more here than on Linux:
    /// a 32-bit game runs through 32-on-64, every call into the host costs extra stack, and a
    /// thread that blows its 1MB leaves exactly the wreckage Blades of Time did —
    ///
    ///     err:seh:call_stack_handlers invalid frame 0012EDF0 (00132000-0022FD20)
    ///     err:seh:NtRaiseException Exception frame is not in stack limits
    ///
    /// — an SEH chain pointing below the stack it belongs to, which is a stack overflow that
    /// couldn't even report itself.
    static func setCommandStreamThread(containerURL: URL, enabled: Bool) async throws {
        do {
            try await addRegistryKey(containerURL: containerURL,
                                     key: RegistryKey.direct3D.rawValue,
                                     name: "csmt",
                                     data: enabled ? "1" : "0",
                                     type: .dword)
        } catch {
            log.error("\(formatLog(containerURL: containerURL, description: "Unable to set CSMT to \(enabled)", error: error))")
            throw error
        }
    }

    static func getCommandStreamThread(containerURL: URL) async throws -> Bool {
        // Absent means Wine's default, which is on.
        guard let result = try? await queryRegistryKey(containerURL: containerURL,
                                                       key: RegistryKey.direct3D.rawValue,
                                                       name: "csmt",
                                                       type: .dword) else { return true }

        return Int(result.trimmingPrefix("0x"), radix: 16).map { $0 != 0 } ?? true
    }

    /// Whether this prefix lets a fullscreen game take the display.
    ///
    /// Absent means Wine's own default, which is **off** — see
    /// ``Wine/Container/Settings/captureDisplaysForFullscreen``.
    static func getCaptureDisplaysForFullscreen(containerURL: URL) async throws -> Bool {
        guard let result = try? await queryRegistryKey(containerURL: containerURL,
                                                       key: RegistryKey.macDriver.rawValue,
                                                       name: "CaptureDisplaysForFullscreen",
                                                       type: .string) else { return false }

        return result == "y"
    }

    static func setCaptureDisplaysForFullscreen(containerURL: URL, enabled: Bool) async throws {
        try await addRegistryKey(containerURL: containerURL,
                                 key: RegistryKey.macDriver.rawValue,
                                 name: "CaptureDisplaysForFullscreen",
                                 data: enabled ? "y" : "n",
                                 type: .string)
    }

    static func getRetinaMode(containerURL: URL) async throws -> Bool {
        let result = try await queryRegistryKey(containerURL: containerURL,
                               key: RegistryKey.macDriver.rawValue,
                               name: "RetinaMode",
                               type: .string)

        return (result == "y")
    }

    static func getWindowsVersion(containerURL: URL) async throws -> WindowsVersion? {
        do {
            let process: Process = .init()
            process.arguments = ["winecfg", "-v"]
            transformProcess(process, containerURL: containerURL)
            
            let commandResult = try await process.runWrapped()
            
            let currentVersion: String?
            // wine above major version 7 sends the windows version to stderr
            if self.retrieveVersion()?.major ?? 0 > 7 {
                currentVersion = commandResult.standardError?
                    .split(whereSeparator: \.isNewline)
                    .last.map(String.init)
            } else {
                currentVersion = commandResult.standardOutput?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            return WindowsVersion.allCases.first(where: { String(describing: $0) == currentVersion })
        } catch {
            log.error("\(formatLog(containerURL: containerURL, description: "Unable to get windows version", error: error))")
            throw error
        }
    }

    static func setWindowsVersion(containerURL: URL, version: WindowsVersion) async throws {
        do {
            let process: Process = .init()
            process.arguments = ["winecfg", "-v", String(describing: version)]
            transformProcess(process, containerURL: containerURL)
            
            try process.run()
            
            process.waitUntilExit()
            
            try process.checkTerminationStatus()
        } catch {
            log.error("\(formatLog(containerURL: containerURL, description: "Unable to set windows version", error: error))")
            throw error
        }
    }

    static func getDisplayScaling(containerURL: URL) async throws -> Int {
        do {
            let result = try await queryRegistryKey(containerURL: containerURL,
                                                    key: RegistryKey.desktop.rawValue,
                                                    name: "LogPixels",
                                                    type: .dword)

            guard let scale = Int(result.trimmingPrefix("0x"), radix: 16) else {
                return -1
            }

            return scale
        } catch {
            log.error("\(formatLog(containerURL: containerURL, description: "Unable to get display scaling value", error: error))")
            throw error
        }
    }

    static func setDisplayScaling(containerURL: URL, dpi: Int) async throws {
        guard (96...480).contains(dpi) else { return }
        do {
            try await addRegistryKey(containerURL: containerURL,
                                     key: RegistryKey.desktop.rawValue,
                                     name: "LogPixels",
                                     data: String(dpi),
                                     type: .dword)
        } catch {
            log.error("\(formatLog(containerURL: containerURL, description: "Unable to set display scaling value", error: error))")
            throw error
        }
    }
    
    /// Verbs a container has already been given, one per line.
    ///
    /// A file in the container rather than `UserDefaults`, so it travels with the prefix: a
    /// container deleted and recreated should be prepared again, and one restored from a
    /// backup should not.
    private static func installedVerbsFile(inContainerAtURL url: URL) -> URL {
        url.appending(path: "PorTalistic-winetricks.txt")
    }

    /// Somewhere for a `@Sendable` callback to put lines.
    ///
    /// `runWinetricks` hands its output to a sendable closure, which cannot write to a local
    /// `var` — so this holds them instead. Locked in plain synchronous methods, because
    /// `NSLock` cannot be taken from an async context and the callback is not one.
    private final class OutputLog: @unchecked Sendable {
        private let lock: NSLock = .init()
        private var lines: [String] = .init()

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }

            lines.append(line)
        }

        /// The tail, which is where a tool that gave up says why.
        func last(_ count: Int) -> [String] {
            lock.lock()
            defer { lock.unlock() }

            return Array(lines.suffix(count))
        }
    }

    /// Whether anything on this machine can open a Microsoft cabinet.
    ///
    /// winetricks shells out to `cabextract` or `7z` for any verb whose payload is a cab, and
    /// macOS ships neither. `d3dcompiler_43` is inside Microsoft's DirectX redistributable and
    /// therefore cannot be installed without one; `d3dcompiler_47` comes from a zip and can,
    /// which is exactly the asymmetry that made one verb succeed and the other exit 1 with
    /// nothing to act on.
    ///
    /// - Note: This is a shipping problem, not a diagnostic one. PorTalistic bundles winetricks
    ///   but not the tools winetricks needs, so every curated fix whose DLL lives in a cab fails
    ///   this way on a stock Mac — and telling someone to install Homebrew is not a fix. Either
    ///   `cabextract` gets bundled or cabinets get opened in-process.
    static var canExtractCabinets: Bool {
        cabinetExtractorSearchPaths.contains { directory in
            ["cabextract", "7z", "7za"].contains { tool in
                FileManager.default.isExecutableFile(atPath: "\(directory)/\(tool)")
            }
        }
    }

    private static var cabinetExtractorSearchPaths: [String] {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        // The app's own environment rarely has Homebrew on it, and `runWinetricks` adds those
        // directories itself, so they are checked here too.
        return path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }

    /// Verbs this container was asked for and could not be given, with why.
    ///
    /// Beside the marker file and for the same reason: a verb that failed is the explanation
    /// for the crash that follows, and it happens during provisioning — before the launch
    /// transcript exists — so without this it lives only in the app's own log, where nobody
    /// looking at a broken game will find it.
    private static func failedVerbsFile(inContainerAtURL url: URL) -> URL {
        url.appending(path: "PorTalistic-winetricks-failed.txt")
    }
    /// Installs the winetricks verbs a game's profile asks for, skipping any this container
    /// already has.
    ///
    /// Once per container, because each verb downloads and installs real DLLs and takes long
    /// enough that doing it per launch would be obvious.
    ///
    /// Failure is logged and not thrown. The game will then fail in whatever way the verb was
    /// meant to prevent — but that is no worse than not trying, and the line naming the verb
    /// that failed is the one that explains the crash which follows. Refusing to launch because
    /// a download failed would be worse.
    static func installWinetricksVerbsIfMissing(_ verbs: [String], inContainerAtURL url: URL) async {
        guard !verbs.isEmpty else { return }

        if !canExtractCabinets {
            log.warning("""
                No cabinet extractor found (cabextract, 7z). Winetricks verbs whose payload is \
                a Microsoft cab cannot be installed, and this machine needs: \
                \(verbs.joined(separator: ", "), privacy: .public)
                """)
        }

        let marker = installedVerbsFile(inContainerAtURL: url)
        let existing = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        var installed: Set<String> = .init(existing.split(separator: "\n").map(String.init))

        for verb in verbs where !installed.contains(verb) {
            log.notice("Installing winetricks verb \(verb, privacy: .public) into \(url.lastPathComponent, privacy: .public)")

            // winetricks says why it gave up on its own output, and losing that was the
            // difference between "the verb failed" and a diagnosis: the first time one did,
            // all that survived was an exit code.
            let output: OutputLog = .init()

            do {
                try await runWinetricks(containerURL: url, verb: verb) { line in
                    output.append(line)
                }

                installed.insert(verb)
                try? Data(installed.sorted().joined(separator: "\n").utf8).write(to: marker)
            } catch let error where error is CancellationError || Task.isCancelled {
                // Force-quit while this was running. Not a verb that failed — recording it as
                // one would put a line in the failures file that nobody can explain — and not a
                // reason to start the next one.
                log.notice("Stopped installing winetricks verbs into \(url.lastPathComponent, privacy: .public): the launch was force-quit")
                return
            } catch {
                log.error("Couldn't install winetricks verb \(verb, privacy: .public): \(error.localizedDescription, privacy: .public)")

                let failures = failedVerbsFile(inContainerAtURL: url)
                let previous = (try? String(contentsOf: failures, encoding: .utf8)) ?? ""
                let diagnosis = canExtractCabinets
                    ? ""
                    : """

                        No cabinet extractor on this machine (cabextract, 7z). Any verb whose \
                        payload is inside a Microsoft cab — d3dcompiler_43 among them — cannot \
                        be installed without one.
                        """

                let record = """
                    \(Date.now.formatted(date: .abbreviated, time: .standard)) — \(verb): \(error.localizedDescription)\(diagnosis)
                    \(output.last(40).map { "    \($0)" }.joined(separator: "\n"))

                    """

                try? Data((previous + record).utf8).write(to: failures)
            }
        }
    }

    /// Runs a winetricks verb in the specified container.
    /// - Parameters:
    ///   - containerURL: The URL of the Wine container/prefix.
    ///   - verb: The winetricks verb to execute (e.g., "corefonts", "vcrun2019", "d3dx9").
    ///   - onOutput: Optional callback for streaming output updates.
    /// - Note: Winetricks must be installed and available in the system PATH or bundled with the Engine.
    static func runWinetricks(containerURL: URL, verb: String, onOutput: (@Sendable (String) -> Void)? = nil) async throws {
        guard containerExists(at: containerURL) else { throw Container.DoesNotExistError() }
        guard Engine.isInstalled else { throw Engine.NotInstalledError() }
        
        let process: Process = .init()
        
        // Check for bundled winetricks first, then fall back to system winetricks
        let bundledWinetricksURL = Engine.directory.appending(path: "winetricks")
        let winetricksURL: URL
        
        if FileManager.default.fileExists(atPath: bundledWinetricksURL.path) {
            winetricksURL = bundledWinetricksURL
        } else {
            // Try to find winetricks in common locations
            let possiblePaths = [
                "/usr/local/bin/winetricks",
                "/opt/homebrew/bin/winetricks",
                "/usr/bin/winetricks"
            ]
            
            if let foundPath = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                winetricksURL = URL(filePath: foundPath)
            } else {
                throw WinetricksNotFoundError()
            }
        }
        
        let wineBinDirectory = Engine.directory.appending(path: "wine/bin")
        let wineLibDirectory = Engine.directory.appending(path: "wine/lib")
        
        // Get user's home directory and cache directory for winetricks
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? "\(homeDirectory)/Library/Caches"
        
        process.executableURL = winetricksURL
        process.arguments = ["--force", verb]
        process.currentDirectoryURL = containerURL

        // Built on the container's own environment, not instead of it.
        //
        // This used to be a hand-written dictionary, and it left out `WINEMSYNC`. A
        // `wineserver` reads that once, at startup, and then serves the prefix long after
        // whatever started it has gone — so one winetricks run left a server behind with
        // msync off, and every game launched in that container afterwards died immediately
        // on
        //
        //     err:msync:msync_init Failed to open msync shared memory file
        //
        // with no window and a three-line log. Blades of Time was exactly this.
        //
        // It also hard-coded the bundled engine as `WINE`, `WINE64` and `WINESERVER` — the
        // FIXME that used to sit on that line — so a verb installed into a Wine 11 prefix
        // was installed by Wine 7.7, into a prefix its own server then refused on a protocol
        // version mismatch.
        let runtimeInvocation = runtimeInvocation(forContainerAtURL: containerURL)
        let runtimeBinDirectory = runtimeInvocation.executableURL.deletingLastPathComponent()

        var environment = (try? assembleEnvironmentVariables(forContainerAtURL: containerURL)) ?? .init()
        environment.merge(runtimeInvocation.environment, uniquingKeysWith: { $1 })

        environment["HOME"] = homeDirectory
        environment["USER"] = NSUserName()
        environment["XDG_CACHE_HOME"] = cacheDirectory
        environment["WINEPREFIX"] = containerURL.path
        environment["WINE"] = runtimeInvocation.executableURL.path
        environment["WINE64"] = runtimeInvocation.executableURL.path
        environment["WINESERVER"] = runtimeBinDirectory.appending(path: "wineserver").path
        environment["WINEARCH"] = "win64"
        environment["PATH"] = "\(runtimeBinDirectory.path):\(wineBinDirectory.path):/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        environment["WINETRICKS_WINE_IS_64BIT"] = "true"
        environment["DISPLAY"] = ""       // no X11 display requirements
        environment["TERM"] = "xterm-256color"

        // Only if the container's runtime didn't say where its own libraries are.
        if environment["DYLD_FALLBACK_LIBRARY_PATH"] == nil {
            environment["DYLD_FALLBACK_LIBRARY_PATH"] = "\(wineLibDirectory.path):/usr/lib"
        }

        process.environment = environment
        
        log.info("\(formatLog(containerURL: containerURL, description: "Running winetricks verb: \(verb)"))")
        
        if let onOutput {
            // Stream output in real-time — and stop when asked. Force Quit on a launch that is
            // installing what its game needs cancels this, and cancelling used to end only the
            // wait: the script ran on to the end of its verb — downloading, extracting, starting
            // Wine in a prefix the Force Quit had just cleared. Killed with everything it has
            // started, because the step it is on is always one of its children — see
            // ``Process/killTree()``.
            let launch: StoppableLaunch = .init(halting: { $0.killTree() })

            try await withTaskCancellationHandler {
                try await process.runStreamed(throwsOnChunkError: false, launchingWith: launch) { chunk in
                    onOutput(chunk.output)
                    return nil
                }
            } onCancel: {
                launch.stop()
            }
        } else {
            // Original behavior without streaming
            let result = try await process.runWrapped()
            
            // Log any output for debugging
            if let stderr = result.standardError, !stderr.isEmpty {
                log.warning("\(formatLog(containerURL: containerURL, description: "Winetricks stderr: \(stderr)"))")
            }
        }
        
        guard process.terminationStatus == 0 else {
            throw WinetricksExecutionError(verb: verb, exitCode: process.terminationStatus)
        }
        
        log.info("\(formatLog(containerURL: containerURL, description: "Successfully installed winetricks verb: \(verb)"))")
    }
    
    /// Error thrown when winetricks is not found on the system.
    struct WinetricksNotFoundError: LocalizedError {
        var errorDescription: String? {
            "Winetricks is not installed. Please install winetricks via Homebrew (brew install winetricks) or ensure it's bundled with the Engine."
        }
    }
    
    /// Error thrown when a winetricks verb execution fails.
    struct WinetricksExecutionError: LocalizedError {
        let verb: String
        let exitCode: Int32
        
        var errorDescription: String? {
            "Failed to install '\(verb)' via winetricks. Exit code: \(exitCode)"
        }
    }

    // MARK: - Game logs

    /// Where a game's output is kept: beside the container it ran in, so it goes when the
    /// container does and is one "Open…" away from the person who needs to send it to you.
    static func logURL(forGameTitled title: String, inContainerAtURL containerURL: URL) -> URL {
        let name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        return containerURL.appending(path: "logs/\(name).log")
    }

    /// Opens `logURL` for writing, truncated, with a header saying what is about to run.
    ///
    /// Truncated rather than appended: the interesting log is always the last run's, and a
    /// file that only grows is one nobody scrolls to the bottom of.
    /// Keeps the previous launch's log, redacted, and clears the way for a new one.
    ///
    /// Two problems, one answer.
    ///
    /// The log only ever held the *last* launch, so a game reported as "crashed twice, in
    /// different places" could only be looked at once — the second run had already overwritten
    /// the first. Now the previous one survives beside it.
    ///
    /// And redaction has to happen here rather than when a game exits, because on the Epic path
    /// there is no moment that means "the game exited": `legendary` spawns Wine detached and
    /// returns, so a pass scheduled after it ran while the game was still appending to the file
    /// — which is why a 2K bearer token was still sitting in a transcript that had supposedly
    /// been cleaned. By the time a launch begins, whatever wrote the previous log is long gone,
    /// which makes this the first point where the file is genuinely finished.
    ///
    /// - Important: this sanitises what is *kept*, not what is being written. A live transcript
    ///   contains whatever the game is putting in it, so anything that reveals or sends one has
    ///   to redact a copy at that moment. Nothing does yet; when something does, that is the
    ///   rule.
    static func rotateLog(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        redactSecrets(inLogAt: url)

        let previous = url
            .deletingLastPathComponent()
            .appending(path: "\(url.deletingPathExtension().lastPathComponent) — previous.\(url.pathExtension)")

        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }

    /// Strips credentials out of a finished launch log.
    ///
    /// Games talk to their publishers' services with `curl`'s verbose output going to stderr,
    /// and stderr is the transcript — so what lands in the file is the whole request. BioShock
    /// Remastered writes its 2K Coretech `Authorization: Bearer` token into it, JWT payload and
    /// all: account id, session id, and the coordinates of the city it resolved the player to.
    ///
    /// A launch transcript exists to be read by somebody else. Its whole purpose is to be
    /// attached to a bug report, which makes a live session token in it the one thing it must
    /// never contain. Rewritten once, after the game has exited and nothing is still appending.
    /// ``redactSecrets(inLogAt:)``'s rewrite, over a string.
    ///
    /// Split out because a crash report carries *extracts* of a transcript, and an extract has
    /// to be redacted on its own — the file it came from is redacted only at the start of the
    /// next launch, which is far too late for something about to be transmitted.
    ///
    /// Header values first, then anything else shaped like a JWT: a token can appear in a query
    /// string or a response body as easily as in a header.
    static func redactSecrets(in text: String) -> String {
        let patterns: [String] = [
            "(?i)((?:authorization|x-api-key|x-auth-token|cookie|set-cookie)\\s*:\\s*)(?:bearer\\s+)?[^\\r\\n]+",
            "eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}(?:\\.[A-Za-z0-9_-]+)?"
        ]

        var redacted = text

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }

            redacted = expression.stringByReplacingMatches(
                in: redacted,
                range: NSRange(redacted.startIndex..., in: redacted),
                withTemplate: pattern.hasPrefix("(?i)") ? "$1<redacted by PorTalistic>" : "<redacted by PorTalistic>"
            )
        }

        return redacted
    }

    static func redactSecrets(inLogAt url: URL) {
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { return }

        let redacted = redactSecrets(in: original)

        guard redacted != original else { return }

        log.notice("Redacted credentials from \(url.lastPathComponent, privacy: .public)")
        try? Data(redacted.utf8).write(to: url)
    }

    /// The parts of a launch environment worth keeping a record of.
    ///
    /// Written into the transcript because three separate diagnoses this week turned on "was
    /// that override actually set?" and there was no way to answer it afterwards. A DLL
    /// override that reaches the process and a native DLL that then fails to load look
    /// identical from the outside — Wine falls back to its builtin either way and says nothing
    /// — and the difference decides the fix.
    ///
    /// Filtered rather than dumped: the inherited environment carries plenty that has nothing
    /// to do with Wine, and a transcript people are asked to send somewhere should contain only
    /// what it needs to.
    static func environmentSummary(_ environment: [String: String]) -> String {
        let interesting = environment
            .filter { key, _ in
                key.hasPrefix("WINE") || key.hasPrefix("DXVK") || key.hasPrefix("MTL_")
                    || key.hasPrefix("ROSETTA_") || key.hasPrefix("DYLD_")
            }
            .sorted { $0.key < $1.key }
            .map { "  \($0.key)=\($0.value)" }

        guard !interesting.isEmpty else { return "environment: nothing wine-related set" }

        return (["environment:"] + interesting).joined(separator: "\n")
    }

    static func beginLogging(to logURL: URL,
                            describing executable: URL,
                            environment: [String: String] = .init()) -> FileHandle? {
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)

            rotateLog(at: logURL)

            let header = """
                \(executable.path)
                \(Date.now.formatted(date: .abbreviated, time: .standard))
                \(environmentSummary(environment))

                """

            try header.data(using: .utf8)?.write(to: logURL, options: [.atomic])

            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            return handle
        } catch {
            log.warning("Couldn't open a log for \(executable.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Foreground

    /// Hands the foreground to a Windows game that has just been started.
    ///
    /// Wine's Mac driver does not change the display mode while its process isn't the active
    /// application — it records the request and applies it when the process is next activated.
    /// A game started by a launcher that stays in front therefore asks for fullscreen, is
    /// quietly told "later", and comes up as an ordinary window the size of its fullscreen
    /// resolution. It looks exactly like a game ignoring its own settings, and it un-sticks
    /// itself the moment the player changes any video setting — because by then they have
    /// clicked into the game and it has become active.
    ///
    /// So PorTalistic gives the game the front itself, rather than leaving the player to do it
    /// before the game gets as far as asking. And the person pressed Play: the game is what
    /// they asked to be looking at, which would be reason enough on its own.
    ///
    /// - Parameters:
    ///   - executableName: the game's executable, e.g. `Prey.exe`. A hint, not an identity —
    ///     Wine names the application after it only sometimes, and calls it "Wine" otherwise.
    ///   - pid: the process PorTalistic *did* create, tried first — on the GOG and local paths
    ///     that is Wine itself, which makes the answer exact.
    ///   - hidingLauncher: whether to get PorTalistic out of the way once the game has the
    ///     front. Never before: hiding is also deactivating, and an application that isn't
    ///     active has no front to give away.
    ///   - onAppear: called once, on the main actor, the first time an application belonging
    ///     to this launch turns up. This is the only "the game is up" signal there is — see
    ///     ``superviseGame(named:startedAs:hidingLauncher:onAppear:)``.
    /// - Returns: every application this launch turned into, for whoever wants to know when
    ///   the game has gone.
    @discardableResult
    /// Whether anything is still running in this container.
    ///
    /// Asked at the end of a launch, where the answer decides whether the app may conclude the
    /// game never started — see ``LaunchOutcome/stillRunning``.
    ///
    /// The runtime's own directory is the needle, not the prefix: `WINEPREFIX` is in a wine
    /// process's *environment*, which `pgrep -f` cannot see, while every process of a live
    /// prefix — the game, the preloader, the `wineserver` that outlives them by a moment — runs
    /// a binary from the build's `bin`. There is one container per runtime, so the two
    /// questions have the same answer; and where they differ it is in the safe direction, since
    /// a second game in the same container means "still running" and the app concludes nothing.
    ///
    /// Deliberately not `tasklist(for:)`: asking Wine means starting a Wine process inside the
    /// prefix being asked about.
    static func anythingRunning(under buildDirectory: URL) async -> Bool {
        let build = buildDirectory.path(percentEncoded: false)

        // Anchored to the program being run rather than matched anywhere in the line. A game
        // installed at `…/restart.exe` contains "start.exe", and would have been taken for
        // Wine's own furniture and ignored for ever — silently, since the whole answer is one
        // boolean.
        let furniture = prefixFurniture.flatMap {
            ["\\system32\\\($0)", "/system32/\($0)", "\(build)/\($0)"]
        }

        return await ChildProcesses.anyCommandLineContains(build, ignoring: furniture)
    }

    /// Wine's own processes, which outlive every game that ever ran in a prefix.
    ///
    /// A served prefix keeps a `wineserver` and a handful of Windows services alive long after
    /// the game has gone — that is the whole reason ``isPrefixServerCompatible(_:_:)`` exists —
    /// and every one of them runs a binary from the build's own directory. Counting them as
    /// "the game is still running" made the answer true after every session that has ever
    /// happened, which would have put the verdict for a game that refuses to run out of reach
    /// again: the exact fault this was written to close, moved one step along.
    ///
    /// A game's own process is not on this list, and neither is an installer stub, which is
    /// what keeps the case this exists for: a large game still unpacking on its first run is a
    /// real Windows process with a real name.
    private static let prefixFurniture: [String] = [
        "wineserver", "wineboot", "services.exe", "winedevice.exe", "plugplay.exe",
        "rpcss.exe", "explorer.exe", "svchost.exe", "conhost.exe", "start.exe", "tabtip.exe"
    ]

    /// How long a launch waits for something that looks like the game to turn up.
    ///
    /// Named because a second reader depends on it: a launch where nothing ever arrives lasts
    /// *at least* this long, so ``RecoveryPolicy/neverStartedWithin`` has to be larger or
    /// "nothing started" can never be concluded at all. It was 45 seconds against this 60, and
    /// the four launches that proved it are in one journal: Asphalt Legends, nothing arriving,
    /// sixty seconds each, every one filed as somebody opening a game and changing their mind.
    static let arrivalDeadline: TimeInterval = 60

    static func handOverForeground(toGameNamed executableName: String,
                                   startedAs pid: pid_t,
                                   hidingLauncher: Bool,
                                   onAppear: (@MainActor @Sendable () -> Void)? = nil) async -> Set<pid_t> {
        // Nothing stands aside first. This used to open with `NSApp.deactivate()`, on the
        // reasoning that a new application can't come to the front while this one insists on
        // being there — which was true once and is now exactly backwards. From macOS 14 the
        // front is *given*, not taken, and only the active application has it to give: see
        // ``activate(_:)``. Deactivating before asking threw away the one thing that made the
        // request legal, so the game was left in the background and the launcher wasn't in
        // front of it either.

        // Everything that could already be brought forward, taken before the game can have
        // become one of them, so that whatever turns up next can be told apart from it. This
        // is what identifies the game at all: see ``newestGameApplication(startedAs:named:ignoring:)``.
        let existing: Set<pid_t> = await MainActor.run {
            Set(activatableApplications().map(\.processIdentifier))
        }

        let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier

        /// Every application this launch has turned into. Plural, and that is the point: an
        /// engine that re-launches itself produces the application that owns the window
        /// *second*. Bloodstained is `BloodstainedRotN-Win64-Shipping.exe` behind a stub, and
        /// handing the front to the first Wine process to appear and then stopping is why it
        /// opened behind everything while single-executable games came up fine.
        var ours: Set<pid_t> = .init()

        /// Since when the game has held the front uninterrupted. Reset by every new arrival,
        /// because a stub holding the front is not the game holding the front.
        var activeSince: ContinuousClock.Instant?

        // Long enough for a cold start of a large game off a slow disk. It returns as soon as
        // the game has settled, so this is a ceiling rather than a wait.
        let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(arrivalDeadline))

        while .now < deadline {
            // Force Quit. Without this the loop went on looking for the game for the rest of
            // its minute — and, since `Task.sleep` returns at once for a cancelled task, it
            // looked without pausing, on the main actor, while the launch it belonged to still
            // said "Starting". If the game had got far enough to open a window, it was then
            // handed the front.
            guard !Task.isCancelled else { return ours }

            guard let game = await newestGameApplication(startedAs: pid,
                                                         named: executableName,
                                                         ignoring: existing) else {
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }

            if ours.insert(game.processIdentifier).inserted {
                // Said once, and only for the first: a two-stage engine produces a second
                // application a few seconds later, and the game did not start twice.
                if ours.count == 1, let onAppear {
                    await MainActor.run { onAppear() }
                }

                log.notice("""
                    Foreground: \(game.localizedName ?? executableName, privacy: .public) \
                    [\(game.processIdentifier, privacy: .public)] appeared
                    """)
                activeSince = nil
            }

            let front: pid_t? = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            }

            // Ours to give only while the person hasn't put the front somewhere themselves.
            // Pressing Play is a request to be looking at the game; clicking into a browser
            // thirty seconds later is a request not to be, and that one wins.
            guard let front, front == ownPID || ours.contains(front) else {
                log.notice("Foreground: the person moved to another application; leaving the front where they put it")
                return ours
            }

            guard game.isActive else {
                activeSince = nil
                await activate(game)
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }

            let held = activeSince ?? .now
            activeSince = held

            // Settled: the game has the front and nothing new has started up behind it. Three
            // seconds because Wine's Mac driver applies a deferred display-mode change on
            // activation, and a game that goes fullscreen and immediately drops back to a
            // window is one that lost the front again while doing it.
            guard held.duration(to: .now) > .seconds(3) else {
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }

            // Last, never first — hiding is also deactivating, and an application that isn't
            // active has no front left to give away.
            if hidingLauncher {
                await MainActor.run { NSApp.hide(nil) }
            }

            log.notice("Foreground: \(game.localizedName ?? executableName, privacy: .public) has it")
            return ours
        }

        let candidates = await MainActor.run {
            activatableApplications()
                .map { "\($0.localizedName ?? "?") [\($0.processIdentifier)]" }
                .joined(separator: ", ")
        }

        // Listing what *was* there, because "it never appeared", "it appeared under a name
        // this didn't recognise" and "it appeared, was asked, and refused" need three
        // different fixes and look identical from the outside.
        log.notice("""
            \(executableName, privacy: .public) never settled in the foreground. \
            Applications that could have been brought forward: \(candidates, privacy: .public)
            """)

        return ours
    }

    /// Follows a game from "we asked for it" until it has gone.
    ///
    /// A launch operation used to end when the process this app started returned, and on the
    /// Epic path that is `legendary` handing the game to Wine and exiting — seconds after
    /// Play, with the game still loading. Everything the interface knew about a running game
    /// came from that, so Play went live again while the game was up (a second press started a
    /// second copy), the spinner was a six-second guess, and a running game vanished from
    /// Operations with no way left to stop it.
    ///
    /// So the launch keeps this, and this keeps the game: `onAppear` fires when the game
    /// actually exists, and the call returns when every application it turned into has gone.
    /// A launch that never produces one returns when the hand-off gives up, about a minute in,
    /// rather than waiting for something that is not coming.
    @discardableResult
    static func superviseGame(named executableName: String,
                              startedAs pid: pid_t,
                              hidingLauncher: Bool,
                              forGameWithID gameID: Game.ID) async -> LaunchOutcome {
        await superviseGame(named: executableName, startedAs: pid, hidingLauncher: hidingLauncher) {
            Game.operationManager.noteGameAppeared(forGameID: gameID)
        }
    }

    /// ``superviseGame(named:startedAs:hidingLauncher:forGameWithID:)`` for a caller that may
    /// not know what the game's executable is called.
    ///
    /// Without a name there is nothing to tell the game apart from whatever else the person
    /// happens to open while it starts, so nothing is followed and the launch ends with the
    /// process it started — which is what every launch used to do.
    @discardableResult
    static func superviseGame(named executableName: String?,
                              startedAs pid: pid_t,
                              hidingLauncher: Bool,
                              forGameWithID gameID: Game.ID) async -> LaunchOutcome {
        guard let executableName else {
            // Worth a line: from the outside this is indistinguishable from a game that
            // started and exited immediately — the launch simply ends, Play comes back, and
            // nothing ever said the game was running. On the Epic path it means the
            // installation data couldn't be read.
            log.notice("Nothing to follow for [\(gameID, privacy: .public)]: no executable name, so the launch ends with the process it started")
            return .init(appeared: false, ranFor: 0)
        }

        return await superviseGame(named: executableName,
                                   startedAs: pid,
                                   hidingLauncher: hidingLauncher,
                                   forGameWithID: gameID)
    }

    /// Supervise a game, then read what its launch left behind.
    ///
    /// The one call the launch paths make. Supervision and the post-mortem are one call on
    /// purpose: they need the same three facts — when it started, whether it appeared, and
    /// which transcript is this launch's — and splitting them is how a launch path ends up
    /// diagnosing the *previous* run's log.
    ///
    /// The post-mortem is deliberately last and deliberately cheap: by the time it runs the
    /// game has exited, nothing is appending to the transcript, and no container is being
    /// served. Nothing it decides takes effect until the next launch.
    static func superviseGame(named executableName: String?,
                              startedAs pid: pid_t,
                              hidingLauncher: Bool,
                              forGameWithID gameID: Game.ID,
                              plan: Provisioner.LaunchPlan?,
                              transcriptAt transcriptURL: URL?) async {
        var outcome = await superviseGame(named: executableName,
                                          startedAs: pid,
                                          hidingLauncher: hidingLauncher,
                                          forGameWithID: gameID)

        guard let plan, let facts = plan.facts else { return }

        // Cancelled means force-quit, and that was the person's decision rather than anything
        // the game did. Judged like any other launch it was a no-show — nothing had appeared,
        // and it lasted seconds — so pressing Force Quit on a game that was starting too slowly
        // reconfigured it. See `RecoveryPolicy.judgesForceQuit(ranFor:)`.
        if Task.isCancelled, !RecoveryPolicy.judgesForceQuit(ranFor: outcome.ranFor) { return }

        // Asked once, at the one moment it means anything: the watching has stopped, and
        // whether the game is still there is what decides what that silence was.
        outcome.stillRunning = await anythingRunning(under: plan.runtimeBinaryDirectory)

        await RecoveryCoordinator.shared.launchFinished(facts: facts,
                                                        outcome: outcome,
                                                        transcriptURL: transcriptURL,
                                                        containerURL: plan.containerURL,
                                                        runtimeID: plan.runtimeID,
                                                        applied: plan.settings,
                                                        effective: plan.effectiveSettings,
                                                        winetricks: plan.winetricks,
                                                        backendInEffect: plan.graphicsBackend,
                                                        requirements: plan.requirements,
                                                        usesDirect3DEleven: plan.requirements.direct3DOnMetal)
    }

    @discardableResult
    static func superviseGame(named executableName: String,
                              startedAs pid: pid_t,
                              hidingLauncher: Bool,
                              onAppear: (@MainActor @Sendable () -> Void)? = nil) async -> LaunchOutcome {
        let startedAt: Date = .now

        let family = await handOverForeground(toGameNamed: executableName,
                                              startedAs: pid,
                                              hidingLauncher: hidingLauncher,
                                              onAppear: onAppear)

        await waitUntilGone(family, named: executableName)

        // An empty family means nothing that looked like the game ever arrived, which is the
        // difference between "the person quit" and "it never started" — and the only signal
        // there is for the latter, since macOS names a running Windows game "Wine".
        return .init(appeared: !family.isEmpty, ranFor: Date.now.timeIntervalSince(startedAt))
    }

    /// Waits until every application in `family` has exited.
    ///
    /// Polled rather than observed: `NSWorkspace.didTerminateApplicationNotification` is only
    /// posted for applications AppKit is tracking, and a Wine process that transformed itself
    /// into one mid-flight is exactly the case where that has been unreliable. Two seconds is
    /// far below anything a person would notice on the way out of a game, and the check is a
    /// lookup in a list AppKit already keeps.
    ///
    /// Deliberately does *not* adopt applications that appear after the hand-off settled: by
    /// then anything new is as likely to be a second game the person started as it is to be
    /// part of this one, and claiming it would leave a game listed as running long after it
    /// quit.
    private static func waitUntilGone(_ family: Set<pid_t>, named executableName: String) async {
        guard !family.isEmpty else { return }

        while !Task.isCancelled {
            let stillRunning: Set<pid_t> = await MainActor.run {
                family.filter { NSRunningApplication(processIdentifier: $0)?.isTerminated == false }
            }

            if stillRunning.isEmpty {
                log.notice("\(executableName, privacy: .public) has exited")
                return
            }

            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Give the front away to a game, the way macOS 14 and later require.
    ///
    /// Cooperative activation: an application can no longer simply take the front, and
    /// `activate(options:)` called by a process that isn't the active one is ignored outright.
    /// The active application has to hand it over, naming itself as the source — which is what
    /// `activate(from:)` is, and why this is called while PorTalistic is still in front.
    @MainActor
    private static func activate(_ application: NSRunningApplication) {
        NSApp.yieldActivation(to: application)

        if !application.activate(from: .current, options: [.activateAllWindows]) {
            log.warning("""
                \(application.localizedName ?? "The game", privacy: .public) refused the foreground
                """)
        }
    }

    /// Applications that activating would actually do something to.
    ///
    /// `.regular` only. The process this app starts is `legendary` on the Epic path and a Wine
    /// loader on the others, and neither of them owns a window: they come back from
    /// `NSRunningApplication(processIdentifier:)` with an activation policy that makes
    /// activating them do nothing at all, which is what made handing over the foreground look
    /// like it had worked while nothing came to the front. Wine's Mac driver turns a process
    /// into a `.regular` application at the moment it gives it a window, so this is also the
    /// test for "has a window yet".
    @MainActor
    private static func activatableApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    /// The most recently started application belonging to this launch.
    ///
    /// Identity comes from *arrival*, not from the name. macOS shows a running Windows game as
    /// **"Wine"** in the menu bar — it is there in every screenshot of this — so `localizedName`
    /// is whatever `winemac.drv` decided and is only sometimes the executable's. Anything that
    /// was already activatable before the launch is excluded, so a new arrival can be
    /// recognised without knowing what it will end up being called.
    ///
    /// - Parameters:
    ///   - pid: the process PorTalistic started. On the GOG and local paths that is Wine
    ///     itself, which makes the answer exact; on the Epic path it is `legendary`, which
    ///     spawns Wine detached and is never the answer.
    ///   - executableName: a hint, used when Wine did name the application after it.
    @MainActor
    private static func newestGameApplication(startedAs pid: pid_t,
                                              named executableName: String,
                                              ignoring existing: Set<pid_t>) -> NSRunningApplication? {
        var candidates: [NSRunningApplication] = .init()

        if let direct = NSRunningApplication(processIdentifier: pid), direct.activationPolicy == .regular {
            candidates.append(direct)
        }

        let name = (executableName as NSString).deletingPathExtension

        candidates += activatableApplications().filter { application in
            guard !existing.contains(application.processIdentifier) else { return false }

            // Narrowed to Wine rather than "anything new", so that an application the person
            // happened to open during the same few seconds can't be dragged to the front.
            return application.localizedName?.localizedCaseInsensitiveContains(name) == true
                || application.executableURL?.path.localizedCaseInsensitiveContains("wine") == true
        }

        // Highest pid, meaning the most recently started: for a two-stage engine the stub comes
        // first and the process that owns the window comes second.
        return candidates.max { $0.processIdentifier < $1.processIdentifier }
    }
}
