//
//  SteamInterface.swift
//  Mythic
//
//  Created by Claude (Cowork) on 4/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 Controls Mythic's Steam integration.

 Unlike Epic Games (where Mythic reimplements the storefront protocol via `Legendary`),
 Steam support works by managing a single, dedicated Wine container that runs the real,
 official Windows Steam client. This means:

 - Login, 2FA, cloud saves, the overlay, achievements, and Steam's own update/download
   manager all work exactly as they do on Windows, because it *is* Steam, not a
   reimplementation of it.
 - Mythic's job is narrower and more reliable as a result: create a sane container,
   install the real client into it, and read Steam's own on-disk state
   (`libraryfolders.vdf` / `appmanifest_*.acf`) to know what's installed so those games
   can appear in Mythic's library and be launched with one click.
 - New game installs/updates happen inside the real Steam client (opened via
   ``openClient()``); Mythic does not attempt to reimplement Steam's download manager.
   This is a deliberate reliability trade-off: automating that step over a GUI installer
   is fragile, whereas reading Steam's own manifests after the fact is not.
 */
final class Steam {
    static let log: Logger = .custom(category: "SteamInterface")

    /// The fixed name given to Mythic's dedicated Steam container.
    /// Only one is ever created — Steam does not benefit from per-game containers
    /// the way arbitrary Windows games do, since it manages its own game folders.
    static let containerName = "Steam"

    // MARK: - Container

    /// The URL of Mythic's dedicated Steam container, if one has been created.
    static var containerURL: URL? {
        Wine.containerObjects.first(where: { $0.name == containerName })?.url
    }

    /// Default settings used when creating the Steam container.
    /// DXVK + msync + AVX2 mirror what Mythic already recommends for demanding
    /// Windows games; Windows 10 is used because Steam's installer and self-updater
    /// are more conservative about the Windows version they expect than most games are.
    static var recommendedContainerSettings: Wine.Container.Settings {
        .init(metalHUD: false,
              msync: true,
              retinaMode: true,
              dxvk: true,
              dxvkAsync: true,
              windowsVersion: .win10,
              scaling: 192,
              avx2: true)
    }

    /// Creates the Steam container if it doesn't already exist, or returns the existing one.
    @discardableResult
    static func ensureContainer() async throws -> Wine.Container {
        if let containerURL, let existing = try? Wine.getContainerObject(at: containerURL) {
            return existing
        }

        return try await Wine.createContainer(name: containerName, settings: recommendedContainerSettings)
    }

    // MARK: - Client detection & installation

    /// Where `steam.exe` lives inside the container, once installed.
    static func steamExecutableURL(containerURL: URL) -> URL {
        containerURL.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
    }

    /// Whether the real Windows Steam client has been installed into the container.
    static var isClientInstalled: Bool {
        guard let containerURL else { return false }
        return FileManager.default.fileExists(atPath: steamExecutableURL(containerURL: containerURL).path)
    }

    static let installerDownloadURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!

    struct ClientInstallationFailedError: LocalizedError {
        var errorDescription: String? = String(localized: "Steam's installer didn't finish successfully. Try running Set Up Steam again.")
    }

    /// Downloads the official Steam installer and runs it, silently, inside Mythic's Steam container.
    /// - Parameter onProgress: Called with a 0...1 fraction while downloading. Installation itself
    ///   (after download) is fast but not progress-reporting, since it's a black-box NSIS installer.
    @discardableResult
    static func installClient(onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Wine.Container {
        try await Preflight.requireEngineAndRosetta()
        let container = try await ensureContainer()

        let downloadedInstaller = try await downloadInstaller(onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: downloadedInstaller) }

        let process: Process = .init()
        // NSIS silent-install flag — installs to Steam's normal default location
        // (`C:\Program Files (x86)\Steam`) inside this container without showing UI.
        process.arguments = [downloadedInstaller.path, "/S"]
        Wine.transformProcess(process, containerURL: container.url)

        let result = try await process.runWrapped()
        log.notice("Steam installer finished for container \(container.url.prettyPath). stderr: \(result.standardError ?? "none")")

        // The installer's own bootstrapping can briefly relaunch/exit; give the
        // filesystem a moment before checking, then verify unconditionally.
        try await Task.sleep(for: .seconds(2))
        guard isClientInstalled else { throw ClientInstallationFailedError() }

        try await ensureClientRegistryConfiguration(containerURL: container.url)

        return container
    }

    /// Holds the progress observation by reference, so it stays alive for the whole
    /// download without the completion handler having to capture a mutable local.
    private final class ObservationBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
        func invalidate() { observation?.invalidate(); observation = nil }
    }

    private static func downloadInstaller(onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let progressObservation = ObservationBox()

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: installerDownloadURL) { location, response, error in
                progressObservation.invalidate()

                if let error { continuation.resume(throwing: error); return }
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                guard let location else { continuation.resume(throwing: CocoaError(.fileNoSuchFile)); return }

                // `location` is a temp file that URLSession will delete after this closure returns —
                // move it somewhere stable first.
                let destination = FileManager.default.temporaryDirectory.appending(path: "SteamSetup-\(UUID().uuidString).exe")
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            progressObservation.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { _, change in
                if let newValue = change.newValue { onProgress(newValue) }
            }

            task.resume()
        }
    }

    /// Launch arguments Mythic always passes to the real Steam client.
    ///
    /// Steam's bootstrapper is *the* failure point when running the Windows client under
    /// Wine. Left to itself it tries to self-update on every launch, fails partway through,
    /// and dies with "Steam needs to be online to update. Please confirm your network
    /// connection and try again" — even when the network is perfectly fine. The client is
    /// already fully installed at that point; it just refuses to start.
    ///
    /// These flags stop it doing that, and are the long-standing workaround the Wine
    /// community (Lutris, Bottles, Proton) settled on for the same bug:
    ///
    /// - `-no-cef-sandbox`: Steam's Chromium UI can't run its sandbox under Wine.
    /// - `-noverifyfiles`: skip the file-verification pass that kicks off the update loop.
    /// - `-nobootstrapupdate`: don't try to replace the bootstrapper itself.
    /// - `-skipinitialbootstrap`: don't run the initial bootstrap at all.
    /// - `-norepairfiles`: don't "repair" (re-download) a install that isn't broken.
    ///
    /// - Note: These suppress Steam's *self*-update. Game downloads, updates, login, cloud
    ///   saves and the rest are untouched and still work normally.
    /// Whether the client is not merely installed but *complete* — the bootstrapper has
    /// unpacked the real client, not just laid down `steam.exe`.
    ///
    /// `steamui.dll` is the useful signal: it only exists once the downloaded packages have
    /// been extracted, and it's the file Steam names when it can't start.
    static var isClientFullyInstalled: Bool {
        guard let containerURL else { return false }
        let steamRoot = containerURL.appending(path: "drive_c/Program Files (x86)/Steam")
        return FileManager.default.fileExists(atPath: steamRoot.appending(path: "steamui.dll").path)
    }

    /// Launch arguments for the real Steam client.
    ///
    /// Whether it's right to suppress Steam's self-update depends entirely on whether the
    /// client is already complete, and getting this backwards fails either way:
    ///
    /// - On a **fresh** container, Steam's installer lays down only the bootstrapper.
    ///   `steamui.dll` and everything else arrive on first run. Suppressing the update there
    ///   suppresses the very download the client needs, and it dies with
    ///   "Failed to load steamui.dll".
    /// - On a **complete** install, the update check is the thing that breaks it: a
    ///   manifest fetch that times out leaves a perfectly working client refusing to start
    ///   with "Steam needs to be online to update", even though nothing needs updating.
    ///
    /// So: bootstrap freely when incomplete, and stop letting a failed update check block a
    /// client that's already good. Steam still updates itself whenever the check succeeds.
    static var clientLaunchArguments: [String] {
        // Steam's Chromium UI can't run its sandbox under Wine; always needed.
        ["-no-cef-sandbox"]
    }

    /// Turns Steam's own bootstrapper self-update on or off via `steam.cfg`.
    ///
    /// Command-line flags don't reliably reach the bootstrapper — it relaunches itself with
    /// its own arguments, discarding ours. `steam.cfg`, which it reads from its install
    /// directory on every start, is the mechanism that actually holds.
    ///
    /// This matters because a *complete* client still refuses to start when its update
    /// check fails: it can't reach `client-update.steamstatic.com` from inside the
    /// container, times out after two minutes, and reports "Steam needs to be online to
    /// update" — with nothing actually needing updating.
    ///
    /// - Parameter inhibited: `true` to stop the bootstrapper self-updating.
    /// - Note: While inhibited the Steam *client* won't update itself. Game downloads,
    ///   updates and everything else are unaffected. ``updateClient()`` lifts it deliberately.
    static func setBootstrapperUpdateInhibited(_ inhibited: Bool, containerURL: URL) throws {
        let configURL = containerURL
            .appending(path: "drive_c/Program Files (x86)/Steam/steam.cfg")

        guard inhibited else {
            try? FileManager.default.removeItem(at: configURL)
            return
        }

        let contents = """
        BootStrapperInhibitAll=enable
        BootStrapperForceSelfUpdate=disable

        """
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        log.notice("Steam bootstrapper self-update inhibited via steam.cfg")
    }

    /// Lets the client update itself once, by lifting the inhibit and launching.
    /// Use this when the user explicitly asks for a Steam client update.
    static func updateClient() async throws -> Process {
        let container = try await ensureContainer()
        try setBootstrapperUpdateInhibited(false, containerURL: container.url)
        return try await openClient()
    }

    /// Where the Steam client's console output is captured.
    static func clientOutputLogURL(containerURL: URL) -> URL {
        containerURL.appending(path: "steam-client-output.log")
    }

    /// Windows-side path of the Steam install, in the lowercase forward-slash form Steam
    /// itself writes to the registry.
    private static let windowsSteamPath = "c:/program files (x86)/steam"

    /// Makes sure `HKCU\\Software\\Valve\\Steam` names where Steam lives.
    ///
    /// The NSIS installer only writes `InstallPath` under
    /// `HKLM\\Software\\Wow6432Node\\Valve\\Steam`. On real Windows the client fills in the
    /// per-user `SteamPath`/`SteamExe` values itself on first run; in a fresh Wine container
    /// it doesn't get that far — it downloads every package, fails to resolve where to
    /// unpack them ("Failed to determine download location for universe 1"), and shuts down
    /// leaving the install with no `steamui.dll`. Writing the values up front breaks that
    /// deadlock.
    ///
    /// Idempotent, and cheap enough to run before every launch.
    static func ensureClientRegistryConfiguration(containerURL: URL) async throws {
        let values: [(key: String, name: String, value: String)] = [
            ("HKCU\\Software\\Valve\\Steam", "SteamPath", windowsSteamPath),
            ("HKCU\\Software\\Valve\\Steam", "SteamExe", "\(windowsSteamPath)/steam.exe"),
            ("HKCU\\Software\\Valve\\Steam", "ModInstallPath", "\(windowsSteamPath)/steamapps/sourcemods"),
            ("HKCU\\Software\\Valve\\Steam", "SourceModInstallPath", "\(windowsSteamPath)/steamapps/sourcemods")
        ]

        for entry in values {
            let process: Process = .init()
            process.arguments = ["reg", "add", entry.key, "/v", entry.name, "/t", "REG_SZ", "/d", entry.value, "/f"]
            Wine.transformProcess(process, containerURL: containerURL)

            let result = try await process.runWrapped()
            log.debug("reg add \(entry.name, privacy: .public): \(result.standardError ?? "ok", privacy: .public)")
        }

        // Steam expects this to exist; it won't create it before resolving a download location.
        let steamApps = containerURL.appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
        try? FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
    }

    /// Opens the real Steam client's window (installing/launching the container's copy if needed).
    /// This is the entry point for a user to sign in, browse the store, and install/update games —
    /// Mythic deliberately doesn't try to automate that part.
    @discardableResult
    static func openClient() async throws -> Process {
        try await Preflight.requireEngineAndRosetta()
        let container = try await ensureContainer()
        guard isClientInstalled else { throw NotInstalledError() }

        try await ensureClientRegistryConfiguration(containerURL: container.url)

        // Only once the client is complete. On an incomplete install the bootstrapper is
        // exactly what we need to run, so inhibiting it there would strand the container
        // without `steamui.dll`.
        try? setBootstrapperUpdateInhibited(isClientFullyInstalled, containerURL: container.url)

        let process: Process = .init()
        process.arguments = [steamExecutableURL(containerURL: container.url).path] + clientLaunchArguments
        process.environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: container.url)
        Wine.transformProcess(process, containerURL: container.url)

        // Capture the client's console output to a file rather than discarding it.
        // When Steam fails before it can write its own logs — which is most of the
        // interesting cases — this is the only account of what happened.
        // Deliberately a file rather than a Pipe: a pipe nobody drains fills its buffer and
        // blocks the very process we're trying to observe.
        let outputURL = clientOutputLogURL(containerURL: container.url)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: outputURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        try process.run()
        return process
    }

    struct NotInstalledError: LocalizedError {
        var errorDescription: String? = String(localized: "The Steam client hasn't been installed into Mythic's Steam container yet. Use Set Up Steam first.")
    }

    // MARK: - Library scanning

    struct InstalledApp: Equatable {
        let appID: String
        let name: String
        let installDirectory: URL
        /// Steam's own `StateFlags` bitmask; bit `4` (`0x4`) means "fully installed".
        let stateFlags: Int
        var isFullyInstalled: Bool { stateFlags & 0x4 != 0 }
    }

    struct LibraryScanError: LocalizedError {
        var errorDescription: String? = String(localized: "Couldn't read Steam's library data. Make sure Steam has been set up and you've signed in at least once.")
    }

    /// Reads `libraryfolders.vdf` to find every Steam library folder (the default one, plus any
    /// additional drives/folders the user added from within Steam), mapped to their location
    /// inside the container's `drive_c`.
    static func libraryFolders() throws -> [URL] {
        guard let containerURL else { throw LibraryScanError() }
        let steamRoot = containerURL.appending(path: "drive_c/Program Files (x86)/Steam")
        var folders: [URL] = [steamRoot] // the default library is Steam's own install folder

        let manifestURL = steamRoot.appending(path: "steamapps/libraryfolders.vdf")
        guard let contents = try? String(contentsOf: manifestURL, encoding: .utf8),
              let (_, root) = try? VDF.parse(contents),
              case .object(let libraries) = root else {
            return folders
        }

        for (_, entry) in libraries {
            guard let path = entry["path"]?.stringValue else { continue }
            folders.append(windowsPath(path, relativeToContainer: containerURL))
        }

        // de-duplicate while preserving order
        var seen: Set<URL> = []
        return folders.filter { seen.insert($0.standardizedFileURL).inserted }
    }

    /// Converts a Windows-style path as Steam wrote it (e.g. `C:\Program Files (x86)\Steam`)
    /// into the corresponding path under the container's `drive_c`.
    /// - Note: `VDF.parse` has already resolved `\\` escape sequences down to single
    ///   backslashes by this point, so this only has ordinary Windows separators to handle.
    private static func windowsPath(_ path: String, relativeToContainer containerURL: URL) -> URL {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.count >= 2, normalized[normalized.index(normalized.startIndex, offsetBy: 1)] == ":" {
            normalized = String(normalized.dropFirst(2)) // strip the drive letter, e.g. "C:"
        }

        // Append component-by-component rather than the raw (possibly leading-"/") string,
        // so this can't be misread as resetting to the filesystem root.
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        return components.reduce(containerURL.appending(path: "drive_c")) { url, component in
            url.appending(path: String(component))
        }
    }

    /// Scans every known library folder for `appmanifest_*.acf` files and parses them.
    static func installedApps() throws -> [InstalledApp] {
        var apps: [InstalledApp] = []

        for folder in try libraryFolders() {
            let steamappsURL = folder.appending(path: "steamapps")
            guard let entries = try? FileManager.default.contentsOfDirectory(at: steamappsURL,
                                                                              includingPropertiesForKeys: nil) else { continue }

            for entry in entries where entry.lastPathComponent.hasPrefix("appmanifest_") && entry.pathExtension == "acf" {
                guard let contents = try? String(contentsOf: entry, encoding: .utf8),
                      let (_, root) = try? VDF.parse(contents),
                      let appID = root["appid"]?.stringValue,
                      let name = root["name"]?.stringValue,
                      let installDir = root["installdir"]?.stringValue else { continue }

                let stateFlags = Int(root["StateFlags"]?.stringValue ?? "0") ?? 0
                let installationURL = steamappsURL.appending(path: "common").appending(path: installDir)

                apps.append(.init(appID: appID, name: name, installDirectory: installationURL, stateFlags: stateFlags))
            }
        }

        return apps
    }

    /// Scans Steam's own installed-app state and returns `SteamGame` instances ready to merge
    /// into `GameDataStore`'s library, matching the shape `GameDataStore.refreshFromStorefronts()`
    /// already expects from other storefronts.
    @MainActor
    static func importInstalledGames() async throws -> [SteamGame] {
        guard let containerURL else { throw NotInstalledError() }

        return try installedApps()
            .filter(\.isFullyInstalled)
            .map { app in
                SteamGame(appID: app.appID,
                          title: app.name,
                          installationState: .installed(location: app.installDirectory, platform: .windows),
                          containerURL: containerURL)
            }
    }

    // MARK: - Diagnostics

    /// Collects everything needed to work out why the Steam client isn't behaving, and
    /// writes it somewhere readable.
    ///
    /// Steam failures inside a Wine container are close to undebuggable from the UI alone —
    /// the client shows a one-line fatal error and exits, while the actual explanation sits
    /// in its own logs inside the container. This gathers those logs plus the state of the
    /// install (which DLLs actually landed, and how big they are) into one folder.
    ///
    /// - Returns: The directory the report was written to.
    @discardableResult
    static func exportDiagnostics() async throws -> URL {
        guard let containerURL else { throw NotInstalledError() }

        let steamRoot = containerURL.appending(path: "drive_c/Program Files (x86)/Steam")
        let fileManager: FileManager = .default

        // FIXME: temporary location. This should offer a save panel once the app has a
        // proper diagnostics/support flow.
        let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let destination = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Games/Mythic-Diagnostics/steam-\(timestamp)")
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var summary: [String] = []
        func line(_ text: String = "") { summary.append(text) }

        func describe(_ url: URL) -> String {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                return "MISSING"
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date).map(ISO8601DateFormatter().string(from:)) ?? "?"
            return "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))  (modified \(modified))"
        }

        line("# Steam container diagnostics")
        line("generated: \(Date.now)")
        line("container: \(containerURL.path)")
        line("steam root: \(steamRoot.path)")
        line("engine installed: \(Engine.isInstalled)")
        line("engine version: \(await Engine.installedVersion?.description ?? "unknown")")
        line("wine version: \(Wine.retrieveVersion()?.description ?? "unknown")")
        line("rosetta present: \(Rosetta.exists)")
        line("client considered installed: \(isClientInstalled)")
        line("launch arguments: \(clientLaunchArguments.joined(separator: " "))")
        line()

        line("## key files")
        for relativePath in [
            "steam.exe",
            "steamui.dll",
            "steamclient.dll",
            "steamclient64.dll",
            "steamwebhelper.exe",
            "bin/cef/cef.win7/steamwebhelper.exe",
            "bin/cef/cef.win7x64/steamwebhelper.exe",
            "tier0_s.dll",
            "vstdlib_s.dll",
            "crashhandler.dll"
        ] {
            line("\(relativePath): \(describe(steamRoot.appending(path: relativePath)))")
        }
        line()

        func listing(of directory: URL, title: String, limit: Int = 250) {
            line("## \(title)")
            guard let contents = try? fileManager.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: [.fileSizeKey],
                                                                     options: [.skipsHiddenFiles]) else {
                line("(unreadable or absent: \(directory.path))")
                line()
                return
            }
            for entry in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(limit) {
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                line("\(entry.lastPathComponent)  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
            }
            if contents.count > limit { line("... and \(contents.count - limit) more") }
            line()
        }

        listing(of: steamRoot, title: "steam root")
        listing(of: steamRoot.appending(path: "package"), title: "package")
        listing(of: steamRoot.appending(path: "bin"), title: "bin")
        listing(of: steamRoot.appending(path: "logs"), title: "logs")

        try summary.joined(separator: "\n").write(to: destination.appending(path: "summary.txt"),
                                                  atomically: true,
                                                  encoding: .utf8)

        // Copy Steam's own logs verbatim — the real explanation usually lives here.
        let logsDirectory = steamRoot.appending(path: "logs")
        if let logs = try? fileManager.contentsOfDirectory(at: logsDirectory,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) {
            let logsDestination = destination.appending(path: "logs")
            try? fileManager.createDirectory(at: logsDestination, withIntermediateDirectories: true)
            for log in logs {
                try? fileManager.copyItem(at: log, to: logsDestination.appending(path: log.lastPathComponent))
            }
        }

        // ...as does the bootstrapper's own log, which sits at the Steam root.
        for name in ["bootstrap_log.txt", "GameOverlayRenderer.log", "steamapps/libraryfolders.vdf", "bin/service_log.txt"] {
            let source = steamRoot.appending(path: name)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.copyItem(at: source,
                                          to: destination.appending(path: source.lastPathComponent))
            }
        }

        // The client's captured console output, if a launch has been attempted.
        let clientOutput = clientOutputLogURL(containerURL: containerURL)
        if fileManager.fileExists(atPath: clientOutput.path) {
            try? fileManager.copyItem(at: clientOutput,
                                      to: destination.appending(path: clientOutput.lastPathComponent))
        }

        // Wine's registry hives are plain text. Steam resolves its own install location
        // through `Software\\Valve\\Steam`, so when it reports that it can't determine a
        // download location these are the first thing to check.
        for hive in ["system.reg", "user.reg", "userdef.reg"] {
            let source = containerURL.appending(path: hive)
            guard let contents = try? String(contentsOf: source, encoding: .utf8) else { continue }

            // The hives are large and full of unrelated keys; keep the Valve/Steam blocks
            // and a little context around them.
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            var extracted: [String] = []
            for (index, line) in lines.enumerated() where line.range(of: "Valve", options: .caseInsensitive) != nil {
                let start = max(0, index - 1)
                let end = min(lines.count - 1, index + 12)
                extracted.append(contentsOf: lines[start...end].map(String.init))
                extracted.append("---")
            }

            let output = extracted.isEmpty ? "(no Valve/Steam keys found in \(hive))" : extracted.joined(separator: "\n")
            try? output.write(to: destination.appending(path: "\(hive).valve.txt"),
                              atomically: true,
                              encoding: .utf8)
        }

        log.notice("Steam diagnostics written to \(destination.path, privacy: .public)")
        return destination
    }

    // MARK: - Header art

    /// Steam's CDN serves consistent, predictable artwork URLs keyed only by AppID —
    /// no API key or authentication required for these.
    enum ArtworkKind {
        case library600x900 // vertical/portrait — matches Mythic's `verticalImageURL`
        case libraryHero     // wide banner — matches Mythic's `horizontalImageURL`

        fileprivate var filename: String {
            switch self {
            case .library600x900: "library_600x900.jpg"
            case .libraryHero:     "library_hero.jpg"
            }
        }
    }

    static func artworkURL(appID: String, kind: ArtworkKind) -> URL {
        URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appID)/\(kind.filename)")!
    }
}
