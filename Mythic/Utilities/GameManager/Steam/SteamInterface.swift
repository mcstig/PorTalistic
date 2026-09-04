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

    /// Opens the real Steam client's window (installing/launching the container's copy if needed).
    /// This is the entry point for a user to sign in, browse the store, and install/update games —
    /// Mythic deliberately doesn't try to automate that part.
    @discardableResult
    static func openClient() async throws -> Process {
        try await Preflight.requireEngineAndRosetta()
        let container = try await ensureContainer()
        guard isClientInstalled else { throw NotInstalledError() }

        let process: Process = .init()
        process.arguments = [steamExecutableURL(containerURL: container.url).path]
        process.environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: container.url)
        Wine.transformProcess(process, containerURL: container.url)
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
