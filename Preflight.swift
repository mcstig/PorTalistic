//
//  Preflight.swift
//  Mythic
//
//  Created by Claude (Cowork) on 4/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 Explicit, named pre-flight checks for anything that's about to boot a Wine container.

 Heroic's biggest Mac pain point (per its own wiki/issue tracker) isn't any single bug —
 it's that failures are opaque: a game just doesn't start, or crashes instantly, and the
 user is left guessing whether it's Rosetta, a missing engine, a broken container, or the
 game itself. `Preflight` exists so every codepath that launches something through Wine
 (Steam's included) checks the same short list of "is the ground solid" conditions up
 front and throws a specific, actionable `LocalizedError` instead of failing deep inside
 a Process pipe.

 This intentionally does *not* try to diagnose the game itself (missing DLLs, unsupported
 DirectX version, anti-cheat, etc.) — that's a much larger, per-game compatibility problem.
 It only rules out the environment-level failures that are entirely within Mythic's control.
 */
enum Preflight {
    struct RosettaMissingError: LocalizedError {
        var errorDescription: String? = String(localized: "Rosetta 2 isn't installed. Apple Silicon Macs need it to run Windows games — install it from Settings > Engine, then try again.")
    }

    struct EngineMissingError: LocalizedError {
        var errorDescription: String? = String(localized: "Mythic Engine (Mythic's Wine + Game Porting Toolkit build) isn't installed yet. Install it from Settings > Engine, then try again.")
    }

    struct ContainerInvalidError: LocalizedError {
        let containerURL: URL
        var errorDescription: String? {
            String(localized: "The container at \(containerURL.prettyPath) is missing or corrupted. Try recreating it from the Containers tab.")
        }
    }

    struct InsufficientDiskSpaceError: LocalizedError {
        let availableBytes: Int64
        var errorDescription: String? {
            let formatter = ByteCountFormatter()
            return String(localized: "Only \(formatter.string(fromByteCount: availableBytes)) of free disk space remains. Free up some space before continuing.")
        }
    }

    /// The minimum free space Mythic will proceed with for a container boot/launch —
    /// deliberately conservative, since Wine/DXVK shader caches and Steam's own
    /// housekeeping can consume space during a session, not just at install time.
    private static let minimumFreeBytes: Int64 = 2_000_000_000 // 2 GB

    /// Throws a specific error the moment any environment-level precondition for
    /// running a Windows binary through Mythic Engine isn't met.
    static func requireEngineAndRosetta() async throws {
        guard Engine.isInstalled else { throw EngineMissingError() }
        guard Rosetta.exists else { throw RosettaMissingError() }
    }

    /// As `requireEngineAndRosetta()`, plus verifies the given container actually exists
    /// and is readable, and that there's enough free disk space to safely proceed.
    static func requireReadyToLaunch(containerURL: URL) async throws {
        try await requireEngineAndRosetta()

        guard Wine.containerExists(at: containerURL),
              (try? Wine.getContainerObject(at: containerURL)) != nil else {
            throw ContainerInvalidError(containerURL: containerURL)
        }

        if let available = try? FileManager.default
            .attributesOfFileSystem(forPath: containerURL.path)[.systemFreeSize] as? Int64,
           available < minimumFreeBytes {
            throw InsufficientDiskSpaceError(availableBytes: available)
        }
    }

    /// A non-throwing variant that collects every failing check instead of stopping at the
    /// first one — intended for a diagnostics/status UI (e.g. "why won't this launch?")
    /// rather than for gating an actual launch.
    static func diagnose(containerURL: URL?) async -> [LocalizedError] {
        var issues: [LocalizedError] = []

        if !Engine.isInstalled { issues.append(EngineMissingError()) }
        if !Rosetta.exists { issues.append(RosettaMissingError()) }

        if let containerURL {
            let containerValid = Wine.containerExists(at: containerURL)
                && (try? Wine.getContainerObject(at: containerURL)) != nil
            if !containerValid { issues.append(ContainerInvalidError(containerURL: containerURL)) }

            if let available = try? FileManager.default
                .attributesOfFileSystem(forPath: containerURL.path)[.systemFreeSize] as? Int64,
               available < minimumFreeBytes {
                issues.append(InsufficientDiskSpaceError(availableBytes: available))
            }
        }

        return issues
    }
}
