//
//  CrashRecoveryRegressionTests.swift
//  PorTalisticTests
//
//  Created by Claude Opus 5 on 17/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Testing

@testable import PorTalistic

/**
 Reading a crash, and deciding what to do about it.

 Every transcript below is a real one, shortened. That is the only way these tests are worth
 anything: a signature written against invented log text matches invented log text. The lines
 here are what BioShock Remastered, Blades of Time and a stale `wineserver` actually printed on
 this machine, on the evening each of them was diagnosed by hand.

 The other half of the suite is about restraint. An automatic process that reconfigures a game
 is one bug away from breaking a game that works, so there are more tests here about what must
 *not* happen than about what must.
 */
@Suite("Crash recovery")
struct CrashRecoveryRegressionTests {
    // MARK: - Fixtures

    /// A launch that went fine. Full of `fixme:` and `err:`, because every launch is.
    static let cleanTranscript = """
        === PorTalistic launch transcript ===
        WINEMSYNC=1 WINEDLLOVERRIDES=mscoree=d;mshtml=d
        fixme:winediag:loader_init wine-staging 11.16 is a testing version.
        err:environ:init_peb starting L"C:\\\\Game\\\\Game.exe" in experimental wow64 mode
        fixme:d3d:wined3d_check_device_multisample_type multisample_quality 0 ignored.
        fixme:imm:ImeSetActiveContext (0x1234, 1): stub
        """

    static let bioshockAdapterCrash = """
        fixme:atiadlxx:ADL_Main_Control_Create (0x7fe0, 1) semi-stub
        fixme:atiadlxx:ADL_Adapter_NumberOfAdapters_Get (ptr 00000000) stub!
        wine: Unhandled page fault on read access to 00000050 at address 028A415A (thread 0124)
        """

    static let bioshockShaderCrash = """
        fixme:d3dcompiler:D3DCompile2 flags2 0.
        fixme:write_sm4_block Unhandled instruction type HLSL_IR_JUMP.
        wine: Unhandled page fault on execute access to FFFFFE9B at address FFFFFE9B (thread 01a8)
        """

    static let bladesOfTimeStackCrash = """
        err:seh:call_stack_handlers invalid frame 000000000012EDF0 (0000000000132000-000000000022FD20)
        err:seh:NtRaiseException Exception frame is not in stack limits => unable to dispatch exception.
        """

    static let missingLibrary = """
        err:module:import_dll Library D3DCOMPILER_43.dll not found
        err:module:LdrInitializeThunk Importing dlls for L"C:\\\\Game\\\\BioshockHD.exe" failed, status c0000135
        """

    static let staleWineserver = """
        err:msync:msync_init Failed to open msync shared memory file
        err:winediag:loader_init wineserver not responding
        """

    private func facts(_ id: String = "bc2c95c6ff564a16b26644f1d3ac3c55",
                       title: String = "BioShock Remastered",
                       storefront: Game.Storefront? = .epicGames) -> Provisioner.GameFacts {
        .init(id: id, title: title, storefront: storefront, location: .init(filePath: "/tmp/game"))
    }

    // MARK: - Is it even a crash

    @Test("A launch full of the usual Wine noise is not a crash")
    func cleanLaunchIsClean() {
        // The failure this exists for is the expensive one: a generous marker list classifies
        // every session as a crash, and the app starts reconfiguring games that work.
        #expect(CrashDiagnosis.faultLines(in: Self.cleanTranscript).isEmpty)
        #expect(CrashDiagnosis.diagnose(transcript: Self.cleanTranscript) == nil)
    }

    @Test("A page fault is a crash")
    func pageFaultIsACrash() {
        #expect(!CrashDiagnosis.faultLines(in: Self.bioshockAdapterCrash).isEmpty)
    }

    @Test("A verdict reads the transcript before the clock")
    func verdicts() {
        let long: LaunchOutcome = .init(appeared: true, ranFor: 3_600)
        let brief: LaunchOutcome = .init(appeared: true, ranFor: 20)
        let absent: LaunchOutcome = .init(appeared: false, ranFor: 4)

        // Crashed an hour in is still crashed. A good session first doesn't make it a clean one.
        #expect(LaunchVerdict.of(long, faultLines: ["wine: Unhandled page fault"]) == .crashed)
        #expect(LaunchVerdict.of(long, faultLines: []) == .clean)
        #expect(LaunchVerdict.of(absent, faultLines: []) == .neverStarted)

        // Somebody opening a game and changing their mind. Concluding anything here would mean
        // reconfiguring a game because its owner looked at it for twenty seconds.
        #expect(LaunchVerdict.of(brief, faultLines: []) == .inconclusive)
    }

    @Test("A game that opens and closes again, every time, is a game that will not run")
    func wouldNotStay() {
        let brief: LaunchOutcome = .init(appeared: true, ranFor: 12)
        let long: LaunchOutcome = .init(appeared: true, ranFor: 3_600)
        let absent: LaunchOutcome = .init(appeared: false, ranFor: 4)

        // One is still somebody changing their mind; the next one is not. Asphalt Legends
        // opened, put up its own "no compatible GPU" box and closed again, ten seconds at a
        // time, and the app — which only ever looked at one launch — concluded nothing, every
        // time, for as long as it was asked. Written against the policy rather than a number,
        // so moving the threshold moves the test with it.
        #expect(LaunchVerdict.of(brief, faultLines: [],
                                 shortSessionsInARow: RecoveryPolicy.shortSessionsBeforeActing - 1) == .inconclusive)
        #expect(LaunchVerdict.of(brief, faultLines: [],
                                 shortSessionsInARow: RecoveryPolicy.shortSessionsBeforeActing) == .wouldNotStay)

        // And it has to be a failure, or nothing would ever be changed about it.
        #expect(LaunchVerdict.wouldNotStay.isFailure)

        // The facts still outrank the history: a long session is clean and a fault is a crash,
        // whatever the game did on the four launches before this one.
        #expect(LaunchVerdict.of(long, faultLines: [], shortSessionsInARow: 9) == .clean)
        #expect(LaunchVerdict.of(brief, faultLines: ["wine: Unhandled page fault"], shortSessionsInARow: 9) == .crashed)
        #expect(LaunchVerdict.of(absent, faultLines: [], shortSessionsInARow: 9) == .neverStarted)
    }

    @Test("What counts as a refusal, and what puts the count back to nothing")
    func shortSessionCounting() {
        let short = RecoveryPolicy.tooShortToBeASession - 1
        let long = RecoveryPolicy.confirmedGoodAfter

        // The run builds up.
        #expect(RecoveryPolicy.shortSessionsInARow(following: 0, ranFor: short, confirmed: false, faults: []) == 1)
        #expect(RecoveryPolicy.shortSessionsInARow(following: 2, ranFor: short, confirmed: false, faults: []) == 3)

        // A session long enough to have been one ends it.
        #expect(RecoveryPolicy.shortSessionsInARow(following: 2, ranFor: long, confirmed: false, faults: []) == 0)

        // A crash is counted by the crash path. Counting it here as well would spend two rungs
        // on one failure.
        #expect(RecoveryPolicy.shortSessionsInARow(following: 2, ranFor: short, confirmed: false,
                                                   faults: ["wine: Unhandled page fault"]) == 0)

        // And a game that has already run for five minutes is allowed short sessions: that is
        // what looking in on a game for a minute produces.
        #expect(RecoveryPolicy.shortSessionsInARow(following: 2, ranFor: short, confirmed: true, faults: []) == 0)
    }

    @Test("What counts as too short to have been a session")
    func shortSessionBoundary() {
        #expect(RecoveryPolicy.isTooShortToBeASession(RecoveryPolicy.tooShortToBeASession - 1))
        #expect(!RecoveryPolicy.isTooShortToBeASession(RecoveryPolicy.tooShortToBeASession))

        // A session long enough to confirm a configuration is never also short enough to
        // condemn it, whatever either number is set to.
        #expect(!RecoveryPolicy.isTooShortToBeASession(RecoveryPolicy.confirmedGoodAfter))
    }

    @Test("One unreadable attempt doesn't cost the journal everything it has learned")
    func anUnknownVerdictIsForgotten() throws {
        // What a verdict added in a later build looks like to this one. The history is the
        // least valuable thing in the file and the most likely to break it, and `load()`
        // discards what it cannot decode — so without the forgiving decode, a fix that took
        // four crashes to find goes because of a word in a list of old launches.
        let fromTheFuture = """
            {"attempts":[{"at":780000000,"ranFor":9,"runtimeID":"mythic-engine","settings":{},
                          "verdict":"somethingThisBuildHasNeverHeardOf"}],
             "confirmed":false,"consecutiveFailures":1,
             "learned":{"identifiers":[],"settings":{},"titles":["DNF Duel"],"winetricks":[]},
             "reportedExhausted":false,"reportedFix":false,
             "signaturesActedOn":[],"stepsTried":["windows-10"]}
            """

        let record = try JSONDecoder().decode(RecoveryJournal.GameRecord.self,
                                              from: Data(fromTheFuture.utf8))

        #expect(record.attempts.isEmpty)
        #expect(record.learned?.titles == ["DNF Duel"])
        #expect(record.stepsTried == ["windows-10"])
    }

    @Test("A journal written before this version still opens")
    func journalSurvivesANewField() throws {
        // `GameRecord`'s decoder is written out by hand for exactly this. A synthesised one
        // refuses a file missing any non-optional key, and `load()` discards what it cannot
        // decode — so adding a field would have thrown away every learned fix and every rung
        // already walked, on every machine that updated, silently.
        let older = """
            {"attempts":[],"confirmed":true,"consecutiveFailures":2,
             "learned":{"identifiers":[],"settings":{},"titles":["DNF Duel"],"winetricks":[]},
             "reportedExhausted":false,"reportedFix":false,
             "signaturesActedOn":["atiadlxx-stub-returns-null"],"stepsTried":["windows-10"]}
            """

        let record = try JSONDecoder().decode(RecoveryJournal.GameRecord.self, from: Data(older.utf8))

        #expect(record.learned?.titles == ["DNF Duel"])
        #expect(record.stepsTried == ["windows-10"])
        #expect(record.signaturesActedOn == ["atiadlxx-stub-returns-null"])
        #expect(record.confirmed)
        #expect(record.consecutiveShortSessions == 0)
    }

    // MARK: - The faults that were diagnosed by hand

    @Test("The AMD adapter stub is recognised, and disabling it is the answer")
    func diagnosesAdapterStub() throws {
        let finding = try #require(CrashDiagnosis.diagnose(transcript: Self.bioshockAdapterCrash))

        #expect(finding.signature == "atiadlxx-stub-returns-null")
        #expect(finding.remedy?.settings.dllOverrides?["atiadlxx"] == "d")
    }

    @Test("Wine's shader compiler failing is recognised, and the verb comes with the override")
    func diagnosesShaderCompiler() throws {
        let finding = try #require(CrashDiagnosis.diagnose(transcript: Self.bioshockShaderCrash))
        let remedy = try #require(finding.remedy)

        #expect(finding.signature == "builtin-hlsl-compiler-cannot-branch")

        // Both halves, or neither works: the override alone resolves to a builtin that cannot
        // compile them, and the verb alone leaves Wine's compiler in charge.
        #expect(remedy.winetricks.contains("d3dcompiler_43"))
        #expect(remedy.settings.dllOverrides?["d3dcompiler_43"] == "n,b")
    }

    @Test("An exhausted stack asks for a real 32-bit Wine, not a setting")
    func diagnosesStackExhaustion() throws {
        let finding = try #require(CrashDiagnosis.diagnose(transcript: Self.bladesOfTimeStackCrash))

        #expect(finding.signature == "exception-frame-outside-stack")
        #expect(finding.remedy?.requiresNativeThirtyTwoBit == true)
        #expect(finding.remedy?.changesRuntime == true)
    }

    @Test("A stale Wine server is an action, not a configuration change")
    func diagnosesStaleWineserver() throws {
        let finding = try #require(CrashDiagnosis.diagnose(transcript: Self.staleWineserver))
        let remedy = try #require(finding.remedy)

        #expect(finding.signature == "stale-wineserver-without-msync")
        #expect(remedy.sideEffect == .killWineserver)
        #expect(remedy.settings.isEmpty, "nothing about the configuration is wrong here")
    }

    @Test("A missing library is never fixed with a native-only override")
    func missingLibraryNeverAsksForNativeOnly() throws {
        let finding = try #require(CrashDiagnosis.diagnose(transcript: Self.missingLibrary))
        let remedy = try #require(finding.remedy)

        #expect(finding.signature == "missing-imported-dll")

        // The trap this is here for: `n` means native *only*, so a failed verb download turns
        // a missing fix into a game that will not launch at all. Every override this file
        // produces has to carry the builtin fallback.
        for (dll, spec) in remedy.settings.dllOverrides ?? [:] {
            #expect(spec != "n", "\(dll) was set to native-only, which is how BioShock stopped starting")
        }
    }

    @Test("Our own native-only override is recognised as our own fault")
    func recognisesSelfInflictedNativeOnly() throws {
        let applied: RuntimeProfile.SettingsOverride = .init(dllOverrides: ["d3dcompiler_43": "n"])
        let finding = try #require(CrashDiagnosis.diagnose(transcript: Self.missingLibrary, applied: applied))

        #expect(finding.signature == "native-only-override-with-no-native-file")
        #expect(finding.remedy?.settings.dllOverrides?["d3dcompiler_43"] == "n,b")
    }

    // MARK: - What gets changed, and when

    @Test("Nothing is changed after one crash in a game that already worked")
    func confirmedGameGetsTheBenefitOfTheDoubt() {
        // One crash in a game with a configuration that has run cleanly for five minutes is far
        // more likely to be the game than the configuration. Reconfiguring it would be the app
        // breaking something that works.
        var record: RecoveryJournal.GameRecord = .init()
        record.confirmed = true
        record.learned = .init(identifiers: [], titles: ["BioShock Remastered"])
        record.consecutiveFailures = 1

        let plan = RecoveryPlanner.plan(for: record,
                                        diagnosis: nil,
                                        effective: .init(),
                                        requirements: .init(),
                                        usesDirect3DEleven: false)

        #expect(plan == .wait(failures: 1, needed: RecoveryPolicy.failuresBeforeActingOnAConfirmedGame))
        #expect(plan.describedAs == nil)
    }

    @Test("A game that has never worked is acted on immediately")
    func unprovenGameIsActedOnAtOnce() throws {
        var record: RecoveryJournal.GameRecord = .init()
        record.consecutiveFailures = 1

        let plan = RecoveryPlanner.plan(for: record,
                                        diagnosis: nil,
                                        effective: .init(),
                                        requirements: .init(),
                                        usesDirect3DEleven: false)

        guard case .step = plan else {
            Issue.record("a game that has never started should get the first rung, got \(plan)")
            return
        }
    }

    @Test("A game that refuses to start is offered what it actually looked at, first")
    func refusalWalksTheRungsTheGameCanSee() throws {
        var record: RecoveryJournal.GameRecord = .init()
        record.consecutiveFailures = 1

        // Both verdicts are a game that refused to run rather than one that broke while
        // running: Asphalt Legends never appeared at all, and before that it appeared and was
        // gone in ten seconds. Neither drew anything, so nothing about how it draws was the
        // reason it stopped.
        for verdict: LaunchVerdict in [.wouldNotStay, .neverStarted] {
            let plan = RecoveryPlanner.plan(for: record,
                                            verdict: verdict,
                                            diagnosis: nil,
                                            effective: .init(),
                                            backendInEffect: .dxmt,
                                            backendsAvailable: [.direct3DMetal, .dxmt, .wined3d],
                                            requirements: .init(),
                                            usesDirect3DEleven: true)

            guard case .step(let step) = plan else {
                Issue.record("a game that refuses to start should get a rung, got \(plan)")
                return
            }

            // The implementation it renders through, before the Windows version it is told
            // about, and both before the Retina desktop or Wine's render thread. What the
            // person is shown in this class of failure names the graphics card.
            #expect(step.graphicsBackend != nil)
            #expect(step.changesWhatTheGameSees)

            // And not the one it is already on.
            #expect(step.graphicsBackend != .dxmt)
        }
    }

    @Test("Nothing is concluded about a game that is still running")
    func aLiveGameIsNeverAFailure() {
        // The other half of the no-show. The hand-off gives a game a minute to put a window up
        // and then gives up, and `waitUntilGone` returns at once when nothing was identified —
        // so a game still unpacking, or building shaders, or simply large and on a slow disk
        // ends its "launch" on its way to the screen. Calling that `neverStarted` reconfigures
        // a game the person is watching load.
        let loading: LaunchOutcome = .init(appeared: false,
                                           ranFor: Wine.arrivalDeadline + 0.5,
                                           stillRunning: true)

        #expect(LaunchVerdict.of(loading, faultLines: []) == .inconclusive)

        // And it is not counted as a refusal either.
        #expect(RecoveryPolicy.shortSessionsInARow(following: 1, ranFor: 10, confirmed: false,
                                                   faults: [], stillRunning: true) == 0)

        // A session long enough to confirm a configuration still confirms it, whether or not
        // the person is still playing when the app stops watching.
        let playing: LaunchOutcome = .init(appeared: true,
                                           ranFor: RecoveryPolicy.confirmedGoodAfter + 1,
                                           stillRunning: true)

        #expect(LaunchVerdict.of(playing, faultLines: []) == .clean)
    }

    @Test("What the ladder has tried is one line, however many rungs it walks")
    func triedConfigurationsAreOneLine() throws {
        // Six failures in, the panel that explains how a game runs was mostly a list of things
        // that hadn't worked — a paragraph each. It is also what a manifest entry would publish,
        // where the knowledge is the settings, not the history.
        let old = """
            Found by trying configurations after a crash: Tell the game it is running on Windows 10.

            Found by trying configurations after a crash: Tell the game it is running on Windows 7.

            Found by trying configurations after a crash: Turn off Wine's separate render thread.
            """

        let note = RecoveryPlanner.noting("Let Wine take the display for fullscreen", in: old)

        // One line, everything on it, in the order it was tried.
        #expect(note.components(separatedBy: "\n\n").count == 1)
        #expect(note.hasPrefix(RecoveryPlanner.triedPrefix))
        #expect(note.contains("Windows 10; Tell the game it is running on Windows 7"))
        #expect(note.hasSuffix("Let Wine take the display for fullscreen."))

        // A diagnosis keeps its own paragraph, and the same rung twice doesn't appear twice.
        let withDiagnosis = RecoveryPlanner.noting("Tell the game it is running on Windows 10",
                                                   in: "The game asked Wine for an AMD graphics adapter.\n\n" + note)

        #expect(withDiagnosis.components(separatedBy: "\n\n").count == 2)
        #expect(withDiagnosis.hasPrefix("The game asked Wine"))

        let windowsTen = withDiagnosis.components(separatedBy: "Windows 10").count - 1
        #expect(windowsTen == 1)
    }

    @Test("Every line of an explanation gets its own row")
    func everyReasonLineIsARow() {
        // The checkmark is drawn per row, and what the app learns is written as paragraphs — so
        // one multi-line reason drew one checkmark and left the rest of its lines looking like
        // settings that hadn't been applied.
        let rows = RuntimeProfilePanel.rows(of: [
            "64-bit Direct3D 12, which has to be translated to Metal.",
            "One thing.\n\nAnother thing.\n\nA third.",
            "   ",
        ])

        #expect(rows.count == 4)
        #expect(rows.allSatisfy { !$0.isEmpty })
        #expect(rows.last == "A third.")
    }

    @Test("A launch the person force-quit is never a failure")
    func forceQuitIsNotAFailure() {
        // Pressed on a game that was taking too long to start, Force Quit ended a launch in
        // which nothing had appeared, a few seconds in — which is exactly what a no-show looks
        // like, and a no-show is acted on at once. So stopping a slow launch reconfigured the
        // game, and doing it twice walked two rungs of the ladder.
        #expect(!RecoveryPolicy.judgesForceQuit(ranFor: 8))
        #expect(!RecoveryPolicy.judgesForceQuit(ranFor: RecoveryPolicy.confirmedGoodAfter - 1))

        // A long session is still a long session, however it ended: some people close some
        // games with Force Quit, and five minutes of play is what confirms a configuration.
        #expect(RecoveryPolicy.judgesForceQuit(ranFor: RecoveryPolicy.confirmedGoodAfter))
    }

    @Test("A prefix is only shut down when nothing of it is running")
    func killingAPrefixWaitsForTheGameToGo() {
        // `Wine.killAll` ends every process in the container, and there is one container per
        // runtime — so with a game still alive this remedy stops whatever the person happens
        // to be playing. It reaches here with one alive now: a launch the app stopped watching
        // is still a launch it reacts to.
        #expect(RecoveryPolicy.mayKillWineserver(sideEffect: .killWineserver, stillRunning: false))
        #expect(!RecoveryPolicy.mayKillWineserver(sideEffect: .killWineserver, stillRunning: true))
        #expect(!RecoveryPolicy.mayKillWineserver(sideEffect: nil, stillRunning: false))
    }

    @Test("Nothing is offered that this Mac cannot actually provide")
    func unavailableBackendsAreNotOffered() throws {
        var record: RecoveryJournal.GameRecord = .init()
        record.consecutiveFailures = 1

        // No Game Porting Toolkit, no Whisky, no CrossOver: there is no Apple implementation to
        // move a game to. Offering it anyway relaunches the game on exactly what it was on,
        // with a notification saying it now renders through something else.
        let withNothing = RecoveryPlanner.plan(for: record,
                                               verdict: .neverStarted,
                                               diagnosis: nil,
                                               effective: .init(),
                                               backendInEffect: .dxmt,
                                               backendsAvailable: [],
                                               requirements: .init(),
                                               usesDirect3DEleven: true)

        guard case .step(let first) = withNothing else {
            Issue.record("expected a rung, got \(withNothing)")
            return
        }

        #expect(first.graphicsBackend == nil)

        // With one installed, it is the first thing tried.
        let withApple = RecoveryPlanner.plan(for: record,
                                             verdict: .neverStarted,
                                             diagnosis: nil,
                                             effective: .init(),
                                             backendInEffect: .dxmt,
                                             backendsAvailable: [.direct3DMetal],
                                             requirements: .init(),
                                             usesDirect3DEleven: true)

        #expect(withApple == .step(try #require(RecoveryPlanner.ladder.first { $0.id == "direct3d-apple-metal" })))
    }

    @Test("A remedy naming an implementation this Mac hasn't got steps aside for the ladder")
    func unavailableRemedyFallsThrough() throws {
        let finding: CrashDiagnosis.Finding = .init(
            signature: "metal-escapes-missing",
            summary: "The Direct3D-on-Metal layer couldn't get a surface to draw into.",
            remedy: .init(describedAs: "Run it through Apple's translation instead",
                          graphicsBackend: .direct3DMetal)
        )

        var record: RecoveryJournal.GameRecord = .init()
        record.consecutiveFailures = 1

        // A signature is acted on once and never again, so spending it on a change nothing can
        // make costs the one attempt that mattered.
        let plan = RecoveryPlanner.plan(for: record,
                                        verdict: .crashed,
                                        diagnosis: finding,
                                        effective: .init(),
                                        backendsAvailable: [],
                                        requirements: .init(),
                                        usesDirect3DEleven: true)

        #expect(plan != .remedy(finding))

        #expect(RecoveryPlanner.plan(for: record,
                                     verdict: .crashed,
                                     diagnosis: finding,
                                     effective: .init(),
                                     backendsAvailable: [.direct3DMetal],
                                     requirements: .init(),
                                     usesDirect3DEleven: true) == .remedy(finding))
    }

    @Test("Nothing appearing at all is a game that didn't start")
    func nothingAppearingIsNeverStarted() {
        // The verdict was unreachable in the case it exists for. The supervision gives a game
        // `Wine.arrivalDeadline` to turn up, so a launch where nothing ever did lasts at least
        // that long — and this threshold was forty-five seconds against that sixty. Asphalt
        // Legends' launches are sixty seconds each with nothing arriving, and every one of them
        // was filed as somebody opening a game and changing their mind.
        #expect(RecoveryPolicy.neverStartedWithin > Wine.arrivalDeadline)

        let gaveUp: LaunchOutcome = .init(appeared: false, ranFor: Wine.arrivalDeadline + 0.5)

        #expect(LaunchVerdict.of(gaveUp, faultLines: []) == .neverStarted)
    }

    @Test("A crash still walks the ladder cheapest first")
    func crashKeepsTheLaddersOwnOrder() throws {
        var record: RecoveryJournal.GameRecord = .init()
        record.consecutiveFailures = 1

        let plan = RecoveryPlanner.plan(for: record,
                                        verdict: .crashed,
                                        diagnosis: nil,
                                        effective: .init(),
                                        requirements: .init(),
                                        usesDirect3DEleven: true)

        #expect(plan == .step(try #require(RecoveryPlanner.ladder.first)))
    }

    @Test("Nothing asks for an implementation no build here can provide")
    func nothingAsksForDXVK() {
        // Every rung and every remedy that names a Direct3D implementation has to name one a
        // build can actually be asked for. Nothing records whether a Wine has Vulkan, and the
        // build that ships DXMT says it has none in every transcript it writes, so a rung
        // asking for DXVK would move a game to something that cannot draw at all. This is also
        // the shape of the older fault: these used to change nothing whatsoever, because a
        // backend reached the profile and the badge and never the runtime the game was given.
        for step in RecoveryPlanner.ladder {
            #expect(step.graphicsBackend != .dxvk, "the rung \(step.id) asks for DXVK")
        }

        for signature in CrashDiagnosis.signatures {
            #expect(signature.remedy?.graphicsBackend != .dxvk,
                    "the remedy for \(signature.id) asks for DXVK")
        }
    }

    @Test("An entry naming an implementation reaches the ranking, not just the badge")
    func anEntrysBackendIsAPreference() {
        // The half that was missing for a while: `graphicsBackend` was set on the profile — the
        // game's page drew a badge from it — while the runtime went on being chosen from the
        // requirements alone. Every curated entry and every fix the app learned that named an
        // implementation promised a change nothing made.
        let entry: CompatibilityDatabase.Entry = .init(identifiers: [],
                                                       titles: ["Asphalt Legends"],
                                                       graphicsBackend: .direct3DMetal)

        let refined = RuntimeProfile.unknownGame.refined(by: entry)

        #expect(refined.graphicsBackend == .direct3DMetal)
        #expect(refined.requirements.preferredDirect3D == .direct3DMetal)
    }

    @Test("The asked-for implementation goes to the front of the ranking, and nothing is dropped")
    func preferenceReordersTheRanking() {
        func runtime(_ id: String) -> Runtime {
            .init(id: id, name: id, executableURL: .init(filePath: "/tmp/\(id)/wine64"), origin: .managed)
        }

        let dxmt = runtime("dxmt")
        let apple = runtime("apple")
        let plain = runtime("plain")
        let ranking = [dxmt, apple, plain]

        func provides(_ runtime: Runtime, _ backend: RuntimeProfile.GraphicsBackend) -> Bool {
            switch backend {
            case .dxmt:             runtime.id == "dxmt"
            case .direct3DMetal:    runtime.id == "apple"
            case .wined3d:          runtime.id == "plain"
            case .dxvk:             false
            }
        }

        #expect(Runtime.preferring(.direct3DMetal, in: ranking, provides: provides).map(\.id)
                == ["apple", "dxmt", "plain"])

        // Nothing is dropped, so a game asking for something this Mac hasn't got still gets the
        // ranking it would have had.
        #expect(Runtime.preferring(.dxvk, in: ranking, provides: provides).map(\.id)
                == ["dxmt", "apple", "plain"])
        #expect(Runtime.preferring(nil, in: ranking, provides: provides).map(\.id)
                == ["dxmt", "apple", "plain"])
    }

    @Test("The implementation already rendering the game is not offered as a change")
    func theBackendInUseIsNotOfferedAsAChange() {
        // Asked of the rule directly, because the ladder has no such rung today. Asphalt
        // Legends was already on DXMT: moving it to DXMT is a launch spent, a notification
        // sent, and nothing changed.
        let toMetal: RecoveryPlanner.Step = .init(id: "direct3d-on-metal",
                                                  describedAs: "Run Direct3D through Metal instead",
                                                  graphicsBackend: .dxmt)

        #expect(RecoveryPlanner.isAlreadyInEffect(toMetal, given: .init(), backend: .dxmt))
        #expect(!RecoveryPlanner.isAlreadyInEffect(toMetal, given: .init(), backend: .dxvk))

        // Not knowing which implementation ran is not the same as knowing it matches: an
        // unknown backend offers the rung rather than skipping the one that might have worked.
        #expect(!RecoveryPlanner.isAlreadyInEffect(toMetal, given: .init(), backend: nil))
    }

    @Test("A diagnosis beats the ladder, and is only ever tried once")
    func diagnosisWinsThenStepsAside() throws {
        let finding = try #require(CrashDiagnosis.diagnose(transcript: Self.bioshockAdapterCrash))

        var record: RecoveryJournal.GameRecord = .init()
        record.consecutiveFailures = 1

        #expect(RecoveryPlanner.plan(for: record,
                                     diagnosis: finding,
                                     effective: .init(),
                                     requirements: .init(),
                                     usesDirect3DEleven: false) == .remedy(finding))

        // Applied once. The same signature firing again means the remedy was wrong for this
        // game, and repeating it would be an infinite loop that looks like progress.
        record.signaturesActedOn.insert(finding.signature)

        let second = RecoveryPlanner.plan(for: record,
                                          diagnosis: finding,
                                          effective: .init(),
                                          requirements: .init(),
                                          usesDirect3DEleven: false)

        #expect(second != .remedy(finding))
    }

    @Test("The ladder never walks the same rung twice, and ends")
    func ladderIsFiniteAndNeverRepeats() {
        var record: RecoveryJournal.GameRecord = .init()
        record.consecutiveFailures = 1

        var walked: [String] = []

        // Everything on, so no rung is skipped for being already in effect.
        let effective: RuntimeProfile.SettingsOverride = .init(dxvk: true,
                                                               dxvkAsync: true,
                                                               retinaMode: true,
                                                               commandStreamThread: true,
                                                               captureDisplaysForFullscreen: false,
                                                               windowsVersion: .win11)

        while true {
            let plan = RecoveryPlanner.plan(for: record,
                                            diagnosis: nil,
                                            effective: effective,
                                            requirements: .init(thirtyTwoBit: true),
                                            usesDirect3DEleven: true)

            guard case .step(let step) = plan else { break }

            #expect(!walked.contains(step.id), "\(step.id) was walked twice")
            walked.append(step.id)
            record.stepsTried.insert(step.id)

            #expect(walked.count <= RecoveryPlanner.ladder.count + 1, "the ladder didn't end")
            if walked.count > RecoveryPlanner.ladder.count + 1 { break }
        }

        #expect(!walked.isEmpty)
        #expect(RecoveryPlanner.plan(for: record,
                                     diagnosis: nil,
                                     effective: effective,
                                     requirements: .init(thirtyTwoBit: true),
                                     usesDirect3DEleven: true) == .exhausted)
    }

    @Test("A rung that would change nothing is not spent")
    func skipsRungsAlreadyInEffect() {
        var record: RecoveryJournal.GameRecord = .init()
        record.consecutiveFailures = 1

        // Retina Mode is already off, which is what the first rung would set it to.
        let plan = RecoveryPlanner.plan(for: record,
                                        diagnosis: nil,
                                        effective: .init(retinaMode: false),
                                        requirements: .init(),
                                        usesDirect3DEleven: false)

        guard case .step(let step) = plan else {
            Issue.record("expected a rung, got \(plan)")
            return
        }

        #expect(step.id != "retina-off")
    }

    @Test("A 64-bit game is never offered a 32-bit Wine")
    func skipsRungsThatCannotApply() {
        var record: RecoveryJournal.GameRecord = .init()
        record.consecutiveFailures = 1
        record.stepsTried = Set(RecoveryPlanner.ladder.map(\.id)).subtracting(["native-thirty-two-bit"])

        #expect(RecoveryPlanner.plan(for: record,
                                     diagnosis: nil,
                                     effective: .init(),
                                     requirements: .init(thirtyTwoBit: false),
                                     usesDirect3DEleven: false) == .exhausted,
                "a rung that cannot apply to this game must not be offered, or it spends a crash on nothing")
    }

    // MARK: - What is learned

    @Test("Applying a remedy builds the entry a manifest would publish")
    func remedyBecomesAnEntry() throws {
        let finding = try #require(CrashDiagnosis.diagnose(transcript: Self.bioshockShaderCrash))
        let entry = try #require(RecoveryPlanner.entry(applying: .remedy(finding), to: nil, for: facts()))

        #expect(entry.identifiers.first?.storefront == .epicGames)
        #expect(entry.settings.dllOverrides?["d3dcompiler_43"] == "n,b")
        #expect(entry.winetricks.contains("d3dcompiler_47"))
        #expect(entry.note?.isEmpty == false, "an entry that can't explain itself is no use to anybody")
    }

    @Test("Each fix is added to the last, not substituted for it")
    func learningIsAdditive() throws {
        let adapter = try #require(CrashDiagnosis.diagnose(transcript: Self.bioshockAdapterCrash))
        let shader = try #require(CrashDiagnosis.diagnose(transcript: Self.bioshockShaderCrash))

        let first = try #require(RecoveryPlanner.entry(applying: .remedy(adapter), to: nil, for: facts()))
        let second = try #require(RecoveryPlanner.entry(applying: .remedy(shader), to: first, for: facts()))

        // BioShock needed both. An entry that forgot the first one while finding the second is
        // an entry that never converges.
        #expect(second.settings.dllOverrides?["atiadlxx"] == "d")
        #expect(second.settings.dllOverrides?["d3dcompiler_43"] == "n,b")
    }

    // MARK: - Where learned settings sit

    @Test("A curated entry outranks a learned one, field by field")
    func curatedBeatsLearned() {
        let learned: CompatibilityDatabase.Entry = .init(
            identifiers: [.init(storefront: .gog, id: "1")],
            titles: ["Game"],
            settings: .init(retinaMode: true, dllOverrides: ["atiadlxx": "d"]),
            winetricks: ["d3dcompiler_47"]
        )

        let curated: CompatibilityDatabase.Entry = .init(
            identifiers: [.init(storefront: .gog, id: "1")],
            titles: ["Game"],
            requiresNativeThirtyTwoBit: true,
            settings: .init(retinaMode: false)
        )

        let merged = learned.overlaid(with: curated)

        // Somebody read the logs to write the curated entry.
        #expect(merged.settings.retinaMode == false)

        // And it said nothing about these, so the local findings survive rather than being
        // thrown away by a partial curated answer.
        #expect(merged.settings.dllOverrides?["atiadlxx"] == "d")
        #expect(merged.winetricks.contains("d3dcompiler_47"))
        #expect(merged.requiresNativeThirtyTwoBit == true)
    }

    // MARK: - What a report may carry

    @Test("A report carries no credential, no username and no home path")
    func reportIsScrubbed() {
        let dirty = [
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdef",
            "err:module:import_dll opening \(NSHomeDirectory())/Games/Game.exe",
            "cookie: session=abc123; other=def456"
        ]

        let cleaned = CrashReport.evidence(from: dirty)
        let joined = cleaned.joined(separator: "\n")

        #expect(!joined.contains("eyJhbGciOiJIUzI1NiJ9"), "a JWT survived redaction")
        #expect(!joined.contains(NSHomeDirectory()), "an absolute home path survived scrubbing")
        #expect(!joined.contains("session=abc123"), "a cookie value survived redaction")

        if NSUserName().count > 2 {
            #expect(!joined.contains(NSUserName()), "the account's short name survived scrubbing")
        }
    }

    @Test("Evidence is capped in both directions")
    func reportEvidenceIsBounded() {
        let many = (0..<200).map { "wine: Unhandled page fault number \($0)" }
        #expect(CrashReport.evidence(from: many).count == CrashReport.evidenceLineLimit)

        let long = [String(repeating: "x", count: 10_000)]
        let capped = CrashReport.evidence(from: long).first ?? ""
        #expect(capped.count <= CrashReport.evidenceLineLength + 1)
    }

    @Test("Two reports of the same fault share a key, and different faults don't")
    func reportDeduplication() {
        func report(signature: String?, runtime: String) -> CrashReport {
            .init(kind: .unrecognisedCrash,
                  installID: "install",
                  appVersion: "1.0",
                  systemVersion: "macOS 15",
                  model: "Mac15,3",
                  game: .init(storefront: "gog", id: "1", title: "Game"),
                  runtimeID: runtime,
                  runtimeVersion: "11.16.0",
                  settings: .init(),
                  winetricks: [],
                  verdict: .crashed,
                  ranForSeconds: 3,
                  signature: signature,
                  stepsTried: [],
                  evidence: [])
        }

        #expect(report(signature: nil, runtime: "a").deduplicationKey
                == report(signature: nil, runtime: "a").deduplicationKey)

        #expect(report(signature: nil, runtime: "a").deduplicationKey
                != report(signature: nil, runtime: "b").deduplicationKey,
                "the same fault on a different Wine build is a different report")
    }

    @Test("A report is reviewable before it is sent")
    func reportIsReadable() {
        let report: CrashReport = .init(kind: .optionsExhausted,
                                        installID: "install",
                                        appVersion: "1.0",
                                        systemVersion: "macOS 15",
                                        model: "Mac15,3",
                                        game: .init(storefront: "epicGames", id: "1", title: "Game"),
                                        runtimeID: "managed:wine-dxmt-11.16",
                                        runtimeVersion: "11.16.0",
                                        settings: .init(retinaMode: false),
                                        winetricks: ["d3dcompiler_47"],
                                        verdict: .crashed,
                                        ranForSeconds: 12,
                                        signature: nil,
                                        stepsTried: ["retina-off"],
                                        evidence: ["wine: Unhandled page fault"])

        // Nobody can consent to sending something they have not been shown, so the text shown
        // has to be the text sent.
        let text = report.reviewableText
        #expect(text.contains("optionsExhausted"))
        #expect(text.contains("managed:wine-dxmt-11.16"))
        #expect(!text.contains("couldn't be prepared"))
    }

    @Test("The install id says nothing about the machine")
    func installIDIsNotAHardwareIdentifier() {
        let identifier = CrashReport.installID

        #expect(UUID(uuidString: identifier) != nil || identifier == "unknown",
                "the install id has to be a random UUID, not something derived from the Mac")
        #expect(!identifier.contains(CrashReport.hardwareModel) || CrashReport.hardwareModel.isEmpty)
    }
}
