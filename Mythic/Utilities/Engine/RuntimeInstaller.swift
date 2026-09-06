//
//  RuntimeInstaller.swift
//  Mythic
//
//  Created by Claude (Cowork) on 6/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import CryptoKit
import OSLog

/// Downloads, verifies and installs ``RuntimeRelease``s into Mythic's own runtimes directory.
enum RuntimeInstaller {
    static let log: Logger = .custom(category: "RuntimeInstaller")

    /// Coarse stages, for driving a progress UI.
    enum Stage: Equatable {
        /// 0...1, or `nil` when the server doesn't report a length.
        case downloading(Double?)
        case verifying
        case extracting
        case finalising

        var localizedDescription: String {
            switch self {
            case .downloading: String(localized: "Downloading…")
            case .verifying:   String(localized: "Verifying download…")
            case .extracting:  String(localized: "Extracting…")
            case .finalising:  String(localized: "Finishing up…")
            }
        }
    }

    // MARK: - Errors

    struct ChecksumMismatchError: LocalizedError {
        let expected: String
        let actual: String
        var errorDescription: String? {
            String(localized: "The downloaded runtime didn't match its expected checksum, so it wasn't installed.")
        }
        var failureReason: String? { "expected \(expected), got \(actual)" }
        var recoverySuggestion: String? {
            String(localized: "This usually means the download was corrupted. Try again — and if it keeps happening, don't force it.")
        }
    }

    struct ExtractionFailedError: LocalizedError {
        let detail: String
        var errorDescription: String? { String(localized: "Couldn't extract the downloaded runtime.") }
        var failureReason: String? { detail }
    }

    struct PayloadMissingError: LocalizedError {
        let expectedPath: String
        var errorDescription: String? {
            String(localized: "The downloaded runtime didn't contain the files Mythic expected.")
        }
        var failureReason: String? { "missing \(expectedPath)" }
    }

    struct AlreadyInstalledError: LocalizedError {
        let name: String
        var errorDescription: String? { String(localized: "\(name) is already installed.") }
    }

    // MARK: - Install

    /// Fetches a runtime and installs it under `Runtimes/<id>/`.
    ///
    /// Every step happens in a temporary directory and only the final, verified payload is
    /// moved into place, so a failure part-way through can't leave a half-installed runtime
    /// that discovery would later present as usable.
    @discardableResult
    static func install(
        _ release: RuntimeRelease,
        onStage: @escaping @Sendable (Stage) -> Void = { _ in }
    ) async throws -> Runtime {
        guard let managedDirectory = Runtime.managedDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }

        let destination = managedDirectory.appending(path: release.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw AlreadyInstalledError(name: release.name)
        }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "MythicRuntime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 1. Download
        onStage(.downloading(nil))
        let archive = try await download(release, into: scratch, onProgress: { onStage(.downloading($0)) })

        // 2. Verify before touching anything executable.
        onStage(.verifying)
        let digest = try sha256(ofFileAt: archive)
        guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else {
            throw ChecksumMismatchError(expected: release.sha256, actual: digest)
        }
        log.notice("Verified \(release.name, privacy: .public) against its pinned digest")

        // 3. Extract
        onStage(.extracting)
        let extracted = scratch.appending(path: "extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try extract(archive: archive, into: extracted)

        let payload = extracted.appending(path: release.payloadSubpath)
        guard FileManager.default.fileExists(atPath: payload.path) else {
            throw PayloadMissingError(expectedPath: release.payloadSubpath)
        }

        // 4. Move into place, then make it runnable.
        onStage(.finalising)
        try FileManager.default.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: payload, to: destination)

        try await clearQuarantine(at: destination)

        var runtime = Runtime(id: "managed:\(release.id)",
                              name: release.name,
                              executableURL: destination.appending(path: release.executableSubpath),
                              origin: .managed)

        guard runtime.isInstalled else {
            try? FileManager.default.removeItem(at: destination)
            throw PayloadMissingError(expectedPath: release.executableSubpath)
        }

        // Asking the binary its version proves it actually runs, not just that it exists.
        runtime.version = runtime.resolvedVersion()
        log.notice("Installed \(runtime.description, privacy: .public) at \(destination.path, privacy: .public)")

        return runtime
    }

    /// Removes a runtime Mythic installed. Refuses anything it doesn't own.
    static func remove(_ runtime: Runtime) throws {
        guard case .managed = runtime.origin else {
            throw CocoaError(.fileWriteNoPermission)
        }

        // The runtime root is the executable path minus the executable's subpath, so derive
        // it from the managed directory instead of guessing at path arithmetic.
        guard let managedDirectory = Runtime.managedDirectory else { return }
        let name = runtime.id.replacingOccurrences(of: "managed:", with: "")
        let root = managedDirectory.appending(path: name)

        guard root.path.hasPrefix(managedDirectory.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }

        try FileManager.default.removeItem(at: root)
        log.notice("Removed runtime \(name, privacy: .public)")
    }

    // MARK: - Steps

    private final class ProgressBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
        func invalidate() { observation?.invalidate(); observation = nil }
    }

    private static func download(
        _ release: RuntimeRelease,
        into directory: URL,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let progress = ProgressBox()
        let destination = directory.appending(path: release.downloadURL.lastPathComponent)

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: release.downloadURL) { location, response, error in
                progress.invalidate()

                if let error { continuation.resume(throwing: error); return }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                guard let location else {
                    continuation.resume(throwing: URLError(.cannotOpenFile)); return
                }

                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            progress.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { _, change in
                onProgress(change.newValue)
            }

            task.resume()
        }
    }

    /// Streams the file through SHA-256 rather than reading it into memory — these archives
    /// run to hundreds of megabytes.
    private static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func extract(archive: URL, into directory: URL) throws {
        let process: Process = .init()
        process.executableURL = .init(filePath: "/usr/bin/tar")
        // Arguments are passed as an array, so no shell quoting is involved and a path
        // containing spaces or quotes can't be misread as anything else.
        process.arguments = ["-xf", archive.path, "-C", directory.path]

        let errorPipe: Pipe = .init()
        process.standardError = errorPipe

        try process.run()
        let errorOutput = (try? errorPipe.fileHandleForReading.readToEnd())
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExtractionFailedError(detail: errorOutput.isEmpty
                                        ? "tar exited with status \(process.terminationStatus)"
                                        : errorOutput)
        }
    }

    /// Clears the quarantine flag macOS applies to anything downloaded.
    ///
    /// Without this nothing we install will launch. It does mean Gatekeeper won't vet these
    /// binaries — which is precisely why ``RuntimeRelease/sha256`` is mandatory and checked
    /// before we ever get here. Homebrew's `--no-quarantine` makes the same trade.
    private static func clearQuarantine(at url: URL) async throws {
        let process: Process = .init()
        process.executableURL = .init(filePath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            // Not fatal on its own: the attribute may simply not have been set.
            log.warning("xattr exited with status \(process.terminationStatus) while clearing quarantine")
        }
    }
}
