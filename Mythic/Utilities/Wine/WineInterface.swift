//
//  WineInterface.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 30/10/2023.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
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
        var constructedEnvironment: [String: String] = .init()
        
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
        process.executableURL = runtime(forContainerAtURL: containerURL).executableURL

        let capturedEnvironment = process.environment
        process.environment = constructEnvironment(with: containerURL, additionalVariables: capturedEnvironment ?? [:])
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

            let result = try? await process.runWrapped()
            if let stderr = result?.standardError, !stderr.isEmpty {
                log.debug("wineserver -k (\(runtime.name, privacy: .public)): \(stderr, privacy: .public)")
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
        process.arguments = ["tasklist"]
        transformProcess(process, containerURL: containerURL)
        
        let commandResult = try await process.runWrapped()
        
        if let standardOutput = commandResult.standardOutput {
            let tasklistRegex: Regex<AnyRegexOutput>?
            // wine above major version 7 has a new tasklist format
            // swiftlint:disable force_try
            if self.retrieveVersion()?.major ?? 0 > 7 {
                tasklistRegex = try! Regex(#"^\s*(?<ImageName>.+?)\s+(?<PID>\d+)\s+(?<SessionName>\S+)\s+(?<SessionNum>\d+)\s+(?<MemUsage>[\d,]+ K)$"#)
            } else {
                tasklistRegex = try! Regex(#"(?P<ImageName>[^,]+?),(?P<PID>\d+)"#)
            }
            // swiftlint:enable force_try
            
            for line in standardOutput.split(whereSeparator: \.isNewline) {
                guard let match = try tasklistRegex?.wholeMatch(in: line) else { continue }
                
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
        transformProcess(process, containerURL: containerURL)
        return try await process.runWrapped()
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
            environmentVariables["WINEDLLOVERRIDES"] = "d3d10core,d3d11=n,b"
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
}
