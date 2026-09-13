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
        return try decoder.decode(Container.self, from: .init(contentsOf: containerURL.appending(path: "Properties.plist")))
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

    static func transformProcess(_ process: Process, containerURL: URL) {
        let runtime = runtime(forContainerAtURL: containerURL)
        process.executableURL = runtime.executableURL

        var capturedEnvironment = process.environment ?? [:]

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
        capturedEnvironment.merge(supportLibraryEnvironment(forRuntimeAt: root), uniquingKeysWith: { $1 })

        // A CrossOver-derived Wine resolves its own tree from `CX_ROOT`, and Mythic sets that
        // to Mythic.app at launch for the bundled engine. Handing it to any *other* runtime
        // points that runtime at a tree with no Wine in it, and the failure is silent in the
        // worst way: `wine --version` answers fine, because it needs nothing from the tree,
        // while every attempt to start a Windows process ends as a loader Wine forked, could
        // not exec, and reported only as
        //
        //     err:environ:run_wineboot failed to start wineboot 1
        //
        // So each runtime gets its own root, and only the bundled engine keeps Mythic's.
        if case .bundledEngine = runtime.origin, let cxRoot = ProcessInfo.processInfo.environment["CX_ROOT"] {
            capturedEnvironment["CX_ROOT"] = cxRoot
        }

        process.environment = constructEnvironment(with: containerURL, additionalVariables: capturedEnvironment)
    }

    /// The variables a runtime needs regardless of which of its binaries is being run.
    private static func supportLibraryEnvironment(forRuntimeAt runtimeRoot: URL) -> [String: String] {
        let frameworks = runtimeRoot.appending(path: RuntimeInstaller.supportLibrariesDirectoryName)
        guard FileManager.default.fileExists(atPath: frameworks.path) else { return [:] }

        return ["DYLD_FALLBACK_LIBRARY_PATH":
                    [frameworks.path, "/usr/local/lib", "/usr/lib"].joined(separator: ":")]
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

    /// Shuts down whichever `wineserver` is holding this prefix, whatever runtime it came from.
    ///
    /// The runtime that started the server may no longer be the container's selected one —
    /// that mismatch is the whole reason we're here — so asking the *current* runtime's
    /// `wineserver -k` to do it finds nothing and changes nothing. Every known runtime gets
    /// asked instead; the ones that aren't serving this prefix simply do nothing.
    static func shutdownPrefix(at containerURL: URL) async {
        for runtime in Runtime.discoverAll() where runtime.isInstalled {
            guard FileManager.default.isExecutableFile(atPath: runtime.wineserverURL.path) else { continue }

            let process: Process = .init()
            process.executableURL = runtime.wineserverURL
            process.arguments = ["-k"]
            // Inherit the environment rather than replacing it. A bare
            // ["WINEPREFIX": …] strips HOME, PATH and TMPDIR, and wineserver without those
            // exits having done nothing at all — which is indistinguishable, from here,
            // from a kill that worked.
            var environment = ProcessInfo.processInfo.environment
            environment["WINEPREFIX"] = containerURL.path
            process.environment = environment
            process.qualityOfService = .utility

            let result = await process.runWrapped(timeout: .seconds(8))
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
            String(localized: "Quit and reopen Mythic. If that doesn't clear it, the container was built by the older Wine and needs to be recreated.")
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
        let result = try await process.runWrapped()

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
            direct.environment = constructEnvironment(
                with: containerURL,
                additionalVariables: supportLibraryEnvironment(forRuntimeAt: root)
                    .merging(["WINEDEBUG": "+server,+seh,+process"], uniquingKeysWith: { $1 })
            )

            if let output = try? await direct.runWrapped() {
                lines.append("derived loader, wineboot --init: exit=\(direct.terminationStatus)")
                lines.append("  stdout: \(String((output.standardOutput ?? "").suffix(4_000)))")
                lines.append("  stderr: \(String((output.standardError ?? "").suffix(40_000)))")
            } else {
                lines.append("derived loader, wineboot --init: couldn't be run at all")
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
                throw Container.UnableToBootError()
            }

            containerURLs.insert(url)

            try await toggleRetinaMode(containerURL: url, toggle: settings.retinaMode)
            try await setWindowsVersion(containerURL: url, version: settings.windowsVersion)
            try await setDisplayScaling(containerURL: url, dpi: settings.scaling)

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

    /// - Returns: Relevant environment variables as configured in a container for game launch.
    static func assembleEnvironmentVariables(forContainerAtURL containerURL: URL, container: Container? = nil) throws -> [String: String] {
        guard containerExists(at: containerURL) else { throw Wine.Container.DoesNotExistError() }

        let container = try container ?? getContainerObject(at: containerURL)
        var environmentVariables: [String: String] = [:]

        environmentVariables["WINEMSYNC"] = container.settings.msync.numericalValue.description
        environmentVariables["ROSETTA_ADVERTISE_AVX"] = container.settings.avx2.numericalValue.description

        if container.settings.dxvk {
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
            environmentVariables["WINEDLLOVERRIDES"] = "dxgi,d3d10core,d3d11=n,b"
            environmentVariables["DXVK_ASYNC"] = container.settings.dxvkAsync.numericalValue.description
        }

        if container.settings.metalHUD {
            if container.settings.dxvk {
                environmentVariables["DXVK_HUD"] = "full"
            } else {
                environmentVariables["MTL_HUD_ENABLED"] = "1"
            }
        }

        return environmentVariables
    }

    static func deleteContainer(containerURL: URL) throws {
        log.notice("Deleting container \(containerURL.lastPathComponent) (\(containerURL))")
        guard containerExists(at: containerURL) else { throw Container.DoesNotExistError() }

        try FileManager.default.removeItem(at: containerURL)
        containerURLs.remove(containerURL)
    }

    static func killAll(at urls: URL...) throws {
        let urls: [URL] = urls.isEmpty ? .init(containerURLs) : urls

        for url in urls {
            // wineserver has to be the one belonging to the container's own runtime.
            // Shutting a Wine 11 prefix down with the 7.7 engine's wineserver won't find
            // the running processes, and the container would appear to hang.
            let process: Process = .init()
            process.executableURL = runtime(forContainerAtURL: url)
                .executableURL
                .deletingLastPathComponent()
                .appending(path: "wineserver")
            process.arguments = ["-k"]

            Task {
                // Inherited, not replaced — see `shutdownPrefix(at:)`.
                var environment = ProcessInfo.processInfo.environment
                environment["WINEPREFIX"] = url.path
                process.environment = environment
                process.qualityOfService = .utility

                try process.run()
            }
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

    static func queryRegistryKey(containerURL: URL, key: String, name: String, type: RegistryType) async throws -> String {
        let process: Process = .init()
        process.arguments = ["reg", "query", key, "-v", name]
        transformProcess(process, containerURL: containerURL)
        
        let commandResult = try await process.runWrapped()

        try process.checkTerminationStatus()

        // Gather non-empty, trimmed lines; return the last occurrence
        let lines = commandResult.standardOutput?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let last = lines?.last {
            return last
        } else {
            throw UnableToQueryRegistryError()
        }
    }

    static func toggleRetinaMode(containerURL: URL, toggle: Bool) async throws {
        do {
            try await addRegistryKey(containerURL: containerURL,
                                     key: RegistryKey.macDriver.rawValue,
                                     name: "RetinaMode",
                                     data: toggle ? "y" : "n",
                                     type: .string)

            // adjust display scaling accordingly; hard values of 192 and 96 seemingly work
            try await setDisplayScaling(containerURL: containerURL, dpi: toggle ? 192 : 96)
        } catch {
            log.error("\(formatLog(containerURL: containerURL, description: "Unable to toggle retina mode \(toggle)", error: error))")
            throw error
        }
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
        process.environment = [
            "HOME": homeDirectory,
            "USER": NSUserName(),
            "XDG_CACHE_HOME": cacheDirectory,
            "WINEPREFIX": containerURL.path,
            "WINE": Engine.wineExecutableURL.path,
            "WINE64": Engine.wineExecutableURL.path,  // FIXME: should follow the container's runtime
            "WINESERVER": wineBinDirectory.appending(path: "wineserver").path,
            "WINEARCH": "win64",
            "PATH": "\(wineBinDirectory.path):/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin",
            "DYLD_FALLBACK_LIBRARY_PATH": "\(wineLibDirectory.path):/usr/lib",
            "WINETRICKS_WINE_IS_64BIT": "true",
            "DISPLAY": "",  // Disable X11 display requirements
            "TERM": "xterm-256color"
        ]
        
        log.info("\(formatLog(containerURL: containerURL, description: "Running winetricks verb: \(verb)"))")
        
        if let onOutput {
            // Stream output in real-time
            try await process.runStreamed(throwsOnChunkError: false) { chunk in
                onOutput(chunk.output)
                return nil
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
    /// So Mythic steps back and then brings the game forward itself, rather than leaving the
    /// player to do it before the game gets as far as asking.
    ///
    /// - Parameters:
    ///   - executableName: the game's executable, e.g. `Prey.exe`. Wine names the application
    ///     after it, which is the only handle on a process Mythic didn't create directly.
    ///   - pid: the process Mythic *did* create, tried first — it's the same application in
    ///     the common case, and unambiguous when it is.
    static func handOverForeground(toGameNamed executableName: String,
                                   startedAs pid: pid_t,
                                   hidingLauncher: Bool) async {
        await MainActor.run {
            // Standing aside first: a new application can't come to the front while this one
            // is still insisting on being there.
            if hidingLauncher {
                NSApp.hide(nil)
            } else {
                NSApp.deactivate()
            }
        }

        // Wine takes a moment to get as far as creating a window, and a game rather longer.
        // Polling rather than waiting a fixed time, because "rather longer" is the shape of a
        // number that is always wrong on someone else's machine.
        let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30))

        while .now < deadline {
            if let application = await runningApplication(pid: pid, named: executableName) {
                if application.isActive { return }

                await MainActor.run { _ = application.activate(options: []) }

                // One follow-up, because the window the game wants to make fullscreen may not
                // exist yet at the moment it first appears in the Dock.
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { _ = application.activate(options: []) }
                return
            }

            try? await Task.sleep(for: .milliseconds(300))
        }

        log.notice("\(executableName, privacy: .public) never appeared as an application; it may open behind Mythic")
    }

    @MainActor
    private static func runningApplication(pid: pid_t, named executableName: String) -> NSRunningApplication? {
        if let direct = NSRunningApplication(processIdentifier: pid) { return direct }

        // Wine re-executes itself on the way to a Windows process, so the application that
        // ends up owning the window is usually a descendant rather than the process we
        // spawned. Wine names it after the executable, which is what's left to match on.
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.localizedCaseInsensitiveContains(executableName) == true
        }
    }
}
