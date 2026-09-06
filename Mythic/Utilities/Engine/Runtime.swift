//
//  Runtime.swift
//  Mythic
//
//  Created by Claude (Cowork) on 6/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog
import SemanticVersion

/**
 A Wine-family translation layer that can back a container.

 Mythic assumed exactly one — `Engine.wineExecutableURL`, a `static let` pointing at the
 bundled build. That assumption is the thing standing between us and games actually
 running: no single Wine version works for everything. The bundled engine is Wine 7.7,
 which installs the modern Steam client and then can't run it; a current Game Porting
 Toolkit runs Steam but may regress older titles that the 7.7 build handles fine.

 So a runtime is a first-class, discoverable thing here, and the choice of which one to
 use belongs to the game (or the container), not to the app as a whole.

 - Note: A container is tied to the runtime it was created against. Wine upgrades a prefix
   in place on first run and won't downgrade it, so switching a container to an older
   runtime afterwards is not safe. ``Runtime/isCompatible(withPrefixCreatedBy:)`` exists to
   make that explicit rather than discovered the hard way.
 */
struct Runtime: Identifiable, Hashable {
    /// Stable identifier, unique per install location.
    let id: String

    /// Human-readable name, e.g. "Game Porting Toolkit 3.0".
    let name: String

    /// The `wine64` binary this runtime is driven through.
    let executableURL: URL

    /// Where this runtime came from — determines whether Mythic may manage it.
    let origin: Origin

    /// Wine version, resolved lazily by ``Runtime/resolvedVersion()``.
    var version: SemanticVersion?

    enum Origin: Hashable {
        /// Shipped and updated by Mythic itself.
        case bundledEngine
        /// Downloaded and unpacked by Mythic into its own runtimes directory.
        case managed
        /// Installed by the user through some other means (Homebrew, CrossOver, Whisky).
        /// Discovered, used, never modified or deleted.
        case external
    }

    var isManagedByMythic: Bool {
        switch origin {
        case .bundledEngine, .managed: true
        case .external: false
        }
    }

    var isInstalled: Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            // `isExecutableFile` answers true for directories as well, since POSIX treats
            // the execute bit on a directory as search permission — which let a tools
            // *folder* through as though it were a wine binary.
            return false
        }

        return FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    /// Asks the binary what version it is. Cheap, but shells out — cache the result.
    func resolvedVersion() -> SemanticVersion? {
        guard isInstalled else { return nil }

        let process: Process = .init()
        process.executableURL = executableURL
        process.arguments = ["--version"]

        guard let output = (try? process.runWrapped())?.standardOutput,
              let match = try? Regex(#"wine-(\S+)"#).firstMatch(in: output),
              let extracted = match.last?.substring else {
            return nil
        }

        return SemanticVersion(fromRelaxedString: .init(extracted))
    }

    /// Whether a prefix created by `other` can safely be run with this runtime.
    ///
    /// Wine migrates a prefix forward on first run and has no downgrade path, so this is
    /// only true when moving to the same version or newer.
    func isCompatible(withPrefixCreatedBy other: Runtime) -> Bool {
        guard let mine = version ?? resolvedVersion(),
              let theirs = other.version ?? other.resolvedVersion() else {
            // Unknown on either side: don't claim safety we can't verify.
            return id == other.id
        }

        return mine >= theirs
    }
}

// MARK: - Discovery

extension Runtime {
    static let log: Logger = .custom(category: "Runtime")

    /// Where Mythic unpacks runtimes it manages itself.
    static var managedDirectory: URL? {
        Bundle.appHome?.appending(path: "Runtimes")
    }

    /// The build Mythic ships and updates.
    static var bundled: Runtime {
        .init(id: "mythic-engine",
              name: "Mythic Engine",
              executableURL: Engine.wineExecutableURL,
              origin: .bundledEngine)
    }

    /// Locations worth checking for runtimes the user installed themselves.
    ///
    /// Deliberately read-only: these belong to other applications, and Mythic borrows them
    /// rather than taking ownership. Globs are resolved at discovery time because
    /// Homebrew's Cellar paths carry the version.
    /// Binary names a Wine install might expose, newest convention first.
    ///
    /// Wine 11 dropped `wine64` entirely — the new WoW64 architecture runs 32-bit Windows
    /// processes through the single 64-bit `wine` binary. Older builds (the bundled 7.7
    /// engine, GPTK, CrossOver) still ship the split pair, so both have to be probed.
    static let executableNames = ["wine64", "wine"]

    /// Resolves the wine binary inside a `bin` directory, whichever convention it uses.
    static func executable(inBinDirectory binDirectory: URL) -> URL? {
        executableNames
            .map { binDirectory.appending(path: $0) }
            .first { candidate in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
    }

    private static var externalCandidates: [(name: String, path: String)] {
        let home = NSHomeDirectory()

        return [
            // The Gcenx cask installs GPTK as an app bundle, not into the Homebrew prefix.
            ("Game Porting Toolkit", "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"),
            ("Game Porting Toolkit", "\(home)/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"),

            // Older formula-style installs.
            ("Game Porting Toolkit (Homebrew)", "/opt/homebrew/opt/game-porting-toolkit/bin/wine64"),
            ("Game Porting Toolkit (Homebrew, Intel)", "/usr/local/opt/game-porting-toolkit/bin/wine64"),

            ("Wine CrossOver", "/Applications/Wine Crossover.app/Contents/Resources/wine/bin/wine64"),
            ("Wine CrossOver (Homebrew)", "/opt/homebrew/opt/wine-crossover/bin/wine64"),
            ("Wine Stable", "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine64"),
            ("Wine Devel", "/Applications/Wine Devel.app/Contents/Resources/wine/bin/wine64"),

            ("CrossOver", "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64"),
            ("Whisky", "\(home)/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64"),
            ("Heroic (bundled wine)", "\(home)/Library/Application Support/heroic/tools/wine"),

            ("Wine (Homebrew)", "/opt/homebrew/bin/wine64"),
            ("Wine (Homebrew, Intel)", "/usr/local/bin/wine64")
        ]
    }

    /// Every runtime currently available on this machine.
    ///
    /// - Note: Version resolution shells out once per runtime, so call this when the set of
    ///   runtimes might have changed rather than on every launch.
    static func discoverAll() -> [Runtime] {
        var discovered: [Runtime] = []

        var bundledRuntime = bundled
        if bundledRuntime.isInstalled {
            bundledRuntime.version = bundledRuntime.resolvedVersion()
            discovered.append(bundledRuntime)
        }

        if let managedDirectory,
           let entries = try? FileManager.default.contentsOfDirectory(at: managedDirectory,
                                                                     includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles]) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let release = RuntimeRelease.catalogue.first { $0.id == entry.lastPathComponent }
                let executableURL = release
                    .map { entry.appending(path: $0.executableSubpath) }
                    ?? executable(inBinDirectory: entry.appending(path: "Contents/Resources/wine/bin"))
                    ?? entry.appending(path: "bin/wine64")

                var runtime = Runtime(id: "managed:\(entry.lastPathComponent)",
                                      name: release?.name ?? entry.lastPathComponent,
                                      executableURL: executableURL,
                                      origin: .managed)
                guard runtime.isInstalled else { continue }
                runtime.version = runtime.resolvedVersion()
                discovered.append(runtime)
            }
        }

        for candidate in externalCandidates {
            let listed = URL(filePath: candidate.path)
            guard let executableURL = executable(inBinDirectory: listed.deletingLastPathComponent()) else { continue }

            // Two candidates can resolve to the same binary (a Homebrew symlink pointing
            // into an app bundle, say); keep the first and don't list it twice.
            guard !discovered.contains(where: { $0.executableURL.standardizedFileURL == executableURL.standardizedFileURL }) else { continue }

            var runtime = Runtime(id: "external:\(executableURL.path)",
                                  name: candidate.name,
                                  executableURL: executableURL,
                                  origin: .external)
            guard runtime.isInstalled else { continue }
            runtime.version = runtime.resolvedVersion()
            discovered.append(runtime)
        }

        log.notice("Discovered \(discovered.count, privacy: .public) Wine runtime(s): \(discovered.map(\.description).joined(separator: ", "), privacy: .public)")
        return discovered
    }

    /// The newest runtime available, which is the best default for anything that has no
    /// per-game preference of its own.
    static func newestAvailable() -> Runtime? {
        let available = discoverAll()

        // Prefer the newest runtime whose version we could actually read; fall back to the
        // bundled engine rather than guessing at an unversioned build.
        let versioned = available.compactMap { runtime -> (Runtime, SemanticVersion)? in
            guard let version = runtime.version else { return nil }
            return (runtime, version)
        }

        return versioned.max(by: { $0.1 < $1.1 })?.0 ?? available.first
    }
}

extension Runtime: CustomStringConvertible {
    var description: String {
        "\(name)\(version.map { " (wine \($0.description))" } ?? "")"
    }
}
