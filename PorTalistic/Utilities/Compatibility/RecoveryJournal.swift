//
//  RecoveryJournal.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 What has been tried for each game, and what turned out to work.

 The loop needs memory or it is not a loop. Without this, a game that crashes twice gets the
 same remedy applied twice, a ladder walks its first rung forever, and a configuration that
 took four attempts to find is indistinguishable from the three that failed.

 # The learned entry is a manifest entry

 What the app works out for a game is stored as a `CompatibilityDatabase.Entry` — the same type
 the curated list and the fetched manifest are made of. That is deliberate and it is the whole
 shape of the feature: a fix found on one machine is already in the format that publishes it to
 everyone, so closing the loop is a matter of sending the entry rather than of translating it.

 # Where it sits

 Below the person and below the manifest. A setting somebody chose by hand is never
 overridden by something the app inferred, and a curated entry — written by someone who read
 the logs — beats a local guess on any field they both have an opinion about. The learned entry
 keeps the fields the manifest is silent on, so a partial curated answer doesn't discard a
 local fix that goes further.
 */
struct RecoveryJournal: Codable, Equatable {
    static let log: Logger = .custom(category: "RecoveryJournal")

    /// Keyed by storefront-qualified id, `"gog:1164193173"` — the same key the manifest uses,
    /// so a record and an entry can always be matched up.
    var games: [String: GameRecord] = .init()

    struct GameRecord: Codable, Equatable {
        /// Newest last. Bounded — see ``trimmed()``.
        var attempts: [Attempt] = .init()

        /// What the app has worked out for this game, in the shape the manifest publishes.
        var learned: CompatibilityDatabase.Entry?

        /// A configuration that produced a long clean session.
        ///
        /// Two things follow from this being set. Nothing is changed after a single crash any
        /// more — see `RecoveryPolicy.failuresBeforeActingOnAConfirmedGame` — and the entry is
        /// worth sending, because it is a fix rather than an attempt.
        var confirmed: Bool = false

        /// Ladder steps already walked. Never walked twice, whether they helped or not: a step
        /// that didn't help is not going to help the second time, and a step that did help is
        /// already in `learned`.
        var stepsTried: Set<String> = .init()

        /// Diagnosed faults already acted on. A signature firing again after its own remedy
        /// was applied means the remedy was wrong, and the ladder takes over.
        var signaturesActedOn: Set<String> = .init()

        /// Whether the exhausted-every-option report has been sent, so it is sent once.
        var reportedExhausted: Bool = false

        /// Whether there is nothing left to try for this game.
        ///
        /// Separate from ``reportedExhausted``, which is about a report having been queued.
        /// This is the state the person is shown: the app has run out of configurations, and
        /// the page that explains how a game runs says so rather than leaving somebody to
        /// notice that nothing changes any more. Cleared the moment something *is* changed —
        /// a rung that became applicable because a runtime was installed, or a diagnosis.
        var hasExhaustedOptions: Bool = false

        /// Whether the confirmed fix has been sent.
        var reportedFix: Bool = false

        /// Consecutive failures since the last clean or inconclusive session.
        var consecutiveFailures: Int = 0

        /// Consecutive sessions too short to have been sessions, on a game that has never run
        /// cleanly.
        ///
        /// The counter that makes ``LaunchVerdict/wouldNotStay`` possible. One short session is
        /// somebody changing their mind; this is how the loop notices that it is the fourth.
        /// Reset by anything that isn't one, so it only ever counts a run of them.
        var consecutiveShortSessions: Int = 0

        /// How many failures it takes before anything is changed for this game.
        var failuresBeforeActing: Int {
            confirmed
                ? RecoveryPolicy.failuresBeforeActingOnAConfirmedGame
                : RecoveryPolicy.failuresBeforeActing
        }

        /// Decoded field by field, each falling back to its default.
        ///
        /// The synthesised decoder refuses a file that is missing any non-optional key — so
        /// *adding* a property here would have thrown away every journal already written, and
        /// silently: ``RecoveryJournal/load()`` discards what it cannot decode, which would
        /// have cost every learned entry and every rung already walked on every machine that
        /// updated. `consecutiveShortSessions` was exactly that addition.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            attempts = try container.decodeIfPresent([Forgiving<Attempt>].self, forKey: .attempts)?
                .compactMap(\.value) ?? []
            learned = try container.decodeIfPresent(CompatibilityDatabase.Entry.self, forKey: .learned)
            confirmed = try container.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
            stepsTried = try container.decodeIfPresent(Set<String>.self, forKey: .stepsTried) ?? []
            signaturesActedOn = try container.decodeIfPresent(Set<String>.self, forKey: .signaturesActedOn) ?? []
            reportedExhausted = try container.decodeIfPresent(Bool.self, forKey: .reportedExhausted) ?? false
            reportedFix = try container.decodeIfPresent(Bool.self, forKey: .reportedFix) ?? false
            consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
            consecutiveShortSessions = try container.decodeIfPresent(Int.self, forKey: .consecutiveShortSessions) ?? 0
            hasExhaustedOptions = try container.decodeIfPresent(Bool.self, forKey: .hasExhaustedOptions) ?? false
        }

        /// Declaring an initialiser removes the memberwise one, and `.init()` is how every
        /// caller makes a record for a game with no history.
        init() {}

        /// Keep the history readable and the file small. Twenty is far more than any
        /// diagnosis reads, and the counters that matter are kept separately for that reason.
        mutating func trimmed() {
            if attempts.count > 20 {
                attempts.removeFirst(attempts.count - 20)
            }
        }
    }

    /// A value that decodes to nothing rather than taking the file down with it.
    ///
    /// The history is the least valuable thing in this file and the most likely to break it. An
    /// `Attempt` carries a `LaunchVerdict`, so a journal written by a build that knows a verdict
    /// this one doesn't — which is what happens the moment a verdict is added, and one just was
    /// — fails to decode; `load()` discards what it cannot decode, and the learned entry that
    /// took four crashes to find goes with it. An attempt nobody can read is worth exactly as
    /// much as a forgotten one.
    /// Decoding only: the journal is written from `[Attempt]` itself, so nothing here ever
    /// has to put one back.
    struct Forgiving<Wrapped: Decodable>: Decodable {
        let value: Wrapped?

        init(from decoder: any Decoder) throws {
            value = try? Wrapped(from: decoder)
        }
    }

    /// One launch and what came of it.
    struct Attempt: Codable, Equatable {
        let at: Date
        let runtimeID: String
        let settings: RuntimeProfile.SettingsOverride
        let verdict: LaunchVerdict
        let ranFor: TimeInterval

        /// The two facts the verdict was read from. Without them a journal cannot say which
        /// kind of silence a launch was — nothing ever appeared, or the app stopped watching a
        /// game that was still going — and `stillRunning` now decides whether a launch counts
        /// at all. Optional because journals written before this one exist.
        var appeared: Bool?
        var stillRunning: Bool?

        /// The diagnosed fault, when there was one.
        var signature: String?

        /// What was changed *because* of this attempt, in the person's words. Nil when
        /// nothing was — which is most of them.
        var changed: String?
    }

    // MARK: - Reading and writing

    static var url: URL? {
        Bundle.appHome?.appending(path: "Compatibility/recovery.json")
    }

    /// The journal on disk, or an empty one.
    ///
    /// A corrupt file is discarded rather than repaired: this is derived knowledge, the worst
    /// its loss costs is rediscovering a fix, and refusing to launch games because a JSON file
    /// went bad would be far worse than forgetting.
    static func load() -> RecoveryJournal {
        guard let url, let data = try? Data(contentsOf: url) else { return .init() }

        do {
            return try JSONDecoder().decode(RecoveryJournal.self, from: data)
        } catch {
            log.warning("The recovery journal didn't decode; starting a new one: \(error.localizedDescription, privacy: .public)")
            return .init()
        }
    }

    /// The journal the app is using.
    ///
    /// Read from disk on first access and kept, because `Provisioner.resolveProfile` is called
    /// once per installed game at every launch and a file read per game there is exactly the
    /// kind of startup cost this codebase has already paid for once.
    ///
    /// `nonisolated(unsafe)` for the same reason as `RuntimeRelease.catalogue`: it is written
    /// once at startup and once per crash, both far from anything reading it, and the
    /// alternative is a lock on a path that runs before any game does.
    private static let currentLock: NSLock = .init()
    nonisolated(unsafe) private static var stored: RecoveryJournal = .load()

    static var current: RecoveryJournal {
        get { currentLock.withLock { stored } }
        set { currentLock.withLock { stored = newValue } }
    }

    func save() {
        guard let url = Self.url else { return }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)

            let encoder: JSONEncoder = .init()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            try encoder.encode(self).write(to: url, options: .atomic)
            Self.current = self
        } catch {
            Self.log.error("Couldn't write the recovery journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Keys

    /// The storefront-qualified key for a game, matching the manifest's `ids`.
    static func key(for facts: Provisioner.GameFacts) -> String? {
        guard let storefront = facts.storefront else { return nil }
        return "\(storefront.manifestName):\(facts.id)"
    }
}
