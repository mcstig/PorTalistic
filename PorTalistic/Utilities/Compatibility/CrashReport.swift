//
//  CrashReport.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 What gets sent when a game can't be fixed here, and what never does.

 The value of this feature is that a fault nobody has seen becomes a fault somebody can fix, and
 that needs the fault to leave the machine. So this is a wire format, and every wire format that
 carries a log is one mistake away from carrying a credential.

 That is not hypothetical here. BioShock Remastered writes its 2K Coretech `Authorization:
 Bearer` token into stderr, and stderr is the transcript: account id, session id, and the
 coordinates of the city it resolved the player to, sitting in a file whose entire purpose is to
 be handed to somebody else. A full log is therefore never sent, however convenient that would
 be for diagnosis.

 # What is in a report

 The smallest thing that makes a fault identifiable and reproducible: versions, the Mac, the
 game, the runtime, the settings that were in effect, the diagnosis or its absence, and the
 handful of transcript lines that matched a fault marker. Nothing else. Twelve lines of evidence
 is not a diagnostic luxury — it is how the faults in `CrashDiagnosis` were each found.

 # What is never in one

 No full transcript. No username, and no path that contains one — the home directory is
 rewritten to `~` and the short username to `<user>`, because a Wine log is almost entirely
 paths. No account identifier from any storefront, no bearer token or JWT (stripped by
 `Wine.redactSecrets(in:)` on the way in, belt and braces on top of the line-matching). No
 hardware serial, and no identifier derived from the machine: the install id is a random UUID
 written once into the app's own support directory, so it links one install's reports together
 and links nothing to a person or a device.

 # Consent

 Nothing here transmits. This type builds a report and can show it; sending is
 `CrashReportSubmission`'s job and is off until somebody turns it on, having seen what a report
 looks like. That ordering is not politeness — a person cannot consent to sending something they
 have not been shown.
 */
struct CrashReport: Codable, Equatable {
    /// Incremented when the shape changes incompatibly, so the receiving end can refuse a
    /// version it doesn't understand rather than half-read it.
    var formatVersion: Int = 1

    /// Why this report exists.
    enum Kind: String, Codable, Equatable {
        /// Crashed, and nothing in the transcript was recognised. The interesting one: these
        /// are what turn into new signatures.
        case unrecognisedCrash

        /// Every configuration the app knows how to try has been tried and the game still
        /// fails. The end of the automatic process, and the point at which a person has to
        /// look at it.
        case optionsExhausted

        /// A configuration the app found now works. Sent because a fix nobody hears about
        /// helps one machine, and this one can become a manifest entry for everybody.
        case confirmedFix
    }

    let kind: Kind

    /// A random UUID per install. Not derived from the machine — see the type's note.
    let installID: String

    let appVersion: String
    let systemVersion: String

    /// `Mac15,3`. The model matters because a fault can be specific to a GPU family and this
    /// is the coarsest thing that says which one.
    let model: String

    let game: GameDescriptor

    let runtimeID: String
    let runtimeVersion: String?

    /// The settings the failing launch actually ran with.
    let settings: RuntimeProfile.SettingsOverride
    let winetricks: [String]

    let verdict: LaunchVerdict
    let ranForSeconds: Int

    /// The diagnosed fault, or nil when nothing matched — which is the point of the report.
    let signature: String?

    /// Ladder rungs already walked, so a reader knows what has been ruled out.
    let stepsTried: [String]

    /// Redacted, path-scrubbed, and capped. See ``evidence(from:)``.
    let evidence: [String]

    /// Present on a `confirmedFix`: the entry that worked, ready to be reviewed and published.
    var learned: CompatibilityDatabase.Entry?

    struct GameDescriptor: Codable, Equatable {
        let storefront: String
        let id: String
        let title: String
    }

    // MARK: - Building one

    static let log: Logger = .custom(category: "CrashReport")

    /// At most this many lines of evidence, and at most this many characters per line.
    ///
    /// A Wine fault line is under two hundred characters; anything far longer is a game
    /// printing a data structure, which is not evidence and is where an unredacted secret
    /// would hide.
    static let evidenceLineLimit: Int = 12
    static let evidenceLineLength: Int = 400

    /// The evidence lines a report may carry, cleaned.
    ///
    /// Three passes, in this order, because each one can expose what the next one removes:
    /// credentials by pattern, then paths, then length. Truncating first could cut a JWT in
    /// half and leave the half that still identifies a session.
    static func evidence(from lines: [String]) -> [String] {
        lines.prefix(evidenceLineLimit).map { line in
            var cleaned = Wine.redactSecrets(in: line)
            cleaned = scrubPaths(in: cleaned)

            if cleaned.count > evidenceLineLength {
                cleaned = String(cleaned.prefix(evidenceLineLength)) + "…"
            }

            return cleaned
        }
    }

    /// Rewrite anything that names the person.
    ///
    /// A Wine transcript is mostly paths, and a macOS path contains the account's short name in
    /// almost every case. `NSFullUserName()` as well, because a game that writes a save
    /// directory often writes the display name with it.
    static func scrubPaths(in text: String) -> String {
        var scrubbed = text

        let home = NSHomeDirectory()
        if !home.isEmpty {
            scrubbed = scrubbed.replacingOccurrences(of: home, with: "~")
        }

        for name in [NSUserName(), NSFullUserName()] where name.count > 2 {
            scrubbed = scrubbed.replacingOccurrences(of: name, with: "<user>")
        }

        // Wine's own prefix user, which is a fixed name rather than the person's — left alone
        // deliberately, since `C:\users\crossover\…` is the same on every machine and removing
        // it would make a path unrecognisable for no gain.
        return scrubbed
    }

    // MARK: - Identity

    /// A stable, meaningless identifier for this install.
    ///
    /// Written once and read thereafter. Random rather than derived: a hardware identifier
    /// would make every report linkable to a machine forever and is not needed for anything —
    /// all this has to do is let two reports be recognised as coming from the same install, so
    /// a crash loop isn't counted as a hundred people with the same problem.
    static var installID: String {
        guard let url = Bundle.appHome?.appending(path: "Compatibility/install-id") else {
            return "unknown"
        }

        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        let fresh = UUID().uuidString

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(fresh.utf8).write(to: url, options: .atomic)
        } catch {
            log.warning("Couldn't persist the install id: \(error.localizedDescription, privacy: .public)")
        }

        return fresh
    }

    /// `Mac15,3`, or the empty string if it can't be read.
    ///
    /// The model, which is public and shared by every unit of that model. Never the serial, and
    /// never `IOPlatformUUID`, both of which identify one specific machine.
    static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }

        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "" }

        // Trailing NUL from sysctl, which would otherwise end up inside the string.
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    // MARK: - Reviewing one

    /// The report as the person would read it before agreeing to send anything.
    ///
    /// Pretty-printed and key-sorted so that two reports of the same fault look the same, and
    /// so the thing shown in the interface is byte-for-byte the thing that would be sent.
    var reviewableText: String {
        let encoder: JSONEncoder = .init()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return String(localized: "This report couldn't be prepared for review, so nothing will be sent.")
        }

        return text
    }

    /// What two reports being "the same fault" means.
    ///
    /// The receiving end groups on this, and the app refuses to send the same one twice. Game,
    /// diagnosis and runtime — not the evidence, which varies by address and by run, and not
    /// the settings, which change every time the ladder moves.
    var deduplicationKey: String {
        [kind.rawValue, game.storefront, game.id, signature ?? "unrecognised", runtimeID]
            .joined(separator: "|")
    }
}
