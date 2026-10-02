//
//  RecoveryCoordinator.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Observation
import OSLog
import UserNotifications

/**
 The loop: a game exits, the transcript is read, and something changes for next time.

 Everything this calls is a pure function over values — `CrashDiagnosis`, `LaunchVerdict.of`,
 `RecoveryPlanner.plan` — and everything with a side effect is here. That split is deliberate:
 the decisions are the part that has to be right, and they are the part that can be tested
 without a Mac, a game, or a crash.

 # The order matters

 The attempt is journalled *before* anything is changed. A crash that happens while reacting to
 the previous crash would otherwise be invisible, and the ladder would walk the same rung
 forever having never recorded walking it.

 # Nothing is changed during a launch

 Every change lands in the journal and takes effect the *next* time the game starts. The
 alternative — reconfiguring a container while a `wineserver` is still serving it — is the
 failure this codebase already learned once: a settings revert applied mid-startup is what made
 Horizon Chase Turbo open in a small window three separate times.
 */
@Observable @MainActor
final class RecoveryCoordinator {
    static let shared: RecoveryCoordinator = .init()

    static let log: Logger = .custom(category: "RecoveryCoordinator")

    /// The last thing that happened, for an interface that wants to show it.
    ///
    /// A notification is fire-and-forget and a person who missed it has no way back to what it
    /// said, so the notice is kept as well.
    private(set) var lastNotice: Notice?

    /// Bumped whenever a launch has been judged and the journal written.
    ///
    /// What a page watches to know that what it is showing is out of date. The game's page
    /// resolves a profile once, and the recovery loop rewrites what that profile is made of
    /// *after* a game exits — so the change the app had just decided only appeared if you left
    /// the page and came back. Not the notice, which isn't posted for every outcome, and not
    /// the journal itself, which isn't observable: a counter that says "ask again".
    private(set) var journalRevision: Int = 0

    struct Notice: Equatable, Identifiable {
        let id: UUID = .init()
        let gameTitle: String
        let verdict: LaunchVerdict
        /// What was diagnosed, in the person's words. Nil when nothing was recognised.
        let diagnosis: String?
        /// What will be different next run. Nil when nothing changed.
        let change: String?
        /// Whether every option has now been tried.
        let exhausted: Bool
    }

    private init() {}

    // MARK: - The entry point

    /**
     A launch has finished. Work out what it meant and what to do about it.

     - Parameters:
       - facts: what ran.
       - outcome: what the supervision observed.
       - transcriptURL: the launch log. Read, never moved — rotation happens at the start of
         the next launch, which is the only moment nothing is still appending to it.
       - containerURL: the prefix it ran in, for the remedies that are an action rather than a
         setting.
       - runtimeID: which Wine build, for the journal and the report.
       - applied: the settings overlay the launch ran with.
       - effective: those settings with the container's own values filled in where the overlay
         was silent, so a ladder rung isn't spent setting something to what it already was.
       - winetricks: the verbs the profile asked for.
       - backendInEffect: which Direct3D implementation the game actually rendered through, so
         the ladder never offers it the one it is already using.
     */
    func launchFinished(facts: Provisioner.GameFacts, // swiftlint:disable:this function_parameter_count
                        outcome: LaunchOutcome,
                        transcriptURL: URL?,
                        containerURL: URL?,
                        runtimeID: String,
                        applied: RuntimeProfile.SettingsOverride,
                        effective: RuntimeProfile.SettingsOverride,
                        winetricks: [String],
                        backendInEffect: RuntimeProfile.GraphicsBackend?,
                        requirements: RuntimeProfile.Requirements,
                        usesDirect3DEleven: Bool) async {
        guard let key = RecoveryJournal.key(for: facts) else { return }

        let transcript = transcriptURL.flatMap(Self.readTranscript) ?? ""
        let faults = CrashDiagnosis.faultLines(in: transcript)

        var journal = RecoveryJournal.load()
        var record = journal.games[key] ?? .init()

        // Counted before the verdict is read, because this launch means something different
        // given the ones before it: a game that has never run properly and is gone again
        // within seconds, every single time, is not somebody changing their mind. What counts
        // and what resets it is ``RecoveryPolicy/shortSessionsInARow(following:ranFor:confirmed:faults:)``.
        record.consecutiveShortSessions = RecoveryPolicy.shortSessionsInARow(
            following: record.consecutiveShortSessions,
            ranFor: outcome.ranFor,
            confirmed: record.confirmed,
            faults: faults,
            stillRunning: outcome.stillRunning
        )

        let verdict = LaunchVerdict.of(outcome,
                                       faultLines: faults,
                                       shortSessionsInARow: record.consecutiveShortSessions)

        let diagnosis = verdict.isFailure
            ? CrashDiagnosis.diagnose(transcript: transcript, applied: applied)
            : nil

        // Journalled first — see the type's note.
        record.attempts.append(.init(at: .now,
                                     runtimeID: runtimeID,
                                     settings: applied,
                                     verdict: verdict,
                                     ranFor: outcome.ranFor,
                                     appeared: outcome.appeared,
                                     stillRunning: outcome.stillRunning,
                                     signature: diagnosis?.signature))
        record.trimmed()

        switch verdict {
        case .clean:
            record.consecutiveFailures = 0

            // Cleared here as well as when something is changed, because changes only happen
            // after failures: without this, a game that ran out of options once carries the
            // "nothing else I can try" warning on its page through every good session it has
            // from then on — including the one where it finally works.
            record.hasExhaustedOptions = false
            await confirm(&record, key: key, facts: facts, runtimeID: runtimeID,
                          applied: applied, winetricks: winetricks, outcome: outcome)

        case .inconclusive:
            // Somebody opened a game and changed their mind. Not evidence of anything, and
            // deliberately not a reason to reset the failure count either — a game that
            // crashes, then gets a ten-second look, then crashes again has crashed twice.
            break

        case .crashed, .neverStarted, .wouldNotStay:
            record.consecutiveFailures += 1

            await react(&record,
                        key: key,
                        facts: facts,
                        verdict: verdict,
                        diagnosis: diagnosis,
                        faults: faults,
                        containerURL: containerURL,
                        runtimeID: runtimeID,
                        applied: applied,
                        effective: effective,
                        winetricks: winetricks,
                        outcome: outcome,
                        backendInEffect: backendInEffect,
                        requirements: requirements,
                        usesDirect3DEleven: usesDirect3DEleven)
        }

        journal.games[key] = record
        journal.save()

        journalRevision += 1
    }

    // MARK: - A configuration that works

    private func confirm(_ record: inout RecoveryJournal.GameRecord,
                         key: String,
                         facts: Provisioner.GameFacts,
                         runtimeID: String,
                         applied: RuntimeProfile.SettingsOverride,
                         winetricks: [String],
                         outcome: LaunchOutcome) async {
        // Only meaningful if the app changed something. A game that always worked has nothing
        // to confirm and nothing worth telling anybody.
        guard let learned = record.learned, !record.confirmed else { return }

        record.confirmed = true
        Self.log.notice("\(key, privacy: .public) ran clean for \(Int(outcome.ranFor), privacy: .public)s on a learned configuration")

        if !record.reportedFix {
            record.reportedFix = true

            var report = Self.report(kind: .confirmedFix,
                                     facts: facts,
                                     runtimeID: runtimeID,
                                     settings: applied,
                                     winetricks: winetricks,
                                     verdict: .clean,
                                     outcome: outcome,
                                     signature: record.attempts.last(where: { $0.signature != nil })?.signature,
                                     stepsTried: record.stepsTried.sorted(),
                                     evidence: [])
            report.learned = learned

            CrashReportStore.queue(report)
        }

        await notify(.init(gameTitle: facts.title,
                           verdict: .clean,
                           diagnosis: nil,
                           change: String(localized: "The configuration PorTalistic worked out for this game now runs cleanly."),
                           exhausted: false))
    }

    // MARK: - A configuration that doesn't

    // Everything a verdict is made from, named, rather than a bag the reader has to open.
    private func react(_ record: inout RecoveryJournal.GameRecord, // swiftlint:disable:this function_parameter_count
                       key: String,
                       facts: Provisioner.GameFacts,
                       verdict: LaunchVerdict,
                       diagnosis: CrashDiagnosis.Finding?,
                       faults: [String],
                       containerURL: URL?,
                       runtimeID: String,
                       applied: RuntimeProfile.SettingsOverride,
                       effective: RuntimeProfile.SettingsOverride,
                       winetricks: [String],
                       outcome: LaunchOutcome,
                       backendInEffect: RuntimeProfile.GraphicsBackend?,
                       requirements: RuntimeProfile.Requirements,
                       usesDirect3DEleven: Bool) async {
        // What this Mac can render Direct3D with at all, so nothing offers to move a game to
        // an implementation no installed build has. Off the main actor, because answering it
        // means reading every runtime's directory.
        let backendsAvailable = await Task.detached { Runtime.installedBackends() }.value

        let plan = RecoveryPlanner.plan(for: record,
                                        verdict: verdict,
                                        diagnosis: diagnosis,
                                        effective: effective,
                                        backendInEffect: backendInEffect,
                                        backendsAvailable: backendsAvailable,
                                        requirements: requirements,
                                        usesDirect3DEleven: usesDirect3DEleven)

        // A crash nobody recognises is the report worth having: it is what turns into the next
        // signature. Sent whatever the plan is, because the ladder finding a workaround by
        // trial doesn't explain the fault.
        if diagnosis == nil {
            CrashReportStore.queue(Self.report(kind: .unrecognisedCrash,
                                               facts: facts,
                                               runtimeID: runtimeID,
                                               settings: applied,
                                               winetricks: winetricks,
                                               verdict: verdict,
                                               outcome: outcome,
                                               signature: nil,
                                               stepsTried: record.stepsTried.sorted(),
                                               evidence: CrashReport.evidence(from: faults)))
        }

        switch plan {
        case .wait(let failures, let needed):
            Self.log.notice("\(key, privacy: .public) failed \(failures, privacy: .public)/\(needed, privacy: .public); leaving its configuration alone")

            await notify(.init(gameTitle: facts.title,
                               verdict: verdict,
                               diagnosis: diagnosis?.summary,
                               change: nil,
                               exhausted: false))

        case .remedy(let finding):
            record.hasExhaustedOptions = false
            record.signaturesActedOn.insert(finding.signature)
            record.learned = RecoveryPlanner.entry(applying: plan, to: record.learned, for: facts)
            record.attempts[record.attempts.count - 1].changed = finding.remedy?.describedAs

            if RecoveryPolicy.mayKillWineserver(sideEffect: finding.remedy?.sideEffect,
                                                stillRunning: outcome.stillRunning),
               let containerURL {
                try? Wine.killAll(at: containerURL)
            }

            await notify(.init(gameTitle: facts.title,
                               verdict: verdict,
                               diagnosis: finding.summary,
                               change: finding.remedy?.describedAs,
                               exhausted: false))

        case .step(let step):
            record.hasExhaustedOptions = false
            record.stepsTried.insert(step.id)
            record.learned = RecoveryPlanner.entry(applying: plan, to: record.learned, for: facts)
            record.attempts[record.attempts.count - 1].changed = step.describedAs

            // A configuration that used to work and doesn't any more is no longer confirmed,
            // or the failure threshold would stay at two forever while the ladder walks.
            record.confirmed = false

            await notify(.init(gameTitle: facts.title,
                               verdict: verdict,
                               diagnosis: diagnosis?.summary,
                               change: step.describedAs,
                               exhausted: false))

        case .exhausted:
            // Said on the page as well as in a notification. A notification is one moment, and
            // this is a state: somebody who looks at the game a day later is owed the same
            // answer as somebody who was watching when it ran out.
            record.hasExhaustedOptions = true

            if !record.reportedExhausted {
                record.reportedExhausted = true

                CrashReportStore.queue(Self.report(kind: .optionsExhausted,
                                                   facts: facts,
                                                   runtimeID: runtimeID,
                                                   settings: applied,
                                                   winetricks: winetricks,
                                                   verdict: verdict,
                                                   outcome: outcome,
                                                   signature: diagnosis?.signature,
                                                   stepsTried: record.stepsTried.sorted(),
                                                   evidence: CrashReport.evidence(from: faults)))
            }

            await notify(.init(gameTitle: facts.title,
                               verdict: verdict,
                               diagnosis: diagnosis?.summary,
                               change: nil,
                               exhausted: true))
        }
    }

    // MARK: - Plumbing

    private static func report(kind: CrashReport.Kind, // swiftlint:disable:this function_parameter_count
                               facts: Provisioner.GameFacts,
                               runtimeID: String,
                               settings: RuntimeProfile.SettingsOverride,
                               winetricks: [String],
                               verdict: LaunchVerdict,
                               outcome: LaunchOutcome,
                               signature: String?,
                               stepsTried: [String],
                               evidence: [String]) -> CrashReport {
        .init(kind: kind,
              installID: CrashReport.installID,
              appVersion: Self.appVersion,
              systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
              model: CrashReport.hardwareModel,
              game: .init(storefront: facts.storefront?.manifestName ?? "unknown",
                          id: facts.id,
                          title: facts.title),
              runtimeID: runtimeID,
              runtimeVersion: Runtime.discoverAll()
                  .first { $0.id == runtimeID }?
                  .version?.description,
              settings: settings,
              winetricks: winetricks,
              verdict: verdict,
              ranForSeconds: Int(outcome.ranFor),
              signature: signature,
              stepsTried: stepsTried,
              evidence: evidence)
    }

    /// `CFBundleShortVersionString`, which is what the About window shows.
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// The transcript, bounded.
    ///
    /// A launch log can be tens of megabytes — Blades of Time's first two minutes produced 1.4MB
    /// of `fixme:d3d` before that channel was silenced. Both ends are kept because the two
    /// halves say different things: a failed import is printed before the first frame, and a
    /// page fault is printed last.
    private static func readTranscript(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }

        let cap = 2 * 1024 * 1024

        guard data.count > cap * 2 else {
            return String(data: data, encoding: .utf8)
        }

        let head = data.prefix(cap)
        let tail = data.suffix(cap)

        let opening = String(data: head, encoding: .utf8) ?? ""
        let closing = String(data: tail, encoding: .utf8) ?? ""

        return opening + "\n…\n" + closing
    }

    private func notify(_ notice: Notice) async {
        lastNotice = notice

        let content: UNMutableNotificationContent = .init()

        content.title = switch notice.verdict {
        case .neverStarted: String(localized: "\(notice.gameTitle) didn't start.")
        case .crashed:      String(localized: "\(notice.gameTitle) crashed.")
        case .wouldNotStay: String(localized: "\(notice.gameTitle) closed itself again.")
        default:            String(localized: "\(notice.gameTitle) is working.")
        }

        content.body = if notice.exhausted {
            String(localized: "PorTalistic has tried every configuration it knows. A report has been prepared so this can be looked at.")
        } else if let change = notice.change, let diagnosis = notice.diagnosis {
            String(localized: "\(diagnosis)\n\nNext run: \(change).")
        } else if let change = notice.change {
            String(localized: "Next run: \(change).")
        } else if let diagnosis = notice.diagnosis {
            diagnosis
        } else {
            String(localized: "Nothing in the log said why. PorTalistic will change its configuration if it happens again.")
        }

        content.interruptionLevel = .active

        let request: UNNotificationRequest = .init(identifier: "Recovery_\(notice.id.uuidString)",
                                                   content: content,
                                                   trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.log.error("Couldn't post the recovery notice: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Reports waiting to go

/**
 Reports the app has prepared, kept on disk until something sends them.

 Separate from the submission itself so that the whole loop works, and can be inspected, before
 a single byte leaves the machine. A report here is a file somebody can read — which is also
 the only honest way to ask for consent to send it.
 */
enum CrashReportStore {
    static let log: Logger = .custom(category: "CrashReportStore")

    static var directory: URL? {
        Bundle.appHome?.appending(path: "Compatibility/reports")
    }

    /// Write a report, unless one with the same fault is already waiting.
    ///
    /// The dedup is the point: a game in a crash loop produces a report per launch, and fifty
    /// copies of one fault is worse than none — it buries every other report and, once
    /// submission exists, reads as fifty people rather than one.
    static func queue(_ report: CrashReport) {
        guard let directory else { return }

        let name = report.deduplicationKey
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        let url = directory.appending(path: "\(name).json")

        guard !FileManager.default.fileExists(atPath: url.path) else {
            log.debug("A report for \(report.deduplicationKey, privacy: .public) is already waiting")
            return
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(report.reviewableText.utf8).write(to: url, options: .atomic)
            log.notice("Prepared a \(report.kind.rawValue, privacy: .public) report for \(report.game.title, privacy: .public)")
        } catch {
            log.error("Couldn't write a crash report: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Everything waiting, for the interface and for whatever eventually sends them.
    static func pending() -> [URL] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                         includingPropertiesForKeys: nil,
                                                                         options: [.skipsHiddenFiles]) else {
            return []
        }

        return entries.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }
}
