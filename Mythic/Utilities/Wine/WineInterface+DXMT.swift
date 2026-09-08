//
//  WineInterface+DXMT.swift
//  Mythic
//

// Copyright © 2023-2025 vapidinfinity

import Foundation

extension Wine {
    /// Direct3D 11 on Metal, for the runtimes Mythic manages.
    ///
    /// Neither engine Mythic shipped could run the Steam client on its own, and the reason is
    /// worth writing down because it applies to Direct3D 11 games too, not just to Steam:
    ///
    ///   - The bundled engine is Game Porting Toolkit derived and carries Apple's D3DMetal, so
    ///     Direct3D 11 works. It is also Wine 7.7, whose socket layer Steam trips over
    ///     constantly (`getsockname failed in BGetBoundAddr with error: 10022`, IPv6 tests
    ///     timing out, a connectivity check that takes a minute).
    ///   - The managed upstream builds have four years of fixes in them and working sockets.
    ///     They also have only wined3d, which on macOS has OpenGL 2.1 underneath it: Direct3D
    ///     feature level 9_3, an adapter that claims to be an NVIDIA GeForce 6800, and a
    ///     Chromium that gives up and paints nothing.
    ///
    /// DXVK doesn't bridge that gap — upstream DXVK 2.x requires the Vulkan `geometryShader`
    /// feature, which Metal does not have, so it rejects MoltenVK outright. DXMT does: it
    /// implements Direct3D 11 on Metal directly, and it targets current Wine.
    ///
    /// - Note: Only runtimes Mythic manages are touched. The Game Porting Toolkit, Whisky and
    ///   Homebrew installs Mythic discovers belong to other applications, and writing into
    ///   them would be modifying software the user installed for something else.
    enum DXMT {
        static let version = "v0.80"

        static var downloadURL: URL {
            .init(string: "https://github.com/3Shain/dxmt/releases/download/\(version)/dxmt-\(version)-builtin.tar.gz")!
        }

        /// Where a runtime keeps its Wine tree — the directory holding `lib/wine`.
        ///
        /// Runtimes are laid out `<root>/bin/wine`, whether that root sits inside an app
        /// bundle's `Contents/Resources/wine` or directly in a Homebrew prefix.
        static func wineRoot(of runtime: Runtime) -> URL {
            runtime.executableURL.deletingLastPathComponent().deletingLastPathComponent()
        }

        /// Whether this runtime has DXMT's libraries in place.
        static func isInstalled(in runtime: Runtime) -> Bool {
            FileManager.default.fileExists(
                atPath: wineRoot(of: runtime).appending(path: "lib/wine/x86_64-unix/winemetal.so").path
            )
        }

        struct UnsupportedRuntimeError: LocalizedError {
            let runtimeName: String
            var errorDescription: String? {
                String(localized: "\(runtimeName) isn't a runtime Mythic manages, so Mythic won't modify it. Install a managed Wine runtime and try again.")
            }
        }

        struct LayoutError: LocalizedError {
            let path: String
            var errorDescription: String? {
                String(localized: "This runtime doesn't have the directory DXMT needs (\(path)). It may be built differently to the ones Mythic expects.")
            }
        }

        /// Downloads DXMT and installs it into a managed runtime.
        ///
        /// DXMT ships as a Wine builtin rather than as native DLLs dropped in a prefix, which
        /// is why this writes into the runtime and not into a container: `winemetal` is a
        /// PE/unix pair, and the unix half has to sit where Wine's loader looks for builtins.
        /// It also means no `WINEDLLOVERRIDES` — these *are* the builtins now, and overriding
        /// them to native would send Wine looking for files that aren't there.
        /// Where a failed install leaves its account of itself.
        ///
        /// The button that calls this reports success or failure and nothing else, and the
        /// interesting failures are about a runtime's directory layout — which is exactly the
        /// thing you cannot see from a red cross.
        static var transcriptURL: URL? {
            Wine.containersDirectory?.appending(path: "dxmt-install.log")
        }

        private static func record(_ lines: [String]) {
            guard let transcriptURL else { return }
            try? lines.joined(separator: "\n").appending("\n")
                .write(to: transcriptURL, atomically: true, encoding: .utf8)
        }

        static func install(into runtime: Runtime) async throws {
            var transcript = ["runtime: \(runtime.name) [\(runtime.id)]",
                              "executable: \(runtime.executableURL.path)",
                              "wineRoot: \(wineRoot(of: runtime).path)"]
            defer { record(transcript) }

            guard runtime.isManagedByMythic else {
                transcript.append("refused: not managed by Mythic")
                throw UnsupportedRuntimeError(runtimeName: runtime.name)
            }

            let root = wineRoot(of: runtime)
            let destinations = [
                "x86_64-unix": root.appending(path: "lib/wine/x86_64-unix"),
                "x86_64-windows": root.appending(path: "lib/wine/x86_64-windows"),
                "i386-windows": root.appending(path: "lib/wine/i386-windows")
            ]

            // Refuse rather than guess. A runtime laid out differently would take the files
            // silently and then behave exactly as it did before, which is a worse outcome than
            // an error naming the directory that's missing.
            for (architecture, destination) in destinations.sorted(by: { $0.key < $1.key }) {
                transcript.append("\(architecture) -> \(destination.path) exists=\(FileManager.default.fileExists(atPath: destination.path))")
            }

            guard FileManager.default.fileExists(atPath: destinations["x86_64-unix"]!.path) else {
                transcript.append("refused: no x86_64-unix directory")
                if let listing = try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "lib/wine").path) {
                    transcript.append("lib/wine contains: \(listing.sorted())")
                } else if let listing = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
                    transcript.append("wineRoot contains: \(listing.sorted())")
                } else {
                    transcript.append("wineRoot is not readable or does not exist")
                }
                throw LayoutError(path: destinations["x86_64-unix"]!.path)
            }

            let staging = FileManager.default.temporaryDirectory
                .appending(path: "mythic-dxmt-\(version)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            Wine.log.notice("Downloading DXMT \(version, privacy: .public)…")
            let (archive, response) = try await URLSession.shared.download(from: downloadURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            transcript.append("download: HTTP \(status)")
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            let tarball = staging.appending(path: "dxmt.tar.gz")
            try FileManager.default.moveItem(at: archive, to: tarball)

            let extraction: Process = .init()
            extraction.executableURL = .init(filePath: "/usr/bin/tar")
            extraction.arguments = ["xzf", tarball.path, "-C", staging.path]
            let extracted = try await extraction.runWrapped()
            guard extraction.terminationStatus == 0 else {
                throw NSError(domain: "DXMT", code: .init(extraction.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: extracted.standardError ?? "Couldn't unpack DXMT."
                ])
            }

            // The tarball unpacks to a single version-named directory.
            guard let payload = try FileManager.default.contentsOfDirectory(
                at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ).first(where: { $0.hasDirectoryPath }) else {
                throw LayoutError(path: staging.path)
            }

            var installed = 0
            for (architecture, destination) in destinations {
                let source = payload.appending(path: architecture)
                guard let libraries = try? FileManager.default.contentsOfDirectory(
                    at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }

                guard FileManager.default.fileExists(atPath: destination.path) else {
                    Wine.log.notice("\(runtime.name, privacy: .public) has no \(architecture, privacy: .public) directory; skipping those libraries.")
                    continue
                }

                for library in libraries {
                    try FileManager.default.forceCopyItem(
                        at: library, to: destination.appending(path: library.lastPathComponent)
                    )
                    installed += 1
                }
            }

            transcript.append("installed \(installed) libraries")
            Wine.log.notice("Installed DXMT \(version, privacy: .public) into \(runtime.name, privacy: .public) (\(installed, privacy: .public) libraries).")
        }

        /// Puts `winemetal.dll` where a prefix's own loader will find it.
        ///
        /// The runtime carries the builtin, but Wine resolves a DLL through the prefix's
        /// `system32` first, and a prefix created before DXMT was installed has no entry there
        /// at all. Cheap, and idempotent.
        static func prepareContainer(at containerURL: URL, runtime: Runtime) throws {
            let source = wineRoot(of: runtime).appending(path: "lib/wine/x86_64-windows/winemetal.dll")
            guard FileManager.default.fileExists(atPath: source.path) else { return }

            try FileManager.default.forceCopyItem(
                at: source,
                to: containerURL.appending(path: "drive_c/windows/system32/winemetal.dll")
            )
        }
    }
}
