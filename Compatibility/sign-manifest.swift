#!/usr/bin/env swift

//
//  sign-manifest.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 15/9/2026.
//

// Copyright © 2026 Michael Stoian

//  Signs Compatibility/manifest.json so the app will trust it.
//
//      swift Compatibility/sign-manifest.swift --generate-key   # once, ever
//      swift Compatibility/sign-manifest.swift                  # after every edit
//
//  The app discards any manifest whose signature doesn't verify against the public key
//  compiled into it — see PorTalistic/Utilities/Compatibility/ManifestSignature.swift. The
//  manifest decides which Wine builds exist and where their tarballs are fetched from, so
//  the signature is what stands between "the repository is public and takes pull requests"
//  and "anyone who lands a commit chooses what gets executed".
//
//  CryptoKit rather than openssl: it ships with macOS, and the Ed25519 support in the
//  openssl on a Mac depends on which openssl it is.

import Foundation
import CryptoKit

// MARK: - Where things live

let arguments = Array(CommandLine.arguments.dropFirst())

/// Outside the repository, and outside anything the app or a build script touches.
///
/// A signing key in a working tree is a signing key that gets committed. `~/.portalistic` is
/// not backed up by anything on its own, so back it up somewhere: losing it doesn't break any
/// app that is already installed, but it does mean no new manifest can ever be published to
/// them, and a replacement key only reaches people who update the app.
let keyDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".portalistic")
let keyURL = keyDirectory.appending(path: "manifest-signing-key")

/// Resolved from this script rather than the working directory, so it signs the manifest in
/// its own checkout wherever it is run from.
let manifestURL: URL = {
    if let path = arguments.first(where: { !$0.hasPrefix("--") }) {
        return URL(filePath: path)
    }

    return URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "manifest.json")
}()

let signatureURL = manifestURL.appendingPathExtension("sig")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func report(_ message: String) {
    print(message)
}

// MARK: - Keys

func publicKeyLine(for key: Curve25519.Signing.PrivateKey) -> String {
    """

    Compile this into the app, in ManifestSignature.swift:

        static let trustedPublicKey: String? = "\(key.publicKey.rawRepresentation.base64EncodedString())"

    """
}

func generateKey() -> Never {
    if FileManager.default.fileExists(atPath: keyURL.path) {
        fail("""
            a signing key already exists at \(keyURL.path).
            Refusing to overwrite it — every manifest signed with it would stop verifying, and
            every copy of the app already installed would reject anything signed by the
            replacement. Move it aside by hand if that is really what you want.
            """)
    }

    let key = Curve25519.Signing.PrivateKey()

    do {
        try FileManager.default.createDirectory(at: keyDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        try key.rawRepresentation.base64EncodedString().write(to: keyURL,
                                                              atomically: true,
                                                              encoding: .utf8)

        // Set after the write: `write(to:atomically:)` replaces the file, and the replacement
        // gets the default mode rather than whatever the old one had.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    } catch {
        fail("couldn't write the key to \(keyURL.path): \(error.localizedDescription)")
    }

    report("Wrote a new signing key to \(keyURL.path) (mode 600). Back it up; it is not in the repository and cannot be recovered.")
    report(publicKeyLine(for: key))
    exit(0)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let encoded = try? String(contentsOf: keyURL, encoding: .utf8) else {
        fail("""
            no signing key at \(keyURL.path).
            Run this with --generate-key first. If you have one somewhere else, put it there.
            """)
    }

    guard let bytes = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else {
        fail("the file at \(keyURL.path) isn't a base64 Ed25519 private key")
    }

    return key
}

// MARK: - Signing

if arguments.contains("--generate-key") { generateKey() }

if arguments.contains("--help") || arguments.contains("-h") {
    report("""
        usage: swift sign-manifest.swift [--generate-key] [--print-key] [manifest.json]

          --generate-key   create ~/.portalistic/manifest-signing-key and print its public half
          --print-key      print the public half of the existing key and stop
          manifest.json    what to sign; defaults to the manifest.json beside this script
        """)
    exit(0)
}

let key = loadKey()

if arguments.contains("--print-key") {
    report(publicKeyLine(for: key))
    exit(0)
}

guard let manifest = try? Data(contentsOf: manifestURL) else {
    fail("couldn't read \(manifestURL.path)")
}

// Parsed only to catch a broken edit before it is signed. The signature covers the bytes as
// they are, not a re-encoding of them, so nothing here is written back.
guard (try? JSONSerialization.jsonObject(with: manifest)) != nil else {
    fail("\(manifestURL.lastPathComponent) isn't valid JSON — fix it before signing it")
}

guard let signature = try? key.signature(for: manifest) else {
    fail("signing failed")
}

do {
    try signature.base64EncodedString().appending("\n").write(to: signatureURL,
                                                              atomically: true,
                                                              encoding: .utf8)
} catch {
    fail("couldn't write \(signatureURL.path): \(error.localizedDescription)")
}

report("""
    Signed \(manifestURL.lastPathComponent) (\(manifest.count) bytes).
    Wrote \(signatureURL.lastPathComponent). Commit both — the app fetches them side by side.
    """)
