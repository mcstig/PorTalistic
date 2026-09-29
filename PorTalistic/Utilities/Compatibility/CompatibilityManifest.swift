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

 4. **The whole file is signed.** A detached Ed25519 signature sits beside it and the public
    half is compiled in; a manifest that doesn't verify is discarded before it is parsed. See
    ``ManifestSignature``, which is also where "no key compiled in" is documented as meaning
    "trust no fetched manifest at all". That rule is what covers the case the other three
    don't: a *new* runtime id, which was otherwise trusted on the strength of TLS and nobody
    having write access to the repository who shouldn't.
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
        /// See `RuntimeRelease.hasNativeThirtyTwoBit`. Absent means false, and like
        /// `exposesMetalEscapes` it is held to the shipped value where ids collide: it decides
        /// which build a game is sent to, so a fetched file must not be able to claim it.
        var hasNativeThirtyTwoBit: Bool?
        /// See `RuntimeRelease.family`. Absent means the build is its own lineage, so it is
        /// never pruned and never prunes anything — and like the two flags above it is held
        /// to the shipped value where ids collide, because a family decides which builds get
        /// deleted and a fetched file must not be able to point that at something else.
        var family: String?
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
        var requiresNativeThirtyTwoBit: Bool?
        /// Winetricks verbs the prefix needs, e.g. `["d3dcompiler_43"]`.
        var winetricks: [String]?
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
            var captureDisplaysForFullscreen: Bool?
            /// Wine's own override specs, keyed by DLL: `{"atiadlxx": "d"}`. Use `"n,b"`
            /// rather than `"n"` — native-only turns a missing file into a game that will
            /// not launch at all.
            var dllOverrides: [String: String]?
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

    /// The detached signature, beside the manifest.
    static var remoteSignatureURL: URL {
        remoteURL.appendingPathExtension(ManifestSignature.signatureExtension)
    }

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

    /// The cached manifest's signature.
    ///
    /// Cached so that the cache can be *re-verified* on load rather than trusted for being
    /// on disk. The manifest lives in the app's own support directory, which is not a
    /// security boundary — anything that can write there can edit the cache.
    static var signatureCacheURL: URL? {
        cacheURL?.appendingPathExtension(ManifestSignature.signatureExtension)
    }

    // MARK: - Lifecycle

    /// Apply the cached manifest, then refresh in the background.
    ///
    /// Cache first and synchronously: a game can be launched seconds after the app opens, and
    /// it should not matter whether a network round-trip finished first.
    @MainActor static func bootstrap() {
        if let cached = loadCached() {
            apply(cached)
        }

        pendingRefresh = Task.detached(priority: .utility) {
            await refresh()
            await MainActor.run { pendingRefresh = nil }
        }
    }

    /// The refresh ``bootstrap()`` started, until it has finished.
    ///
    /// Kept so a launch in the app's first seconds can wait for it — see
    /// ``waitForPendingRefresh(atMost:)``.
    @MainActor private static var pendingRefresh: Task<Void, Never>?

    /// Wait for the refresh started at launch, if it is still running — but not for long.
    ///
    /// Polled rather than awaited: awaiting a task's value can't be abandoned part-way, and
    /// a fetch that hangs would then hold a launch for both of its 20-second timeouts.
    @MainActor static func waitForPendingRefresh(atMost limit: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: limit)

        while pendingRefresh != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Fetch, verify, validate, apply, and cache. Silent on failure by design.
    static func refresh() async {
        // Asked before anything is fetched: with no key compiled in nothing that comes back
        // can be trusted, and two requests to discard the answer is worse than none.
        guard ManifestSignature.isConfigured else {
            ManifestSignature.logMissingKey()
            return
        }

        do {
            guard let data = try await fetch(remoteURL) else { return }
            guard let signatureFile = try await fetch(remoteSignatureURL) else {
                log.notice("The compatibility manifest has no signature beside it; ignoring it")
                return
            }

            guard let signature = ManifestSignature.decodeSignature(signatureFile),
                  ManifestSignature.verify(data, signature: signature) else { return }

            guard let manifest = decode(data) else { return }

            apply(manifest)
            cache(data, signature: signatureFile)

            // The pass at launch worked from the cached copy — on a first run, from what the
            // app shipped with. A build or a game entry this fetch just brought is one it
            // could not have acted on, and nothing else was going to look again.
            await MainActor.run {
                Provisioner.shared.requestPass(because: "the compatibility manifest was refreshed")
            }
        } catch {
            log.warning("Couldn't refresh the compatibility manifest: \(error.localizedDescription)")
        }
    }

    /// One file from the manifest's repository, or `nil` if it isn't there.
    ///
    /// A missing manifest is a non-event, not an error: the repository may be private, the
    /// branch may not have one yet, and the compiled-in catalogue is the fallback either way.
    private static func fetch(_ url: URL) async throws -> Data? {
        var request: URLRequest = .init(url: url)
        request.timeoutInterval = 20
        // The raw-content CDN caches aggressively; without this a corrected entry can take
        // minutes to reach anyone, which defeats the point of fetching it at all.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            log.notice("\(url.lastPathComponent, privacy: .public) isn't available (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)); using what shipped with the app")
            return nil
        }

        return data
    }

    private static func decode(_ data: Data) -> CompatibilityManifest? {
        guard let manifest = try? JSONDecoder().decode(CompatibilityManifest.self, from: data) else {
            log.error("A compatibility manifest verified but wouldn't decode")
            return nil
        }

        guard manifest.formatVersion <= supportedFormatVersion else {
            log.notice("Compatibility manifest is format \(manifest.formatVersion, privacy: .public), newer than this app understands; ignoring it")
            return nil
        }

        return manifest
    }

    private static func cache(_ data: Data, signature: Data) {
        guard let cacheURL, let signatureCacheURL else { return }

        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        try? signature.write(to: signatureCacheURL, options: .atomic)
    }

    /// The last manifest that verified — verified again.
    ///
    /// Re-checked rather than trusted for being on disk: the cache lives in the app's support
    /// directory, which anything running as this user can write to. It is also what makes a
    /// key rotation take effect on the next launch rather than the next successful fetch.
    private static func loadCached() -> CompatibilityManifest? {
        guard let cacheURL, let signatureCacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let signatureFile = try? Data(contentsOf: signatureCacheURL),
              let signature = ManifestSignature.decodeSignature(signatureFile),
              ManifestSignature.verify(data, signature: signature) else { return nil }

        return decode(data)
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
                                        family: shipped.family,
                                        exposesMetalEscapes: shipped.exposesMetalEscapes,
                                        hasNativeThirtyTwoBit: shipped.hasNativeThirtyTwoBit,
                                        supportLibraries: shipped.supportLibraries)
                continue
            }

            guard let release = Self.validated(entry) else { continue }

            indexByID[release.id] = resolved.count
            resolved.append(release)
        }

        return Self.newestFirstWithinFamilies(resolved)
    }

    /// Newest first within each family, families left where they were.
    ///
    /// Catalogue order is preference order, and a manifest's new entries are appended — so a
    /// newer build of a lineage landed *behind* the one it supersedes, and `ranked()` went on
    /// choosing the older one. Nothing about that is visible: the download happens, the build
    /// installs, and it is simply never selected.
    ///
    /// Reordered within the family's own positions rather than globally, because the order
    /// *between* families is a deliberate preference — the bundled engine's path first, DXMT
    /// ahead of wined3d for Direct3D 11 — and sorting the whole list by version would throw
    /// that away.
    private static func newestFirstWithinFamilies(_ releases: [RuntimeRelease]) -> [RuntimeRelease] {
        var positionsByFamily: [String: [Int]] = .init()

        for (index, release) in releases.enumerated() {
            positionsByFamily[release.resolvedFamily, default: []].append(index)
        }

        var ordered = releases

        for (_, positions) in positionsByFamily where positions.count > 1 {
            let sorted = positions
                .map { releases[$0] }
                .enumerated()
                .sorted { left, right in
                    // Index as the tie-break, so equal versions keep the order they arrived in
                    // rather than depending on how the sort happens to be implemented.
                    left.element.version == right.element.version
                        ? left.offset < right.offset
                        : left.element.version > right.element.version
                }
                .map(\.element)

            for (position, release) in zip(positions, sorted) {
                ordered[position] = release
            }
        }

        return ordered
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
                     family: entry.family,
                     exposesMetalEscapes: entry.exposesMetalEscapes ?? false,
                     hasNativeThirtyTwoBit: entry.hasNativeThirtyTwoBit ?? false,
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
                         requiresNativeThirtyTwoBit: entry.requiresNativeThirtyTwoBit,
                         settings: .init(dxvk: entry.settings?.dxvk,
                                         dxvkAsync: entry.settings?.dxvkAsync,
                                         retinaMode: entry.settings?.retinaMode,
                                         commandStreamThread: entry.settings?.commandStreamThread,
                                         msync: entry.settings?.msync,
                                         metalHUD: entry.settings?.metalHUD,
                                         avx2: entry.settings?.avx2,
                                         captureDisplaysForFullscreen: entry.settings?.captureDisplaysForFullscreen,
                                         windowsVersion: entry.settings?.windowsVersion
                                            .flatMap(Wine.WindowsVersion.init(rawValue:)),
                                         dllOverrides: entry.settings?.dllOverrides),
                         winetricks: entry.winetricks ?? [],
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
