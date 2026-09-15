//
//  GOGDLInterface.swift
//  Mythic
//
//  Created by Claude (Cowork) on 13/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/// `gogdl`, the downloader Mythic shells out to for GOG installs.
///
/// The same arrangement Epic has with `legendary`, and for the same reason: GOG serves games
/// through its Galaxy content system — builds, depot manifests, files split into hashed
/// chunks fetched over signed, time-limited CDN links, and updates expressed as a delta
/// between two builds. Writing that is a subsystem, and getting it subtly wrong shows up as a
/// corrupted install at 80% of a 60GB download rather than as an error. `gogdl` is the tool
/// Heroic uses for exactly this, so Mythic bundles it rather than reimplementing it.
///
/// Authentication is shared rather than duplicated: both sides read and write
/// ``GOG/authConfigURL``. See ``GOG/StoredCredentials`` for why that matters.
enum GOGDL {
    static let log: Logger = .custom(category: "GOGDLInterface")

    /// The bundled binary for this machine's architecture.
    ///
    /// Two are shipped rather than one fat binary, because the upstream releases are per-arch
    /// and merging them would mean carrying a build step for a file Mythic doesn't compile.
    /// Under Rosetta this picks the x86_64 one, which is correct — the translated process is
    /// what would have to exec it.
    static var executableURL: URL? {
        #if arch(arm64)
        let name = "gogdl/gogdl_arm64"
        #else
        let name = "gogdl/gogdl_x86_64"
        #endif

        return Bundle.main.url(forResource: name, withExtension: nil)
    }

    // MARK: - Errors

    struct NotBundledError: LocalizedError {
        var errorDescription: String? { String(localized: "PorTalistic's GOG downloader is missing.") }
        var recoverySuggestion: String? { String(localized: "Reinstalling PorTalistic should restore it.") }
    }

    struct UnsupportedPlatformError: LocalizedError {
        let title: String
        let platform: Game.Platform
        var errorDescription: String? { String(localized: "GOG doesn't offer \(title) for \(platform.description).") }
    }

    struct MetadataUnavailableError: LocalizedError {
        var errorDescription: String? { String(localized: "GOG didn't say how to install this game.") }
        var recoverySuggestion: String? {
            String(localized: "It may not be distributed through GOG Galaxy. Try again, or install it from an offline installer and add it from Import Game › Local.")
        }
    }

    struct OperationFailedError: LocalizedError {
        let terminationStatus: Int32
        var errorDescription: String? { String(localized: "The GOG download didn't finish.") }
        var failureReason: String? { "gogdl exited with status \(terminationStatus)" }
        var recoverySuggestion: String? {
            String(localized: "Starting it again resumes from where it stopped.")
        }
    }

    // MARK: - Invocation

    /// gogdl's name for a platform, which is not Mythic's.
    private static func platformArgument(for platform: Game.Platform) -> String {
        switch platform {
        case .macOS: "osx"
        case .windows: "windows"
        }
    }

    private static func makeProcess(arguments: [String]) throws -> Process {
        guard let executableURL else { throw NotBundledError() }

        try FileManager.default.createDirectory(at: GOG.configurationFolder, withIntermediateDirectories: true)

        let process: Process = .init()
        process.executableURL = executableURL
        process.arguments = ["--auth-config-path", GOG.authConfigURL.path] + arguments

        // gogdl keeps per-game depot manifests so an update is a delta rather than a refetch.
        // Left alone it puts them in a `heroic_gogdl` folder of its own; pointing it here keeps
        // everything GOG in one place, and makes signing out able to take the whole lot.
        var environment = ProcessInfo.processInfo.environment
        environment["GOGDL_CONFIG_PATH"] = GOG.configurationFolder.path
        process.environment = environment

        return process
    }

    // MARK: - Language

    /// The language to install, as GOG names it.
    ///
    /// This is asked of gogdl rather than derived here, because gogdl looks the tag up in a
    /// fixed table and *crashes* on a miss — `en-AU` and `pt-PT` are perfectly ordinary
    /// locales that aren't in it. `lang-match` is the same lookup exposed as a command, so
    /// asking it is the one way to know the answer without carrying a copy of the table that
    /// would drift out of date.
    private nonisolated(unsafe) static var memoizedLanguage: String?

    /// Cached across launches, not just in memory: resolving it costs a whole process spawn,
    /// and a PyInstaller binary unpacks ~11MB of itself before it will answer anything. The
    /// locale would have to change for the answer to, and that invalidates it below.
    private static let languageDefaultsKey = "gogInstallLanguage"

    static func installLanguage() async -> String {
        if let memoizedLanguage { return memoizedLanguage }

        let storedLocale = UserDefaults.standard.string(forKey: "\(languageDefaultsKey).locale")
        if storedLocale == Locale.current.identifier,
           let stored = UserDefaults.standard.string(forKey: languageDefaultsKey) {
            memoizedLanguage = stored
            return stored
        }

        let fallback = "en-US"
        var candidates: [String] = [Locale.current.identifier(.bcp47)]
        if let code = Locale.current.language.languageCode?.identifier {
            candidates.append(code)
        }

        for candidate in candidates where !candidate.isEmpty {
            guard let process = try? makeProcess(arguments: ["lang-match", candidate]),
                  let result = await process.runWrapped(timeout: .seconds(30)),
                  let output = result.standardOutput?.data(using: .utf8),
                  let matched = try? JSONDecoder().decode(MatchedLanguage.self, from: output),
                  let code = matched.code else { continue }

            remember(language: code)
            return code
        }

        remember(language: fallback)
        return fallback
    }

    private static func remember(language: String) {
        memoizedLanguage = language
        UserDefaults.standard.set(language, forKey: languageDefaultsKey)
        UserDefaults.standard.set(Locale.current.identifier, forKey: "\(languageDefaultsKey).locale")
    }

    private struct MatchedLanguage: Decodable {
        /// Absent when nothing matched — gogdl prints `{}` rather than failing.
        let code: String?
    }

    // MARK: - Metadata

    /// What `gogdl info` answers with: everything needed to decide whether to install, and where.
    struct Metadata {
        /// Sizes keyed by language, with `*` holding the part every language shares.
        /// A game's real cost is `*` plus the one language being installed.
        let sizes: [String: Size]
        /// The folder GOG expects the game to live in, e.g. `Cyberpunk 2077`.
        ///
        /// Not derived from the title: GOG's own name for the directory is what its installers,
        /// its save paths and its own launcher use, and a game moved out from under Galaxy
        /// should still be where Galaxy would have put it.
        let folderName: String
        let buildID: String?
        let versionName: String?
        let availableLanguages: [String]

        struct Size {
            let download: Int64
            let disk: Int64
        }

        func size(inLanguage language: String) -> Size {
            let shared = sizes["*"]
            let specific = sizes[language]

            return .init(download: (shared?.download ?? 0) + (specific?.download ?? 0),
                         disk: (shared?.disk ?? 0) + (specific?.disk ?? 0))
        }
    }

    /// Answers are kept for a few minutes, because getting one is expensive and the same
    /// question gets asked twice in a row: once by the installation sheet to show a size, and
    /// again by the install itself to learn the folder name.
    private struct CachedMetadata {
        let metadata: Metadata
        let fetched: Date
        var isFresh: Bool { Date().timeIntervalSince(fetched) < 300 }
    }

    private nonisolated(unsafe) static var memoizedMetadata: [String: CachedMetadata] = .init()

    static func metadata(for game: GOGGame, platform: Game.Platform) async throws -> Metadata {
        guard GOG.isSignedIn else { throw GOG.NotSignedInError() }

        let key = "\(game.id)|\(platformArgument(for: platform))"
        if let cached = memoizedMetadata[key], cached.isFresh { return cached.metadata }

        let process = try makeProcess(arguments: [
            "info", game.id,
            "--platform", platformArgument(for: platform),
            "--lang", await installLanguage(),
            "--with-dlcs"
        ])

        // Bounded, because someone is waiting on a sheet for this — and it answers from
        // manifests, so it has no business taking longer than a moment.
        guard let result = await process.runWrapped(timeout: .seconds(90)),
              process.terminationStatus == 0,
              let output = result.standardOutput?.data(using: .utf8) else {
            // gogdl exits 1 with "Game doesn't support content system api" for anything that
            // predates Galaxy, which is the common case rather than an anomaly.
            log.error("gogdl couldn't describe \(game.id, privacy: .public) for \(platform.description, privacy: .public)")
            throw MetadataUnavailableError()
        }

        guard let root = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let folderName = root["folder_name"] as? String else {
            throw MetadataUnavailableError()
        }

        var sizes: [String: Metadata.Size] = .init()
        for (language, value) in (root["size"] as? [String: [String: Any]] ?? .init()) {
            sizes[language] = .init(download: (value["download_size"] as? NSNumber)?.int64Value ?? 0,
                                    disk: (value["disk_size"] as? NSNumber)?.int64Value ?? 0)
        }

        // `buildId` is a string in the v2 content system and an integer in v1, and which one
        // answers depends on how old the game is rather than on anything the caller chose.
        let buildID: String? = (root["buildId"] as? String) ?? (root["buildId"] as? NSNumber)?.stringValue

        let metadata: Metadata = .init(sizes: sizes,
                                       folderName: folderName,
                                       buildID: buildID,
                                       versionName: root["versionName"] as? String,
                                       availableLanguages: root["languages"] as? [String] ?? .init())

        memoizedMetadata[key] = .init(metadata: metadata, fetched: .now)
        return metadata
    }

    // MARK: - Install records

    /// What was installed, so a later run knows whether it's still current.
    ///
    /// A `Game` subclass cannot add to what gets persisted — `Game.encode(to:)` is declared in
    /// an extension, so it can't be overridden — and `installationState` carries only a
    /// location and a platform. The build a game is sitting at has to live somewhere, and
    /// beside the account is where legendary keeps the same thing.
    struct InstallRecord: Codable {
        let buildID: String?
        let versionName: String?
        let folderName: String
        let platform: Game.Platform
        /// Optional because records written before this existed don't have it; those are
        /// reconstructed from the install base directory, which is where they'd have gone.
        var location: URL?
    }

    private static var installRecordsURL: URL { GOG.configurationFolder.appending(path: "installed.json") }

    private nonisolated(unsafe) static var memoizedInstallRecords: [String: InstallRecord]?

    private static func installRecords() -> [String: InstallRecord] {
        if let memoizedInstallRecords { return memoizedInstallRecords }

        let records = (try? Data(contentsOf: installRecordsURL))
            .flatMap { try? JSONDecoder().decode([String: InstallRecord].self, from: $0) } ?? .init()

        memoizedInstallRecords = records
        return records
    }

    static func installRecord(forGameID id: String) -> InstallRecord? { installRecords()[id] }

    /// Where a recorded install should be, whether or not the record says so outright.
    private static func recordedLocation(_ record: InstallRecord) -> URL? {
        record.location
            ?? UserDefaults.standard.url(forKey: "installBaseURL")?.appending(path: record.folderName)
    }

    /// Puts a game's installation state back in step with what's actually on disk.
    ///
    /// The library lives in `UserDefaults` and the files don't, so the two can disagree — a
    /// game deleted in Finder still reads as installed, and a library entry lost to a failed
    /// write orphans a download that's sitting right there. gogdl's own record is the third
    /// opinion that settles it, which is the same reason legendary keeps `installed.json`.
    ///
    /// - Returns: `true` if the game's state was changed.
    /// - Parameter probingExternalVolumes: Whether it may reach for paths that aren't on the
    ///   startup disk. False on the automatic refresh, because doing so is what makes macOS
    ///   put up "PorTalistic would like to access files on a removable volume" — and the app
    ///   was provoking that at every launch purely to find out whether games it was not
    ///   about to open were still on the drive. True when the user presses Force-refresh,
    ///   where they have asked for exactly this and the prompt is not a surprise.
    ///
    ///   Nothing is lost by waiting: whether a game's files are there is checked again when
    ///   it is launched, by ``GOGGameManager``, which refuses with an error that says so.
    @discardableResult
    @MainActor static func reconcileInstallationState(of game: GOGGame,
                                                      probingExternalVolumes: Bool = false) -> Bool {
        let record = installRecord(forGameID: game.id)
        let recordedURL = record.flatMap(recordedLocation)

        switch game.installationState {
        case .installed(let location, _):
            if location.isOnAnExternalVolume, !probingExternalVolumes { return false }

            guard !FileManager.default.fileExists(atPath: location.path) else { return false }

            // Not there *right now* is not the same as gone. Unplugging an external disk
            // takes every game on it out of reach at once, and this used to answer that by
            // marking them uninstalled *and deleting their install records* — so plugging
            // the disk back in could not undo it, because the recovery below has nothing
            // left to read. The record is the thing that has to survive.
            if location.isOnAnUnmountedVolume {
                log.notice("""
                    \(game.title, privacy: .public) is on a volume that isn't mounted;                     leaving it as installed
                    """)
                return false
            }

            log.notice("\(game.title, privacy: .public) is recorded as installed but isn't on disk; marking it uninstalled")
            game.installationState = .uninstalled
            forgetInstall(ofGameID: game.id)
            return true

        case .uninstalled:
            guard let record, let recordedURL else {
                return rediscoverInstall(of: game, probingExternalVolumes: probingExternalVolumes)
            }

            if recordedURL.isOnAnExternalVolume, !probingExternalVolumes { return false }
            guard FileManager.default.fileExists(atPath: recordedURL.path) else { return false }

            log.notice("Recovering \(game.title, privacy: .public) from its install record")
            game.installationState = .installed(location: recordedURL, platform: record.platform)
            return true
        }
    }

    /// Directories whose immediate children are worth checking for a forgotten install.
    ///
    /// Only places the app already knows games live: the configured install directory, and
    /// the parent of every location an install record names. Nothing is enumerated to find
    /// them.
    ///
    /// The first version of this walked every mounted volume and looked under `Games`,
    /// `GOG Games` and `GOG` on each. That found more, and cost more than it was worth:
    /// touching a removable volume is what makes macOS ask "PorTalistic would like to access
    /// files on a removable volume", so a routine library refresh could provoke that prompt
    /// about a disk with no games on it at all. A forgotten install is beside its siblings
    /// in practice, and its siblings are in this list.
    private static func searchBases() -> [URL] {
        var bases: [URL] = .init()

        if let configured = UserDefaults.standard.url(forKey: "installBaseURL") {
            bases.append(configured)
        }

        for record in installRecords().values {
            guard let location = recordedLocation(record) else { continue }
            bases.append(location.deletingLastPathComponent())
        }

        // The same directory reached two ways is the same directory.
        var seen: Set<String> = .init()
        return bases.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// Looks for a game's files where they were left, for a game whose record is gone.
    ///
    /// The install record is what normally proves a game is installed, and the bug above
    /// deleted it for every game on a disk that got unplugged. A GOG install identifies
    /// itself, though: each one carries a `goggame-<product id>.info` at its root, so the
    /// files can be recognised with no record, no network call and no guessing from the
    /// title. This is what brings those games back.
    ///
    /// - Returns: `true` if the game's state was changed.
    @discardableResult
    @MainActor static func rediscoverInstall(of game: GOGGame,
                                             probingExternalVolumes: Bool = false) -> Bool {
        let candidates = searchBases()
            .filter { probingExternalVolumes || !$0.isOnAnExternalVolume }
            .flatMap { base in
            (try? FileManager.default.contentsOfDirectory(at: base,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles])) ?? []
        }

        guard let location = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appending(path: "goggame-\(game.id).info").path)
        }) else { return false }

        // Read from the files rather than assumed: a macOS build is an app bundle where a
        // Windows one is a tree of executables, and the wrong answer here sends the game to
        // a runtime that can't start it.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: location.path)) ?? []
        let platform: Game.Platform = entries.contains { $0.hasSuffix(".app") } ? .macOS : .windows

        log.notice("""
            Found \(game.title, privacy: .public) at \(location.prettyPath, privacy: .public)             with no install record; putting it back
            """)

        // No build ID: nothing on disk says which one this is, and claiming one would make
        // the update check answer confidently about a version it never saw.
        setInstallRecord(.init(buildID: nil,
                               versionName: nil,
                               folderName: location.lastPathComponent,
                               platform: platform,
                               location: location),
                         forGameID: game.id)

        game.installationState = .installed(location: location, platform: platform)
        return true
    }

    private static func setInstallRecord(_ record: InstallRecord?, forGameID id: String) {
        var records = installRecords()
        records[id] = record
        memoizedInstallRecords = records

        do {
            try FileManager.default.createDirectory(at: GOG.configurationFolder, withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: installRecordsURL, options: [.atomic])
        } catch {
            // Losing this costs update detection until the next install, nothing more.
            log.warning("Couldn't record the GOG install for \(id, privacy: .public): \(error.localizedDescription)")
        }
    }

    // MARK: - Update availability

    /// Whether a newer build exists, as far as anything on disk can say.
    ///
    /// Answered from a memo rather than from the network, because the property asking it —
    /// `Game.isUpdateAvailable` — is synchronous and read while drawing a card. ``refreshUpdateAvailability(for:)``
    /// is what fills the memo.
    /// Read from anywhere — `Game.isUpdateAvailable` is a synchronous property with no
    /// isolation of its own — but only ever written on the main actor, which is what keeps a
    /// task group refreshing every installed game at once from racing on it.
    private nonisolated(unsafe) static var memoizedUpdateAvailability: [String: Bool] = .init()

    static func cachedUpdateAvailability(forGameID id: String) -> Bool? { memoizedUpdateAvailability[id] }

    /// Asks GOG for the game's latest build and compares it with what was installed.
    ///
    /// The content-system builds endpoint rather than `gogdl info`: `info` fetches and
    /// decompresses the whole depot manifest to answer, which is a lot of work to learn a
    /// single identifier, and this runs for every installed game on a refresh.
    @discardableResult
    @MainActor static func refreshUpdateAvailability(for game: GOGGame) async -> Bool? {
        guard case .installed = game.installationState,
              let record = installRecord(forGameID: game.id),
              let installedBuildID = record.buildID else { return nil }

        var components: URLComponents = .init(
            string: "https://content-system.gog.com/products/\(game.id)/os/\(platformArgument(for: record.platform))/builds"
        )!
        components.queryItems = [.init(name: "generation", value: "2")]

        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return nil }

        // The first item without a branch is the public build, which is what was installed:
        // a branch is an opt-in beta, and offering one as "an update" would move the player
        // onto it without asking.
        let latest = items.first(where: { $0["branch"] is NSNull || $0["branch"] == nil }) ?? items.first
        guard let latestBuildID = (latest?["build_id"] as? String) ?? (latest?["legacy_build_id"] as? NSNumber)?.stringValue else {
            return nil
        }

        let isAvailable = latestBuildID != installedBuildID
        memoizedUpdateAvailability[game.id] = isAvailable
        return isAvailable
    }

    // MARK: - Play tasks

    /// How a GOG install says it should be started.
    ///
    /// Every GOG game ships a `goggame-<id>.info` file describing its own play tasks — the
    /// executable, its working directory, its arguments — which is how Galaxy knows what to
    /// run without being told. Read here rather than through `gogdl launch`, because that
    /// command wants to pick a Wine build and spawn the process itself, and Mythic already has
    /// opinions about both.
    struct PlayTask {
        let path: String
        let workingDirectory: String?
        let arguments: [String]
        let isPrimary: Bool
        let isHidden: Bool
        let name: String?
    }

    /// Where the `.info` file lives, which differs by platform: a macOS build is an app
    /// bundle and keeps it in `Contents/Resources`.
    private static func gameInfoURL(forGameAt location: URL, id: String, platform: Game.Platform) -> URL? {
        let searchDirectory: URL = switch platform {
        case .macOS: location.appending(path: "Contents/Resources")
        case .windows: location
        }

        let exact = searchDirectory.appending(path: "goggame-\(id).info")
        if FileManager.default.fileExists(atPath: exact.path) { return exact }

        // DLC ships its own `.info` beside the base game's, so a glob can't just take the
        // first hit — but when the id doesn't match a file (a game installed under a different
        // root id), the one that names itself as the root is the right one.
        guard let contents = try? FileManager.default.contentsOfDirectory(at: searchDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }

        return contents
            .filter { $0.lastPathComponent.hasPrefix("goggame-") && $0.pathExtension == "info" }
            .first { url in
                guard let data = try? Data(contentsOf: url),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }

                return (root["gameId"] as? String) == (root["rootGameId"] as? String)
            }
    }

    static func playTasks(forGameAt location: URL, id: String, platform: Game.Platform) -> [PlayTask] {
        guard let infoURL = gameInfoURL(forGameAt: location, id: id, platform: platform),
              let data = try? Data(contentsOf: infoURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = root["playTasks"] as? [[String: Any]] else { return .init() }

        return tasks.compactMap { task in
            // A URLTask is a link to a manual or a support page, not something to run.
            guard (task["type"] as? String) != "URLTask", let path = task["path"] as? String else { return nil }

            // `arguments` is a single command line as often as it is a list, because it comes
            // from whatever the game's own installer wrote.
            let arguments: [String] = switch task["arguments"] {
            case let list as [String]: list
            case let line as String: line.replacingOccurrences(of: "\\", with: "/").split(separator: " ").map(String.init)
            default: .init()
            }

            return .init(path: path,
                         workingDirectory: task["workingDir"] as? String,
                         arguments: arguments,
                         isPrimary: task["isPrimary"] as? Bool ?? false,
                         isHidden: task["isHidden"] as? Bool ?? false,
                         name: task["name"] as? String)
        }
    }

    /// What to run, resolved against the install directory.
    ///
    /// Paths in a `.info` file are Windows-relative — backslashes and all — so they are
    /// translated here rather than handed to anything that would take them literally.
    static func primaryLaunchTarget(forGameAt location: URL,
                                    id: String,
                                    platform: Game.Platform) -> (executable: URL, workingDirectory: URL, arguments: [String])? {
        let tasks = playTasks(forGameAt: location, id: id, platform: platform)
        guard let task = tasks.first(where: { $0.isPrimary && !$0.isHidden })
                ?? tasks.first(where: { !$0.isHidden })
                ?? tasks.first else { return nil }

        func resolve(_ relative: String) -> URL {
            location.appending(path: relative.replacingOccurrences(of: "\\", with: "/"))
        }

        return (executable: resolve(task.path),
                workingDirectory: task.workingDirectory.map(resolve) ?? location,
                arguments: task.arguments)
    }

    // MARK: - Progress

    /// Turns gogdl's periodic status lines into a `Progress` the rest of Mythic understands.
    ///
    /// Sample, as logged (to standard error, like legendary's):
    ///
    ///     [PROGRESS] INFO: = Progress: 47.28 261/552, Running for: 00:00:14, ETA: 00:00:15
    ///     [PROGRESS] INFO: = Downloaded: 93.43 MiB, Written: 215.42 MiB
    ///     [PROGRESS] INFO:  + Download	- 7.99 MiB/s (raw) / 17.00 MiB/s (decompressed)
    ///
    /// Close to legendary's, but not the same: no `%` after the percentage, a colon after
    /// "Running for", and the counts are bytes rather than objects. Parsed separately rather
    /// than by loosening legendary's pattern until it matches both, because a regex that
    /// matches two formats silently matches a third one wrongly.
    private static func updateProgress(_ progress: Progress, from output: String) {
        // Not dynamic, so there's no reason for these to fail to compile.
        // swiftlint:disable force_try
        let progressRegex: Regex = try! .init(
            #"Progress: (?<percentage>[\d.]+) (?<written>\d+)\/(?<total>\d+), Running for: (?<runtime>\d+:\d+:\d+), ETA: (?<eta>\d+:\d+:\d+)"#
        )
        let speedRegex: Regex = try! .init(
            #"\+ Download\s+- (?<raw>[\d.]+) \w+\/\w+ \(raw\)"#
        )
        // swiftlint:enable force_try

        if let match = try? progressRegex.firstMatch(in: output) {
            // `totalUnitCount` is set to 100 by the caller, matching how Epic reports.
            progress.completedUnitCount = Int64(Double(match["percentage"]?.substring ?? .init())?.rounded() ?? 0)
            progress.estimatedTimeRemaining = TimeInterval(HH_MM_SSString: String(match["eta"]?.substring ?? .init()))
        }

        if let match = try? speedRegex.firstMatch(in: output),
           let rawMiBPerSecond = Double(match["raw"]?.substring ?? .init()) {
            progress.throughput = Int(rawMiBPerSecond * pow(1024, 2))
        }
    }

    // MARK: - Operations

    /// Downloads a game.
    ///
    /// - Note: `download` is the only one of gogdl's three download commands that appends the
    ///   game's own folder name to `--path`, so this is handed the *base* directory while
    ///   ``update(game:qualityOfService:)`` and ``repair(game:qualityOfService:)`` are handed
    ///   the game's directory. Getting that backwards nests a second copy of the folder.
    @discardableResult
    @MainActor static func install(game: GOGGame,
                                   platform: Game.Platform,
                                   qualityOfService: QualityOfService = .default,
                                   baseDirectoryURL: URL? = UserDefaults.standard.url(forKey: "installBaseURL")) async throws -> GameOperation {
        if let supported = game.getSupportedPlatforms(), !supported.contains(platform) {
            throw UnsupportedPlatformError(title: game.title, platform: platform)
        }

        guard let baseDirectoryURL else {
            log.error("No install base directory is set; installation cannot continue")
            throw CocoaError(.fileReadUnknown)
        }

        // Everything that can be checked instantly is checked here; asking GOG what the
        // download involves happens *inside* the operation. It takes a minute or two for a
        // game with DLC — every depot manifest has to be fetched and decompressed to answer —
        // and a sheet that sits on a spinner for that long reads as broken, while a queued
        // operation that says "Installing" reads as exactly what it is.
        let operation = makeInstallOperation(game: game, platform: platform, baseDirectoryURL: baseDirectoryURL)

        operation.qualityOfService = qualityOfService
        Game.operationManager.queueOperation(operation)
        return operation
    }

    private nonisolated static func makeInstallOperation(game: GOGGame,
                                                         platform: Game.Platform,
                                                         baseDirectoryURL: URL) -> GameOperation {
        makeOperation(game: game, type: .install) { progress in
            let gameMetadata = try await metadata(for: game, platform: platform)

            // gogdl appends the game's own folder name to `--path` for `download` (and only
            // for `download`), so it is handed the base directory and this is where it lands.
            let destination = baseDirectoryURL.appending(path: gameMetadata.folderName)

            try await runGOGDL(arguments: [
                "download", game.id,
                "--platform", platformArgument(for: platform),
                "--path", baseDirectoryURL.path,
                "--lang", await installLanguage(),
                "--with-dlcs"
            ], reporting: progress)

            await MainActor.run {
                game.installationState = .installed(location: destination, platform: platform)
                setInstallRecord(.init(buildID: gameMetadata.buildID,
                                       versionName: gameMetadata.versionName,
                                       folderName: gameMetadata.folderName,
                                       platform: platform,
                                       location: destination),
                                 forGameID: game.id)
                memoizedUpdateAvailability[game.id] = false

                // Mutating the game isn't enough to save it: the library persists itself from
                // its own `didSet`, and changing an object already inside the set doesn't fire
                // that. Without this the game shows as installed only until the app restarts.
                GameDataStore.shared.library.update(with: game)
            }
        }
    }

    /// Brings an installed game up to the latest build.
    @discardableResult
    @MainActor static func update(game: GOGGame,
                                  qualityOfService: QualityOfService = .default) async throws -> GameOperation {
        guard case .installed(let location, let platform) = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let operation = makeOperation(game: game, type: .update) { progress in
            let gameMetadata = try await metadata(for: game, platform: platform)

            // `update` and `repair`, unlike `download`, take the game's own directory rather
            // than the one above it: only `download` appends the folder name itself.
            try await runGOGDL(arguments: [
                "update", game.id,
                "--platform", platformArgument(for: platform),
                "--path", location.path,
                "--lang", await installLanguage(),
                "--with-dlcs"
            ], reporting: progress)

            await MainActor.run {
                setInstallRecord(.init(buildID: gameMetadata.buildID,
                                       versionName: gameMetadata.versionName,
                                       folderName: gameMetadata.folderName,
                                       platform: platform,
                                       location: location),
                                 forGameID: game.id)
                memoizedUpdateAvailability[game.id] = false
                GameDataStore.shared.library.update(with: game)
            }
        }

        operation.qualityOfService = qualityOfService
        Game.operationManager.queueOperation(operation)
        return operation
    }

    /// Re-checks every file against the manifest and refetches whatever doesn't match.
    @discardableResult
    @MainActor static func repair(game: GOGGame,
                                  qualityOfService: QualityOfService = .default) async throws -> GameOperation {
        guard case .installed(let location, let platform) = game.installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        let operation = makeOperation(game: game, type: .repair) { progress in
            try await runGOGDL(arguments: [
                "repair", game.id,
                "--platform", platformArgument(for: platform),
                "--path", location.path,
                "--lang", await installLanguage(),
                "--with-dlcs"
            ], reporting: progress)
        }

        operation.qualityOfService = qualityOfService
        Game.operationManager.queueOperation(operation)
        return operation
    }

    /// Wraps a body in an operation, outside the main actor deliberately.
    ///
    /// A closure that isn't `@Sendable` inherits the isolation of wherever it was written, and
    /// `GameOperation`'s is neither — so building one inside a `@MainActor` method would pin
    /// an hour-long download to the main actor. Nothing in these bodies wants to be there.
    private nonisolated static func makeOperation(game: GOGGame,
                                                  type: GameOperation.ActiveOperationType,
                                                  body: @escaping (Progress) async throws -> Void) -> GameOperation {
        .init(game: game, type: type) { progress in
            progress.totalUnitCount = 100
            progress.fileOperationKind = .downloading
            try await body(progress)
        }
    }

    /// Runs gogdl to completion, reporting as it goes, and refuses to call a failure a success.
    private nonisolated static func runGOGDL(arguments: [String], reporting progress: Progress) async throws {
        let process = try makeProcess(arguments: arguments)

        try await withTaskCancellationHandler {
            try await process.runStreamed(throwsOnChunkError: false) { chunk in
                if case .standardError = chunk.stream {
                    updateProgress(progress, from: chunk.output)
                }

                return nil
            }
        } onCancel: {
            // Interrupt rather than terminate: gogdl writes out what it has finished, and a
            // download killed outright starts again from nothing.
            process.interrupt()
        }

        try Task.checkCancellation()

        guard process.terminationStatus == 0 else {
            throw OperationFailedError(terminationStatus: process.terminationStatus)
        }
    }

    /// Forgets that a game was ever installed. Removing files is the caller's business.
    @MainActor static func forgetInstall(ofGameID id: String) {
        setInstallRecord(nil, forGameID: id)
        memoizedUpdateAvailability[id] = nil
    }
}
