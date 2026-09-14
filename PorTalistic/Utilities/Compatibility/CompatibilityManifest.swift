//
//  CompatibilityManifest.swift
//  Mythic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog
import SemanticVersion

/**
 The runtime catalogue and the per-game compatibility list, fetched rather than compiled in.

 Both used to be Swift literals, which meant a new Wine build or a correction to one game's
 settings needed an app update to reach anybody — the runtime catalogue's own comment asked
 for this. A manifest also makes the data reviewable: it is a file in the repository that
 someone can read, diff, and send a pull request against, which matters for the half of it
 that can only ever come from people running games.

 # What is and isn't trusted

 The wire format is deliberately its own type rather than `Codable` on the real ones. A
 hand-edited file should look hand-editable — `"storefront": "gog"`, `"version": "11.0.0"` —
 and not the shape Swift happens to synthesise for an enum without raw values, which is
 `{"gog": {}}`. It also means the internal types stay free to change without breaking every
 manifest already published.

 Three rules constrain what a fetched manifest can do, because it arrives over the network
 and decides what gets downloaded and executed:

 1. **Every payload is still digest-pinned.** A manifest names a tarball and its SHA-256;
    `RuntimeInstaller` verifies the bytes before unpacking. That check predates this and is
    what actually stands in for Gatekeeper, since Mythic clears the quarantine attribute.
 2. **Compiled-in releases are a floor.** Where a fetched entry shares an id with one that
    shipped in the app, the app's download URL and digest win — only the descriptive fields
    can be updated. So a manifest cannot re-point `wine-stable-11.0` at different bytes, and
    the runtimes the app shipped knowing about stay exactly what it shipped knowing.
 3. **New entries are constrained.** HTTPS only, from a small set of hosts, with a
    well-formed digest and an id that can safely be a directory name.

 What that does not cover: a *new* runtime id, which is trusted on the strength of the
 repository and TLS alone. Signing the manifest with a key shipped in the app would close
 that, and is the obvious next step — worth doing before this is pointed at a public
 repository that accepts contributions.
 */
struct CompatibilityManifest: Decodable {
    static let log: Logger = .custom(category: "CompatibilityManifest")

    /// Incremented when the shape changes incompatibly. A manifest from the future is
    /// ignored rather than half-read, so an older app keeps working after the format moves on.
    static let supportedFormatVersion: Int = 1

    let formatVersion: Int
    var runtimes: [RuntimeEntry] = []
    var games: [GameEntry] = []

    // MARK: - Wire format

    struct RuntimeEntry: Decodable {
        let id: String
        let name: String
        /// Dotted, e.g. `"11.0.0"`. A string on the wire on purpose: the encoding the
        /// `SemanticVersion` package chooses is its business, not the manifest's.
        let version: String
        let downloadURL: URL
        let sha256: String
        let payloadSubpath: String
        let executableSubpath: String
        let summary: String
        /// See `RuntimeRelease.exposesMetalEscapes`. Absent means false, which is the safe
        /// default: claiming it wrongly gets a game a Direct3D 11 layer that half-works.
        var exposesMetalEscapes: Bool?
        var supportLibraries: SupportLibrariesEntry?

        struct SupportLibrariesEntry: Decodable {
            let downloadURL: URL
            let sha256: String
            let payloadSubpath: String
        }
    }

    struct GameEntry: Decodable {
        /// Storefront-qualified ids, `"gog:1158493447"` or `"epicGames:Boga"`.
        var ids: [String]?
        var titles: [String]?
        /// One of `RuntimeProfile.GraphicsBackend`'s raw values.
        var graphicsBackend: String?
        var requiresModernNetworking: Bool?
        var settings: SettingsEntry?
        var note: String?

        struct SettingsEntry: Decodable {
            var dxvk: Bool?
            var dxvkAsync: Bool?
            var retinaMode: Bool?
            var commandStreamThread: Bool?
            var msync: Bool?
            var metalHUD: Bool?
            var avx2: Bool?
            /// One of `Wine.WindowsVersion`'s raw values, e.g. `"10"`.
            var windowsVersion: String?
        }
    }

    // MARK: - Location

    /// Where the manifest is fetched from.
    ///
    /// - Important: `raw.githubusercontent.com` serves public repositories only. While
    ///   `mcstig/PorTalistic` is private the fetch returns 404 for everyone, which is
    ///   deliberately a non-event — the compiled-in catalogue and seed are the fallback and a
    ///   failed refresh is logged and forgotten — but nothing published here reaches anybody
    ///   until the repository is public. Owner, repository and branch are set here and
    ///   nowhere else.
    static let remoteURL: URL = .init(
        string: "https://raw.githubusercontent.com/mcstig/PorTalistic/main/Compatibility/manifest.json"
    )!

    /// Hosts a runtime may be downloaded from.
    ///
    /// Not a security boundary on its own — anyone can publish a release on GitHub — but it
    /// keeps a mistake in the manifest from becoming a download from anywhere at all.
    private static let allowedDownloadHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "raw.githubusercontent.com"
    ]

    /// Last good manifest, so an offline launch still gets the newest data rather than
    /// falling all the way back to what the app shipped with.
    static var cacheURL: URL? {
        Bundle.appHome?.appending(path: "Compatibility/manifest.json")
    }

    // MARK: - Lifecycle

    /// Apply the cached manifest, then refresh in the background.
    ///
    /// Cache first and synchronously: a game can be launched seconds after the app opens, and
    /// it should not matter whether a network round-trip finished first.
    static func bootstrap() {
        if let cached = loadCached() {
            apply(cached)
        }

        Task.detached(priority: .utility) {
            await refresh()
        }
    }

    /// Fetch, validate, apply, and cache. Silent on failure by design.
    static func refresh() async {
        var request: URLRequest = .init(url: remoteURL)
        request.timeoutInterval = 20
        // The raw-content CDN caches aggressively; without this a corrected entry can take
        // minutes to reach anyone, which defeats the point of fetching it at all.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log.notice("No compatibility manifest available (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)); using what shipped with the app")
                return
            }

            let manifest = try JSONDecoder().decode(CompatibilityManifest.self, from: data)

            guard manifest.formatVersion <= supportedFormatVersion else {
                log.notice("Compatibility manifest is format \(manifest.formatVersion, privacy: .public), newer than this app understands; ignoring it")
                return
            }

            apply(manifest)

            if let cacheURL {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        } catch {
            log.warning("Couldn't refresh the compatibility manifest: \(error.localizedDescription)")
        }
    }

    private static func loadCached() -> CompatibilityManifest? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
        guard let manifest = try? JSONDecoder().decode(CompatibilityManifest.self, from: data),
              manifest.formatVersion <= supportedFormatVersion else { return nil }

        return manifest
    }

    // MARK: - Application

    static func apply(_ manifest: CompatibilityManifest) {
        let runtimes = manifest.resolvedRuntimes()
        let games = manifest.resolvedGames()

        RuntimeRelease.catalogue = runtimes
        if !games.isEmpty {
            CompatibilityDatabase.current = .init(entries: games)
        }

        log.notice("Compatibility manifest applied: \(runtimes.count, privacy: .public) runtimes, \(games.count, privacy: .public) game entries")
    }

    /// The catalogue the manifest asks for, with the compiled-in releases as a floor.
    ///
    /// Compiled-in entries are never dropped and never re-pointed: where ids collide the
    /// app's own URL and digest are kept and only the name and summary can move. Anything
    /// else would let a fetched file change which bytes get executed.
    func resolvedRuntimes() -> [RuntimeRelease] {
        var resolved: [RuntimeRelease] = RuntimeRelease.compiledIn
        var indexByID: [String: Int] = .init()

        for (index, release) in resolved.enumerated() {
            indexByID[release.id] = index
        }

        for entry in runtimes {
            if let index = indexByID[entry.id] {
                let shipped = resolved[index]

                if entry.sha256.lowercased() != shipped.sha256.lowercased() || entry.downloadURL != shipped.downloadURL {
                    Self.log.warning("Manifest tried to re-point \(entry.id, privacy: .public); keeping the version that shipped with the app")
                }

                // `exposesMetalEscapes` is held to the shipped value along with the URL and
                // digest: it decides whether a Direct3D 11 game is sent to this build, and a
                // fetched file shouldn't be able to turn that on for a build that lacks them.
                resolved[index] = .init(id: shipped.id,
                                        name: entry.name,
                                        version: shipped.version,
                                        downloadURL: shipped.downloadURL,
                                        sha256: shipped.sha256,
                                        payloadSubpath: shipped.payloadSubpath,
                                        executableSubpath: shipped.executableSubpath,
                                        summary: entry.summary,
                                        exposesMetalEscapes: shipped.exposesMetalEscapes,
                                        supportLibraries: shipped.supportLibraries)
                continue
            }

            guard let release = Self.validated(entry) else { continue }

            indexByID[release.id] = resolved.count
            resolved.append(release)
        }

        return resolved
    }

    /// A new runtime entry, if it passes every check. `nil` and a log line otherwise: one bad
    /// entry should not cost the user the rest of the manifest.
    private static func validated(_ entry: RuntimeEntry) -> RuntimeRelease? {
        func reject(_ reason: String) -> RuntimeRelease? {
            log.error("Ignoring manifest runtime '\(entry.id, privacy: .public)': \(reason, privacy: .public)")
            return nil
        }

        // The id becomes a directory name under `Runtimes/`, so a separator or a `..` in it
        // is a path escape, not a typo.
        let allowedIDCharacters: CharacterSet = .alphanumerics.union(.init(charactersIn: "-._"))
        guard !entry.id.isEmpty,
              entry.id.unicodeScalars.allSatisfy(allowedIDCharacters.contains),
              !entry.id.hasPrefix(".") else {
            return reject("id isn't usable as a directory name")
        }

        guard SemanticVersion(entry.version) != nil else {
            return reject("version '\(entry.version)' isn't a semantic version")
        }

        guard isWellFormedDigest(entry.sha256) else {
            return reject("sha256 isn't 64 hex characters")
        }

        guard isAllowedDownload(entry.downloadURL) else {
            return reject("download URL isn't HTTPS on a known host")
        }

        if let support = entry.supportLibraries {
            guard isWellFormedDigest(support.sha256), isAllowedDownload(support.downloadURL) else {
                return reject("support libraries failed the same checks")
            }
        }

        guard let version = SemanticVersion(entry.version) else { return nil }

        return .init(id: entry.id,
                     name: entry.name,
                     version: version,
                     downloadURL: entry.downloadURL,
                     sha256: entry.sha256.lowercased(),
                     payloadSubpath: entry.payloadSubpath,
                     executableSubpath: entry.executableSubpath,
                     summary: entry.summary,
                     exposesMetalEscapes: entry.exposesMetalEscapes ?? false,
                     supportLibraries: entry.supportLibraries.map {
                         .init(downloadURL: $0.downloadURL,
                               sha256: $0.sha256.lowercased(),
                               payloadSubpath: $0.payloadSubpath)
                     })
    }

    private static func isWellFormedDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.lowercased().allSatisfy(\.isHexDigit)
    }

    private static func isAllowedDownload(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return allowedDownloadHosts.contains(host)
    }

    /// The game entries the manifest carries, replacing the compiled-in seed outright.
    ///
    /// Replaced rather than merged, unlike the runtimes: these are opinions about settings,
    /// not addresses to download from, so the worst a wrong one does is make a game behave
    /// the way it behaved before anyone looked at it. Keeping a stale local copy alive
    /// underneath a correction would be the greater harm.
    func resolvedGames() -> [CompatibilityDatabase.Entry] {
        games.compactMap { entry in
            let identifiers: [CompatibilityDatabase.Entry.Identifier] = (entry.ids ?? []).compactMap { qualified in
                let parts = qualified.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)

                guard parts.count == 2, let storefront = Game.Storefront(manifestName: String(parts[0])) else {
                    Self.log.error("Ignoring manifest game id '\(qualified, privacy: .public)': expected 'storefront:id'")
                    return nil
                }

                return .init(storefront: storefront, id: String(parts[1]))
            }

            let titles = entry.titles ?? []
            guard !identifiers.isEmpty || !titles.isEmpty else {
                Self.log.error("Ignoring a manifest game entry with nothing to match on")
                return nil
            }

            return .init(identifiers: identifiers,
                         titles: titles,
                         graphicsBackend: entry.graphicsBackend.flatMap(RuntimeProfile.GraphicsBackend.init(rawValue:)),
                         requiresModernNetworking: entry.requiresModernNetworking,
                         settings: .init(dxvk: entry.settings?.dxvk,
                                         dxvkAsync: entry.settings?.dxvkAsync,
                                         retinaMode: entry.settings?.retinaMode,
                                         commandStreamThread: entry.settings?.commandStreamThread,
                                         msync: entry.settings?.msync,
                                         metalHUD: entry.settings?.metalHUD,
                                         avx2: entry.settings?.avx2,
                                         windowsVersion: entry.settings?.windowsVersion
                                            .flatMap(Wine.WindowsVersion.init(rawValue:))),
                         note: entry.note)
        }
    }
}

extension Game.Storefront {
    /// The name this storefront goes by in a manifest.
    ///
    /// Spelled out rather than derived from `description`, which is localised, or from a raw
    /// value, which this enum doesn't have. A manifest is a file people edit by hand and its
    /// spellings shouldn't change with the user's language.
    var manifestName: String {
        switch self {
        case .epicGames:    "epicGames"
        case .gog:          "gog"
        case .steam:        "steam"
        case .local:        "local"
        }
    }

    init?(manifestName: String) {
        guard let matched = Self.allCases.first(where: { $0.manifestName == manifestName }) else { return nil }
        self = matched
    }
}
