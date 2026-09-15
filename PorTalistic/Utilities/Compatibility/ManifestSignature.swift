//
//  ManifestSignature.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 15/9/2026.
//

// Copyright © 2026 Michael Stoian

import Foundation
import CryptoKit
import OSLog

/**
 Who is allowed to tell this app what to download.

 The compatibility manifest decides which Wine builds exist and where their tarballs come
 from. Every payload is digest-pinned and every id that shipped in the app is held to the
 bytes it shipped with, so a manifest cannot re-point a runtime the app already knows. What
 it *could* do is introduce a **new** runtime id, and that was trusted on the strength of
 "it came from raw.githubusercontent.com over TLS" — which is to say, on nobody having
 write access to the repository they shouldn't have, and on the repository being the one the
 URL names for the whole life of the app.

 That is a thin reason to execute a tarball, and it gets thinner the moment the repository
 is public and accepting contributions, which is the point of publishing it.

 So the manifest is signed. A detached Ed25519 signature sits beside it as
 `manifest.json.sig`, the public half is compiled into the app, and a manifest whose
 signature doesn't verify over its exact bytes is discarded before it is even parsed. The
 key that matters is the one in the binary: a key fetched from anywhere would be replaceable
 by whoever could replace the manifest, which is the thing being defended against.

 # Fail closed

 No key, no signature, or a signature that doesn't verify, all mean the same thing: the
 fetched manifest is ignored and the catalogue the app shipped with is used instead. That is
 a working app with slightly older data, which is the right way to fail — the alternative
 trades "out of date" for "runs a tarball someone else chose".

 # Signing a manifest

 `Compatibility/sign-manifest.swift` in the repository does it, and generates the key pair
 on first use. The private half never belongs in the repository.
 */
enum ManifestSignature {
    static let log: Logger = .custom(category: "ManifestSignature")

    /// The Ed25519 public key manifests must be signed with, base64, 32 bytes raw.
    ///
    /// `nil` means no manifest is trusted at all — see *Fail closed* above. Set it to the
    /// key `sign-manifest.swift --generate-key` prints. It is a public key: it belongs in
    /// the repository, in this file, and its whole security value comes from being compiled
    /// into the binary rather than fetched.
    ///
    /// - Note: rotating it invalidates every manifest signed with the old key, which is the
    ///   point of rotating it. Older app versions keep trusting the old key, so a rotation
    ///   wants both signatures published or a version of the app nobody is running any more.
    static let trustedPublicKey: String? = nil

    /// Where the detached signature sits, relative to the manifest.
    static let signatureExtension: String = "sig"

    /// Whether a key is compiled in at all.
    static var isConfigured: Bool { trustedPublicKey != nil }

    /// Says once per launch that nothing fetched is trusted, so the reason is in the log when
    /// somebody wonders why a corrected entry never arrived.
    static func logMissingKey() {
        guard !hasLoggedMissingKey else { return }
        hasLoggedMissingKey = true

        log.notice("No manifest signing key is compiled in, so no fetched compatibility manifest is trusted; using what shipped with the app.")
    }

    private nonisolated(unsafe) static var hasLoggedMissingKey: Bool = false

    /// Whether `signature` is this key's signature over exactly these bytes.
    ///
    /// Takes the raw manifest bytes rather than a decoded manifest on purpose: the signature
    /// covers the file, so anything that re-encodes it first — a round-trip through
    /// `JSONDecoder` and back, a whitespace normalisation, a key reordering — is verifying
    /// something other than what was signed.
    static func verify(_ data: Data, signature: Data) -> Bool {
        guard let trustedPublicKey else {
            logMissingKey()
            return false
        }

        guard let keyBytes = Data(base64Encoded: trustedPublicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            log.error("The compiled-in manifest signing key isn't a valid Ed25519 public key.")
            return false
        }

        guard key.isValidSignature(signature, for: data) else {
            log.error("A compatibility manifest failed signature verification and was discarded.")
            return false
        }

        return true
    }

    /// The signature bytes out of a `.sig` file's contents.
    ///
    /// Base64 with whatever whitespace a text editor or a shell redirect left behind, because
    /// a signature people can copy and paste is worth more than four saved bytes.
    static func decodeSignature(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        return Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
