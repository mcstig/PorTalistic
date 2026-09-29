//
//  RecoveryPlanner.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 What to change after a game crashes.

 Two sources, asked in order, and the order is the point.

 A **diagnosis** is knowledge: the transcript named a fault somebody has already solved, and
 the remedy is the thing that solved it. It is tried first and it is tried once — a signature
 firing again after its own remedy was applied means the remedy was wrong for this game, and
 the planner stops trusting it.

 A **ladder** is ignorance, handled honestly. Nothing in the log was recognised, so a fixed
 sequence of configurations known to matter is walked one rung per crash, cheapest first, never
 repeating a rung. It is not clever and it does not pretend to be; what makes it safe is that
 it is finite, ordered, and recorded. When it runs out, the app stops changing things and says
 so, which is the honest end of an automatic process that did not work.

 # What is never done

 Nothing is changed speculatively — only after a failure. Nothing is changed on a game whose
 configuration has already produced a long clean session unless it fails twice in a row, because
 one crash in a working game is far more likely to be the game. And no rung is walked whose
 value is already in effect, which would burn a step and change nothing.
 */
enum RecoveryPlanner {
    static let log: Logger = .custom(category: "RecoveryPlanner")

    // MARK: - What comes out

    enum Plan: Equatable {
        /// A diagnosed fault with a known remedy.
        case remedy(CrashDiagnosis.Finding)

        /// Nothing recognised; try this rung.
        case step(Step)

        /// Every rung has been walked. Stop changing things, report it, tell the person.
        case exhausted

        /// Not yet — this game gets another chance before anything is touched.
        case wait(failures: Int, needed: Int)

        /// What the person is told changes next run.
        var describedAs: String? {
            switch self {
            case .remedy(let finding):  finding.remedy?.describedAs
            case .step(let step):       step.describedAs
            case .exhausted, .wait:     nil
            }
        }
    }

    // MARK: - The ladder

    /// One configuration worth trying, as a change to a compatibility entry.
    ///
    /// Expressed as entry fields rather than as its own thing, so a rung that works is already
    /// a publishable answer and so a runtime change goes through the same selection machinery
    /// as a curated one. There is no second way to pick a Wine build.
    struct Step: Equatable {
        let id: String
        let describedAs: String

        var settings: RuntimeProfile.SettingsOverride = .init()
        var winetricks: [String] = []
        var requiresNativeThirtyTwoBit: Bool?
        var graphicsBackend: RuntimeProfile.GraphicsBackend?

        /// Only offered when this is true of the game. A native-32-bit build is meaningless
        /// for a 64-bit game, and asking for one would spend a rung and a download on nothing.
        var onlyWhen: Condition?

        enum Condition: Equatable {
            case gameIsThirtyTwoBit
            case gameUsesDirect3DEleven
        }

        var changesRuntime: Bool {
            requiresNativeThirtyTwoBit == true || graphicsBackend != nil
        }

        /// Whether this rung changes what the game is *told about the machine*, rather than
        /// how Wine runs it.
        ///
        /// The Windows version and the Direct3D implementation are what a game's own
        /// compatibility check reads. The Retina desktop and Wine's render thread are not: a
        /// game that refuses to start has not looked at either.
        var changesWhatTheGameSees: Bool {
            graphicsBackend != nil || settings.windowsVersion != nil || settings.dxvk != nil
        }
    }

    /// Cheapest and least invasive first; anything that downloads a Wine build last.
    ///
    /// Each rung is here because it has actually been the answer to something. Retina Mode and
    /// the command stream thread both were, during the evening this loop exists because of;
    /// the Windows version is the single most common line on a community settings list; and the
    /// two runtime rungs are the shape of the two hardest faults found so far — Blades of Time
    /// needing a real i386 architecture, and a Direct3D 11 game stuck on wined3d.
    static let ladder: [Step] = [
        .init(id: "retina-off",
              describedAs: String(localized: "Turn off the Retina desktop"),
              settings: .init(retinaMode: false)),

        .init(id: "command-stream-thread-off",
              describedAs: String(localized: "Turn off Wine's separate render thread"),
              settings: .init(commandStreamThread: false)),

        .init(id: "windows-10",
              describedAs: String(localized: "Tell the game it is running on Windows 10"),
              settings: .init(windowsVersion: .win10)),

        .init(id: "windows-7",
              describedAs: String(localized: "Tell the game it is running on Windows 7"),
              settings: .init(windowsVersion: .win7)),

        .init(id: "dxvk-off",
              describedAs: String(localized: "Use Wine's own Direct3D instead of the Vulkan translation"),
              settings: .init(dxvk: false),
              onlyWhen: .gameUsesDirect3DEleven),

        .init(id: "capture-displays",
              describedAs: String(localized: "Let Wine take the display for fullscreen"),
              settings: .init(captureDisplaysForFullscreen: true)),

        .init(id: "native-thirty-two-bit",
              describedAs: String(localized: "Move the game to a Wine with a real 32-bit architecture"),
              requiresNativeThirtyTwoBit: true,
              onlyWhen: .gameIsThirtyTwoBit),

        // The three that change which Direct3D implementation a game renders through. They sit
        // last because they are the most expensive — a different runtime, possibly a prefix
        // that has to be created — and ``ordered(_:for:)`` walks them *first* for a game that
        // refused to run, which is the failure they are for.
        //
        // These three spent a while doing nothing at all, and the shape of that is worth
        // keeping: a step's `graphicsBackend` reached the game's learned entry, then the
        // profile, and the profile's backend was read by a badge on the game's page and by
        // nothing else. Which runtime a game gets was decided from `requirements` alone. So a
        // rung reported a change, recorded it as tried, and launched the game exactly as
        // before. `Requirements.preferredDirect3D` is what makes them real, and
        // ``Runtime/provides(_:)`` is what decides which build satisfies one.
        //
        // Apple's implementation first, and only here: the ranking deliberately never *chooses*
        // D3DMetal, because it is Apple's and this project may not distribute it. A game that
        // has already refused to run is the exception its own note names — "the honest fallback
        // when nothing else will start" — and it is the most mature of the three.
        //
        // No rung asks for DXVK. Nothing records whether a build has Vulkan, and the build that
        // ships DXMT says it has none in every transcript it writes, so asking for it would move
        // a game to something that cannot draw at all.
        .init(id: "direct3d-apple-metal",
              describedAs: String(localized: "Run Direct3D through Apple's translation instead"),
              graphicsBackend: .direct3DMetal,
              onlyWhen: .gameUsesDirect3DEleven),

        .init(id: "direct3d-dxmt",
              describedAs: String(localized: "Run Direct3D through DXMT instead"),
              graphicsBackend: .dxmt,
              onlyWhen: .gameUsesDirect3DEleven),

        .init(id: "direct3d-wine",
              describedAs: String(localized: "Run Direct3D through Wine's own translation instead"),
              // DXVK off with it: a plain build with DXVK on renders through DXVK, so asking
              // for Wine's own Direct3D without saying that lands the game on the build it was
              // already on, unchanged, and reports a change.
              settings: .init(dxvk: false),
              graphicsBackend: .wined3d,
              onlyWhen: .gameUsesDirect3DEleven)
    ]

    // MARK: - The decision

    /**
     What to do about this game, now.

     - Parameters:
       - record: the game's history. `consecutiveFailures` has already been incremented for
         the launch being reacted to.
       - diagnosis: what `CrashDiagnosis` made of the transcript, if anything.
       - verdict: how the launch failed, which decides the order the rungs are walked in —
         see ``ordered(_:for:)``.
       - effective: the settings the crashed launch actually ran with, so a rung whose value is
         already in effect is skipped rather than wasted.
       - backendInEffect: the Direct3D implementation the game actually rendered through, for
         the same reason. `nil` when it isn't known, which offers those rungs rather than
         risking skipping the one that would have worked.
       - backendsAvailable: the implementations some installed build actually provides. Empty
         means none are offered, which is the safe direction: a rung that moves a game to an
         implementation this Mac hasn't got announces a change and makes none.
       - facts: what is known about the game itself, for the rungs that only apply to some.
     */
    static func plan(for record: RecoveryJournal.GameRecord,
                     verdict: LaunchVerdict = .crashed,
                     diagnosis: CrashDiagnosis.Finding?,
                     effective: RuntimeProfile.SettingsOverride,
                     backendInEffect: RuntimeProfile.GraphicsBackend? = nil,
                     backendsAvailable: Set<RuntimeProfile.GraphicsBackend> = [],
                     requirements: RuntimeProfile.Requirements,
                     usesDirect3DEleven: Bool) -> Plan {
        guard record.consecutiveFailures >= record.failuresBeforeActing else {
            return .wait(failures: record.consecutiveFailures, needed: record.failuresBeforeActing)
        }

        if let diagnosis,
           let remedy = diagnosis.remedy,
           !record.signaturesActedOn.contains(diagnosis.signature),
           // A remedy naming an implementation nothing here provides is the same empty promise
           // as a rung doing it, and worse: a signature is only ever acted on once.
           remedy.graphicsBackend.map(backendsAvailable.contains) ?? true {
            return .remedy(diagnosis)
        }

        let available = ladder.filter { step in
            guard !record.stepsTried.contains(step.id) else { return false }
            guard applies(step,
                          requirements: requirements,
                          usesDirect3DEleven: usesDirect3DEleven,
                          backendsAvailable: backendsAvailable) else { return false }
            return !isAlreadyInEffect(step, given: effective, backend: backendInEffect)
        }

        guard let next = ordered(available, for: verdict).first else { return .exhausted }

        return .step(next)
    }

    /// The remaining rungs, in the order this failure justifies.
    ///
    /// A game that opened and was gone again in seconds did not fail while running — it
    /// refused to run, having looked at the machine and decided against it. What it looked at
    /// is the Windows version and the graphics card: Asphalt Legends put up its own "no
    /// compatible GPU" box and quit, ten seconds at a time. Turning off the Retina desktop
    /// first would spend four launches proving nothing, which is what the person watching it
    /// open and close four times has already done.
    ///
    /// A partition rather than a sort, so the ladder's own cheapest-first order survives
    /// inside each half, and nothing is dropped — a rung that looks irrelevant here has been
    /// the answer to something, or it would not be on the ladder.
    private static func ordered(_ steps: [Step], for verdict: LaunchVerdict) -> [Step] {
        guard verdict.isRefusalToRun else { return steps }

        // Two levels, and the first is the one this was written for. What the person is shown
        // in this class of failure names the graphics card — "No compatible GPU found", in a
        // box the game puts up itself — and the last thing Asphalt Legends' transcript records
        // before it quits is the game asking the graphics adapter what it is. So the
        // implementation it renders through is tried before the Windows version it is told
        // about, and both before anything that only changes how a running game behaves.
        return steps.filter { $0.graphicsBackend != nil }
            + steps.filter { $0.changesWhatTheGameSees && $0.graphicsBackend == nil }
            + steps.filter { !$0.changesWhatTheGameSees }
    }

    private static func applies(_ step: Step,
                                requirements: RuntimeProfile.Requirements,
                                usesDirect3DEleven: Bool,
                                backendsAvailable: Set<RuntimeProfile.GraphicsBackend>) -> Bool {
        // Asked first: a rung that moves the game to an implementation no build on this Mac has
        // is the promise-without-a-change fault again. The ranking finds nothing to put first,
        // the game relaunches on exactly what it was on, and the person is told it will now
        // render through something else. A Mac with no Game Porting Toolkit, Whisky or
        // CrossOver on it has no Apple implementation to move to.
        if let backend = step.graphicsBackend, !backendsAvailable.contains(backend) { return false }

        return switch step.onlyWhen {
        case .none:                         true
        case .gameIsThirtyTwoBit:           requirements.thirtyTwoBit
        case .gameUsesDirect3DEleven:       usesDirect3DEleven
        }
    }

    /// Whether the rung would change nothing.
    ///
    /// A ladder that spends its first rung setting Retina Mode to the value it already has is
    /// a ladder one rung shorter, and the person waits a whole extra crash for it.
    ///
    /// Not private only so the suite can ask it about a graphics-backend rung directly: the
    /// ladder has none today (see the note above it), and a rule nothing exercises is a rule
    /// nobody finds out is broken.
    static func isAlreadyInEffect(_ step: Step,
                                          given effective: RuntimeProfile.SettingsOverride,
                                          backend: RuntimeProfile.GraphicsBackend?) -> Bool {
        let settings = step.settings

        // Asked before the rule below, which is a deliberate "assume not". Which implementation
        // is rendering a game *is* knowable — it is a property of the runtime it ended up on —
        // and a rung asking for the one already in use changes nothing, while the person waits
        // out a whole launch to find that out. Asphalt Legends was already on DXMT.
        if let wanted = step.graphicsBackend {
            guard let backend else { return false }
            return wanted == backend
        }

        if let wanted = settings.retinaMode, effective.retinaMode != wanted { return false }
        if let wanted = settings.commandStreamThread, effective.commandStreamThread != wanted { return false }
        if let wanted = settings.dxvk, effective.dxvk != wanted { return false }
        if let wanted = settings.dxvkAsync, effective.dxvkAsync != wanted { return false }
        if let wanted = settings.captureDisplaysForFullscreen, effective.captureDisplaysForFullscreen != wanted { return false }
        if let wanted = settings.windowsVersion, effective.windowsVersion != wanted { return false }

        // A rung that moves the game to a 32-bit Wine, or installs a verb, is never "already
        // in effect": whether it is depends on what got selected, not on what was asked for.
        if step.changesRuntime || !step.winetricks.isEmpty { return false }

        return !settings.isEmpty
    }

    // MARK: - Applying it

    /// The game's learned entry with this plan folded into it.
    ///
    /// The entry is the unit of knowledge, so a plan is applied by rewriting it rather than by
    /// poking at settings somewhere. Each application is additive: a game that needed three
    /// things ends up with an entry that says all three, which is exactly the entry worth
    /// publishing.
    static func entry(applying plan: Plan,
                      to existing: CompatibilityDatabase.Entry?,
                      for facts: Provisioner.GameFacts) -> CompatibilityDatabase.Entry? {
        var entry = existing ?? blankEntry(for: facts)

        switch plan {
        case .remedy(let finding):
            guard let remedy = finding.remedy else { return nil }

            entry.settings = entry.settings.overlaid(with: remedy.settings)
            entry.winetricks = union(entry.winetricks, remedy.winetricks)
            entry.requiresNativeThirtyTwoBit = remedy.requiresNativeThirtyTwoBit ?? entry.requiresNativeThirtyTwoBit
            entry.graphicsBackend = remedy.graphicsBackend ?? entry.graphicsBackend
            entry.note = appending(finding.summary, to: entry.note)

        case .step(let step):
            entry.settings = entry.settings.overlaid(with: step.settings)
            entry.winetricks = union(entry.winetricks, step.winetricks)
            entry.requiresNativeThirtyTwoBit = step.requiresNativeThirtyTwoBit ?? entry.requiresNativeThirtyTwoBit
            entry.graphicsBackend = step.graphicsBackend ?? entry.graphicsBackend
            entry.note = noting(step.describedAs, in: entry.note)

        case .exhausted, .wait:
            return nil
        }

        return entry
    }

    private static func blankEntry(for facts: Provisioner.GameFacts) -> CompatibilityDatabase.Entry {
        var identifiers: [CompatibilityDatabase.Entry.Identifier] = []

        if let storefront = facts.storefront {
            identifiers.append(.init(storefront: storefront, id: facts.id))
        }

        return .init(identifiers: identifiers, titles: [facts.title])
    }

    private static func union(_ base: [String], _ addition: [String]) -> [String] {
        base + addition.filter { !base.contains($0) }
    }

    /// How the line listing what has been tried begins.
    ///
    /// Public and matched rather than rebuilt, because notes written by older versions have to
    /// be recognised and folded into it — including the wording it used then, below.
    static let triedPrefix: String = String(localized: "Found by trying configurations after a failure: ")

    /// What this wrote before, one paragraph per rung.
    private static let triedPrefixes: [String] = [
        triedPrefix,
        "Found by trying configurations after a crash: "
    ]

    /// `note` with `change` added to the one line that lists what has been tried.
    ///
    /// One line, however many rungs are walked. A paragraph each is what a person ends up
    /// reading on the game's page — six failures in, the panel explaining how a game runs is
    /// mostly a list of things that didn't work — and it is also what a manifest entry would
    /// publish, where "everything we tried" is not the knowledge. The knowledge is `settings`.
    ///
    /// Notes already written are folded in rather than left alone, so a game that has been
    /// through this before gets shorter rather than mixed.
    /// - Important: a change's description may not contain `"; "`, which is what separates the
    ///   items on that line. Nothing in the ladder or the diagnoses does, and the invariant
    ///   script refuses one that starts to.
    static func noting(_ change: String, in note: String?) -> String {
        var paragraphs = (note ?? "")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var tried: [String] = []

        paragraphs.removeAll { paragraph in
            guard let prefix = triedPrefixes.first(where: { paragraph.hasPrefix($0) }) else { return false }

            tried += paragraph
                .dropFirst(prefix.count)
                .components(separatedBy: "; ")
                .map(trimmed)

            return true
        }

        tried.append(trimmed(change))

        var seen: Set<String> = .init()
        tried = tried.filter { !$0.isEmpty && seen.insert($0).inserted }

        paragraphs.append(triedPrefix + tried.joined(separator: "; ") + ".")

        return paragraphs.joined(separator: "\n\n")
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "."))
    }

    private static func appending(_ line: String, to note: String?) -> String {
        guard let note, !note.isEmpty else { return line }
        guard !note.contains(line) else { return note }
        return note + "\n\n" + line
    }
}
