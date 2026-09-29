//
//  WineInterface+Certificates.swift
//  Mythic
//

// Copyright © 2023-2025 vapidinfinity

import CryptoKit
import Foundation
import Security

extension Wine {
    /// Gives a container the Mac's root certificates.
    ///
    /// Wine builds its root store by reading the CA bundles a Linux distribution leaves in
    /// `/etc/ssl` and friends. macOS keeps its roots in the keychain instead, so on a Mac
    /// those paths turn up nothing and the prefix ends up with an *empty* root store. Wine 8
    /// added an import from the host's trust store; the bundled engine is older than that and
    /// has no such thing, which leaves every HTTPS request inside the container failing to
    /// verify — with no mention of certificates anywhere in the error.
    ///
    /// What that looks like in practice, from Steam's bootstrapper:
    ///
    /// ```
    /// Download failed: http error 0 (cdn.steamstatic.com/client/steam_client_win32)
    /// Error: Steam needs to be online to update.
    /// ```
    ///
    /// Which reads like a network problem, and isn't one.
    enum Certificates {
        /// Where Windows keeps machine-wide trusted roots.
        private static let rootStoreKey = #"HKEY_LOCAL_MACHINE\Software\Microsoft\SystemCertificates\Root\Certificates"#

        /// Whether this container already has a root store worth trusting.
        ///
        /// Read from `system.reg` rather than by asking wine: this runs before launch, on
        /// every launch, and spawning a process to answer it would be the expensive part.
        static func areInstalled(inContainerAtURL containerURL: URL) -> Bool {
            guard let registry = try? String(
                contentsOf: containerURL.appending(path: "system.reg"), encoding: .utf8
            ) else { return false }

            // The store's own key exists in an empty prefix; a certificate *under* it is the
            // thing that means anything.
            return registry.contains(#"SystemCertificates\\Root\\Certificates\\"#)
        }

        /// Imports the Mac's trusted roots into a container, unless it already has some.
        static func installIfMissing(inContainerAtURL containerURL: URL) async throws {
            guard !areInstalled(inContainerAtURL: containerURL) else { return }
            try await install(inContainerAtURL: containerURL)
        }

        static func install(inContainerAtURL containerURL: URL) async throws {
            let certificates = try hostRootCertificates()
            guard !certificates.isEmpty else {
                Wine.log.warning("The system trust store returned no anchors; leaving the container's root store empty.")
                return
            }

            let temporaryDirectory = containerURL.appending(path: "drive_c/windows/temp")
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let fileName = "\(Branding.name.lowercased())-root-certificates.reg"
            try registryFile(for: certificates).write(
                to: temporaryDirectory.appending(path: fileName), atomically: true, encoding: .utf8
            )

            // Through wine, not by editing `system.reg`. A live wineserver holds the registry
            // in memory and writes it back out when it exits, so a file edited underneath it
            // is silently discarded — which is a confusing way to lose an hour.
            let process: Process = .init()
            process.arguments = ["regedit", "/S", #"C:\windows\temp\\#(fileName)"#]
            Wine.transformProcess(process, containerURL: containerURL)

            let result = try await process.runWrapped()

            // Written next to the container rather than only to the unified log: when this
            // goes wrong it goes wrong silently, and the caller uses `try?`.
            let transcript = """
                arguments: \(process.arguments ?? [])
                stdout: \(result.standardOutput ?? "")
                stderr: \(result.standardError ?? "")
                certificates: \(certificates.count)
                """
            try? transcript.write(
                to: containerURL.appending(path: "\(Branding.name.lowercased())-certificate-import.log"),
                atomically: true, encoding: .utf8
            )

            Wine.log.notice("""
                Imported \(certificates.count, privacy: .public) root certificates into \
                \(containerURL.lastPathComponent, privacy: .public). \
                \(result.standardError ?? "", privacy: .public)
                """)
        }

        /// The Mac's trusted root certificates, as DER.
        private static func hostRootCertificates() throws -> [Data] {
            var anchors: CFArray?
            let status = SecTrustCopyAnchorCertificates(&anchors)
            guard status == errSecSuccess, let anchors = anchors as? [SecCertificate] else {
                throw NSError(domain: NSOSStatusErrorDomain, code: .init(status))
            }

            return anchors.map { SecCertificateCopyData($0) as Data }
        }

        /// A `REGEDIT4` file placing each certificate under its SHA-1 thumbprint.
        ///
        /// The value is not the certificate itself but a serialised certificate: a property
        /// list, of which the only entry that matters is `CERT_CERT_PROP_ID` (0x20) carrying
        /// the DER. Both Windows and Wine read this shape.
        private static func registryFile(for certificates: [Data]) -> String {
            var contents = "REGEDIT4\n"

            for certificate in certificates {
                let thumbprint = Insecure.SHA1.hash(data: certificate)
                    .map { String(format: "%02X", $0) }
                    .joined()

                var blob = Data([0x20, 0x00, 0x00, 0x00,   // CERT_CERT_PROP_ID
                                 0x01, 0x00, 0x00, 0x00])  // unknown, always 1
                blob.append(contentsOf: withUnsafeBytes(of: UInt32(certificate.count).littleEndian, Array.init))
                blob.append(certificate)

                // Wrapped at the width regedit files traditionally use. Wine copes with one
                // enormous line, but not every tool that might read this file back does.
                let bytes = blob.map { String(format: "%02x", $0) }
                let wrapped = stride(from: 0, to: bytes.count, by: 25)
                    .map { bytes[$0..<min($0 + 25, bytes.count)].joined(separator: ",") }
                    .joined(separator: ",\\\n  ")

                contents += "\n[\(rootStoreKey)\\\(thumbprint)]\n\"Blob\"=hex:\(wrapped)\n"
            }

            return contents
        }
    }
}
