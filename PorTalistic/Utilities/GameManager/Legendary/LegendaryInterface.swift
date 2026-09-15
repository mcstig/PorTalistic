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

    private static var legendaryExecutableURL: URL { Bundle.main.url(forResource: "legendary/cli", withExtension: nil)! }

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
    
    static func handleCLIErrorOutput(fromStandardErrorOutput output: String) throws {
        for line in output.split(whereSeparator: \.isNewline) {
            if let match = try? Regex(#"(ERROR|CRITICAL): (.*)"#).firstMatch(in: line),
               let errorReason = match.last?.substring {
                
                // TODO: dedicated handling for 'Failed to acquire installed data lock, only one instance of Legendary may install/import/move applications at a time.'
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
    static func executeStreamed(_ process: Process,
                                throwsOnChunkError: Bool = true,
                                chunkHandler: @Sendable @escaping (Process.OutputChunk) throws -> String?) async throws {
        await transformProcess(process)
        
        try await process.runStreamed(
            throwsOnChunkError: throwsOnChunkError,
            chunkHandler: { chunk in
                if case .standardError = chunk.stream {
                    try handleCLIErrorOutput(fromStandardErrorOutput: chunk.output)
                }
                
                return try chunkHandler(chunk)
            }
        )
    }

    /// Parse legendary's DLManager status output, and use it to update a `Progress` object.
    private static func handleDownloadManagerOutputProgress(for output: String,
                                                            progress: Progress) {
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
            progress.completedUnitCount = Int64(Double(match["percentage"]?.substring ?? .init())?.rounded() ?? 0)

            progress.estimatedTimeRemaining = TimeInterval(HH_MM_SSString: String(match["eta"]?.substring ?? .init()))
            progress.fileCompletedCount = Int(match["downloadedObjects"]?.substring ?? .init()) ?? 0
            progress.fileTotalCount = Int(match["totalObjects"]?.substring ?? .init()) ?? 0
        }

        if let match = try? downloadSpeedRegex.firstMatch(in: output) {
            // convert raw download speed from MiB/s to B/s by multiplying by 1024^2
            progress.throughput = (Int(Double(match["raw"]?.substring ?? .init()) ?? 0)) * Int(pow(1024.0, 2.0))
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
    static func install(game: EpicGamesGame,
                        forPlatform platform: Game.Platform,
                        qualityOfService: QualityOfService,
                        optionalPackIDs: [String] = .init(),
                        baseDirectoryURL: URL? = UserDefaults.standard.url(forKey: "installBaseURL")) async throws -> GameOperation {
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

        let operation: GameOperation = .init(game: game, type: .install) { [arguments] progress in
            progress.totalUnitCount = 100
            progress.fileOperationKind = .downloading

            let process: Process = .init()
            process.arguments = arguments
            
            try await withTaskCancellationHandler {
                try await executeStreamed(process) { chunk in
                    // append optional packs to legendary's stdin when it requests for them
                    if case .standardOutput = chunk.stream {
                        if chunk.output.contains("Additional packs"), !optionalPackIDs.isEmpty {
                            return optionalPackIDs.joined(separator: ", ") + "\n" // use \n as return key
                        }
                    }
                    
                    if case .standardError = chunk.stream {
                        handleDownloadManagerOutputProgress(for: chunk.output,
                                                            progress: progress)
                    }
                    
                    return nil
                }
            } onCancel: {
                process.interrupt()
            }
        }

        operation.qualityOfService = qualityOfService
        await Game.operationManager.queueOperation(operation)
        return operation
    }

    @discardableResult
    static func update(game: EpicGamesGame, qualityOfService: QualityOfService) async throws -> GameOperation {
        let arguments: [String] = ["-y", "install", game.id, "--update-only"]

        let operation: GameOperation = .init(game: game, type: .update) { progress in
            progress.totalUnitCount = 100
            progress.fileOperationKind = .downloading

            let process: Process = .init()
            process.arguments = arguments
            
            try await withTaskCancellationHandler {
                try await executeStreamed(process) { chunk in
                    if case .standardError = chunk.stream {
                        handleDownloadManagerOutputProgress(for: chunk.output,
                                                            progress: progress)
                    }
                    
                    return nil
                }
            } onCancel: {
                process.interrupt()
            }
        }

        operation.qualityOfService = qualityOfService
        await Game.operationManager.queueOperation(operation)
        return operation
    }

    @discardableResult
    static func repair(game: EpicGamesGame, qualityOfService: QualityOfService) async throws -> GameOperation {
        let arguments: [String] = ["-y", "install", game.id, "--repair"]

        let operation: GameOperation = .init(game: game, type: .repair) { progress in
            progress.totalUnitCount = 100
            progress.fileOperationKind = .downloading

            // note that throwsOnChunkError is disabled, as if a file does not match hash, a `GenericError` is thrown
            // due to the custom error handling in onChunkWithLegendaryErrorHandling.
            // thus, chunk errors are only acknowledged but not thrown.
            // this is bad though for obvious reasons
            let process: Process = .init()
            process.arguments = arguments
            
            try await withTaskCancellationHandler {
                try await executeStreamed(process, throwsOnChunkError: false) { chunk in
                    switch chunk.stream {
                    case .standardError:
                        // if game files require redownload
                        handleDownloadManagerOutputProgress(for: chunk.output,
                                                            progress: progress)
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
            } onCancel: {
                process.interrupt()
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

                    """
                try? transcript.handle.write(contentsOf: Data(header.utf8))
                process.standardError = transcript.handle
            } else {
                process.standardError = processStandardErrorPipe
            }

            try await withTaskCancellationHandler {
                try process.run()

                guard let transcript else {
                    try handleCLIErrorOutput(fromStandardErrorPipe: processStandardErrorPipe)
                    return
                }

                // Waiting is what the pipe did implicitly by reading to EOF, and the comment
                // below about giving the container back depends on it.
                process.waitUntilExit()
                try? transcript.handle.close()
                Self.log.notice("Launch transcript: \(transcript.url.prettyPath, privacy: .public)")

                if let output = try? String(contentsOf: transcript.url, encoding: .utf8) {
                    try handleCLIErrorOutput(fromStandardErrorOutput: output)
                }
            } onCancel: {
                // FIXME: legendary will spawn wine completely detached from the cli itself
                // FIXME: because of this, terminating the process used to launch it will NOT
                // FIXME: terminate the wine subprocess.. this is a KNOWN ISSUE
                process.terminate()
            }

            // Put the container back. Containers are shared by every game on the same
            // runtime, so this game's settings left behind would quietly become the next
            // game's. Waiting for legendary to exit is as close to "the game exited" as this
            // path gets: legendary waits for the Wine it started, even though the game itself
            // ends up detached from it.
            if let plan { await Provisioner.shared.revert(plan) }
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

    /// Holds values parsed out of legendary's output by reference, so the streaming
    /// handler doesn't have to capture and concurrently mutate local variables.
    private final class PreInstallationMetadata: @unchecked Sendable {
        var installSize: Int64?
        var optionalPacks: [String: String] = .init()
    }

    static func fetchPreInstallationMetadata(
        game: EpicGamesGame,
        platform: Game.Platform
    ) async throws -> (installSize: Int64?, optionalPacks: [String: String]) {
        guard case .uninstalled = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let arguments: [String] = ["install", game.id, "--platform", matchPlatform(for: platform)]

        let metadata = PreInstallationMetadata()

        // if the data lock is present, legendary will terminate itself, so this is ok
        // nice n safe
        let process: Process = .init()
        process.arguments = arguments
        
        // note that install size and optional packs are mutually exclusive in this context.
        try await withTaskCancellationHandler {
            try await executeStreamed(process) { chunk in
                switch chunk.stream {
                case .standardError:
                    // Handle install size.
                    // Parsed inline rather than in a detached Task: the previous version
                    // could still have the parse pending when this function returned,
                    // silently dropping the size (and the optional packs below).
                    // legendary always returns install size in MiB
                    if let match = try? Regex(#"Install size: (\d+(?:\.\d+)?) MiB"#).firstMatch(in: chunk.output),
                       let sizeString = match[1].substring,
                       let sizeValue = Double(sizeString) {
                        metadata.installSize = Int64(Int(sizeValue) * 1_048_576) // MiB ➜ B

                        process.interrupt()
                    }

                case .standardOutput:
                    // Handle optional packs
                    if let match = try? Regex(#"\s*\* (?<identifier>\w+) - (?<name>.+)"#).firstMatch(in: chunk.output),
                       let id = match["identifier"]?.substring,
                       let name = match["name"]?.substring {
                        metadata.optionalPacks[String(id)] = String(name)
                    }
                    
                    if chunk.output.contains("Please enter tags of pack(s) to install") {
                        process.interrupt()
                    }
                    
                    // Handle installation requirements check results
                    /* TODO: not implemented, may be unnecessary
                     if chunk.output.contains(" - Warning:") {
                     
                     }
                     
                     if chunk.output.contains(" ! Failure:") {
                     
                     }
                     */
                }
                
                return nil
            }
        } onCancel: {
            process.interrupt()
        }
        
        return (metadata.installSize, metadata.optionalPacks)
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
            guard let platform: Game.Platform = installedGame.platform else { return nil }
            
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

    static func getGameMetadata(gameID: String) throws -> GameMetadata {
        let metadataDirectory: URL = configurationFolder.appending(path: "metadata")
        let metadataDirectoryContents = try FileManager.default.contentsOfDirectory(atPath: metadataDirectory.path)

        guard let metadataFileName: String = metadataDirectoryContents.first(where: { $0 == gameID.appending(".json") }) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let data: Data = try .init(contentsOf: URL(filePath: metadataDirectory.appending(path: metadataFileName).path))
        let metadata: GameMetadata = try JSONDecoder().decode(GameMetadata.self, from: data)

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
        case "Windows": .windows
        case "Mac":     .macOS
        default:        nil
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
