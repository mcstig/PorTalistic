//
//  LaunchOutcome.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation

/// What happened to a launch, as the supervision saw it.
///
/// Separate from the verdict because these are observations and the verdict is a judgement:
/// the same two facts mean different things depending on what the transcript says, and mixing
/// the two made it impossible to test either.
struct LaunchOutcome: Sendable, Equatable {
    /// Whether anything that looked like the game ever appeared.
    ///
    /// False is a strong signal on its own. macOS names a running Windows game "Wine", so the
    /// supervision identifies it by *arrival* — and nothing arriving means nothing started.
    let appeared: Bool

    /// Wall-clock seconds from the hand-off beginning to the last of the game's processes
    /// exiting.
    let ranFor: TimeInterval

    /// Whether anything was still running in the game's container when the supervision stopped
    /// watching.
    ///
    /// The fact that separates the two things ``appeared`` being false can mean. The hand-off
    /// gives a game ``Wine/arrivalDeadline`` to put a window up and then gives up, and
    /// `waitUntilGone` returns at once when nothing was ever identified — so a game still
    /// unpacking, or building shaders, or simply large and on a slow disk ends its "launch"
    /// while it is on its way to the screen. Without this, the verdict for that is
    /// `neverStarted`: a failure, acted on immediately, against a game that is about to open.
    var stillRunning: Bool = false
}

/// What a launch is taken to mean.
enum LaunchVerdict: String, Sendable, Equatable, Codable {
    /// Ran long enough, and printed nothing that says otherwise. This is what confirms a
    /// configuration — the only evidence available that a setting actually helped.
    case clean

    /// The transcript contains a fault. What kind is `CrashDiagnosis`'s question.
    case crashed

    /// Nothing ever appeared. A crash, reported differently because it is what the person
    /// saw: they pressed Play and nothing happened.
    case neverStarted

    /// Appeared, exited cleanly, and too soon to say anything. Somebody opening a game and
    /// changing their mind looks exactly like this, so nothing is concluded and nothing is
    /// changed.
    case inconclusive

    /// Opened, and was gone again in seconds — again, and again, on a game that has never run
    /// properly.
    ///
    /// One of these is somebody changing their mind, which is what `inconclusive` is for. The
    /// third in a row is not. This is the failure that looks like success: the game starts, so
    /// it did not fail to start; it exits normally, so the transcript holds nothing to read;
    /// and what the person saw was a message box telling them the game will not run here. The
    /// app watched that happen four times in a row, concluded nothing each time, and left the
    /// configuration exactly as it was — while the person waited for it to change.
    case wouldNotStay

    var isFailure: Bool {
        switch self {
        case .crashed, .neverStarted, .wouldNotStay: true
        case .clean, .inconclusive: false
        }
    }

    /// Whether the game refused to run, as opposed to breaking while it ran.
    ///
    /// A crash happened to a game that was running; these two are a game that looked at the
    /// machine and declined. Nothing was drawn, so nothing about *how* it draws can have been
    /// the reason — which is what decides the order the ladder is walked in.
    var isRefusalToRun: Bool {
        switch self {
        case .neverStarted, .wouldNotStay: true
        case .crashed, .clean, .inconclusive: false
        }
    }
}

/// The numbers the whole recovery loop is judged against.
///
/// One place, because every one of them is a "how long is long enough" that would otherwise
/// be written differently in the classifier, the journal and the tests.
enum RecoveryPolicy {
    /// A clean session at least this long means the configuration works.
    ///
    /// Five minutes because that is roughly what it took to know BioShock Remastered was
    /// actually fixed rather than crashing slightly later: it had already survived the logos,
    /// two disclaimers and the first act's opening, each of which had killed it before.
    static let confirmedGoodAfter: TimeInterval = 300

    /// A game that never appeared and was gone inside this didn't start.
    ///
    /// Longer than the wait it is judging, which is the whole point of deriving it rather than
    /// writing a number: the supervision gives a game ``Wine/arrivalDeadline`` to turn up, so a
    /// launch where nothing ever did always lasts at least that long. Set below it — 45 against
    /// 60 — this verdict was unreachable in exactly the case it exists for, and the strongest
    /// signal the loop has, "nothing ever appeared", was being filed as "somebody changed their
    /// mind" every time.
    ///
    /// The margin is for the rest of a launch: legendary signing in, Epic being asked for an
    /// authentication token, a prefix booting.
    static let neverStartedWithin: TimeInterval = Wine.arrivalDeadline + 30

    /// A session shorter than this, on a game that has never run properly, was not a session.
    ///
    /// Two minutes. The runs this exists for lasted ten and seventeen seconds — long enough to
    /// read a message box and close it — and the games doing it had been opened and closed the
    /// same way for a week without the app concluding anything.
    static let tooShortToBeASession: TimeInterval = 120

    /// How many of those in a row before a game is taken to be refusing to run.
    ///
    /// Two. One is somebody changing their mind; by the second, on a game that has never run
    /// properly, they are trying rather than browsing — and waiting for a third means watching
    /// the same failure a third time before anything is done about it, which is what this was
    /// set to and what it was changed from.
    static let shortSessionsBeforeActing: Int = 2

    /// Consecutive failures before anything is changed.
    ///
    /// One, for a game that has never worked: there is nothing to lose and the person is
    /// staring at a game that won't start. Two for a game that *has* worked, because a single
    /// crash in a game with a confirmed configuration is far more likely to be the game than
    /// the configuration, and reconfiguring it would be the app breaking something that works.
    static let failuresBeforeActing: Int = 1
    static let failuresBeforeActingOnAConfirmedGame: Int = 2

    /// Whether a session was too short to have been a session at all.
    ///
    /// Here rather than at the call site so the threshold has one reader as well as one
    /// definition.
    static func isTooShortToBeASession(_ ranFor: TimeInterval) -> Bool {
        ranFor < tooShortToBeASession
    }

    /// Whether a launch the person force-quit tells the loop anything.
    ///
    /// Only a long one. A session long enough to confirm a configuration confirms it however it
    /// ended — Force Quit is how some people close some games. A short one says nothing about
    /// the game at all: somebody stopped it, usually because it was taking too long to start,
    /// and read as a launch it is a no-show — a failure, acted on at once, which reconfigured a
    /// game for having been closed.
    static func judgesForceQuit(ranFor: TimeInterval) -> Bool {
        ranFor >= confirmedGoodAfter
    }

    /// Whether a remedy may shut the container's `wineserver` down.
    ///
    /// Only when nothing of that build is still running. The post-mortem can now reach a
    /// remedy while a game is alive — that is what ``LaunchOutcome/stillRunning`` records —
    /// and this one kills every process in the prefix, which with one container per runtime
    /// includes whatever else the person happens to be playing.
    static func mayKillWineserver(sideEffect: CrashDiagnosis.SideEffect?, stillRunning: Bool) -> Bool {
        sideEffect == .killWineserver && !stillRunning
    }

    /// How many sessions too short to be sessions this game has now had in a row.
    ///
    /// A function rather than three conditions at the call site, because each exclusion is a
    /// decision and each one has a reason:
    ///
    /// - a **confirmed** game is never counted, because a short session on a configuration
    ///   that has already run for five minutes is exactly what somebody looking in for a
    ///   minute produces;
    /// - a launch that left a **fault** in the transcript isn't counted, because that is a
    ///   crash and the crash path is already counting it — counting it twice would take two
    ///   rungs for one failure;
    /// - and anything that isn't one resets the run to nothing, because the evidence here is
    ///   the repetition. One is somebody changing their mind.
    static func shortSessionsInARow(following current: Int,
                                    ranFor: TimeInterval,
                                    confirmed: Bool,
                                    faults: [String],
                                    stillRunning: Bool = false) -> Int {
        // `stillRunning` for the same reason the verdict refuses to conclude anything about one:
        // a launch the app stopped watching says nothing about how long the game lasted.
        guard !confirmed, faults.isEmpty, !stillRunning, isTooShortToBeASession(ranFor) else { return 0 }

        return current + 1
    }
}

// MARK: - Classification

extension LaunchVerdict {
    /// Read a finished launch.
    ///
    /// - Parameters:
    ///   - outcome: what the supervision observed.
    ///   - faultLines: `CrashDiagnosis.faultLines(in:)` over the transcript. Passed in rather
    ///     than read here so this stays a pure decision over two facts and a list.
    ///   - shortSessionsInARow: how many sessions too short to be sessions this game has had in
    ///     a row, *including this one*, counted only while the game has never run cleanly.
    ///     Zero from anything that has no history to offer, which reads this launch on its own
    ///     exactly as it used to be read.
    static func of(_ outcome: LaunchOutcome,
                   faultLines: [String],
                   shortSessionsInARow: Int = 0) -> LaunchVerdict {
        // The transcript outranks the clock. A game that crashed forty minutes in crashed,
        // and one that printed a page fault on the way out still crashed even though the
        // person had a good session first.
        if !faultLines.isEmpty { return .crashed }

        // Nothing is concluded about a game that is still running. This is the app having
        // stopped watching, not the game having failed — and every failing verdict below would
        // reconfigure a game that is at that moment on its way to the screen.
        if outcome.stillRunning, outcome.ranFor < RecoveryPolicy.confirmedGoodAfter {
            return .inconclusive
        }

        if !outcome.appeared, outcome.ranFor < RecoveryPolicy.neverStartedWithin {
            return .neverStarted
        }

        if outcome.ranFor >= RecoveryPolicy.confirmedGoodAfter { return .clean }

        // The same ten seconds, for the third time. Each one on its own says nothing, and the
        // app said nothing about each one — which is how a game that opened, put up its own
        // "this device is not supported" box and closed again was read as a person browsing.
        if shortSessionsInARow >= RecoveryPolicy.shortSessionsBeforeActing { return .wouldNotStay }

        return .inconclusive
    }
}
