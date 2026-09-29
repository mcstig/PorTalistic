#!/bin/bash
#
#  check-invariants.sh
#  PorTalistic
#
#  Created by Claude Opus 5 on 15/9/2026.
#
#  The regressions a unit test cannot see.
#
#  Some of the faults that kept coming back are not about a value being wrong — they are
#  about a rule existing in two places, or about something appearing where it must never
#  appear. No amount of `#expect` catches a second copy of a hardcoded button, or a
#  `FileManager` call added to a view that draws three hundred times a second. Those are
#  properties of the source, so they are checked against the source.
#
#  Usage:
#      Scripts/check-invariants.sh            # fails (exit 1) on any violation
#      Scripts/check-invariants.sh --warn     # reports as Xcode warnings, always exits 0
#
#  Every check below names the fault it stands for. If one of them ever fires for a change
#  that is genuinely correct, change the check in the same commit and say why — a check
#  nobody trusts is worse than no check.

set -u

cd "$(dirname "$0")/.." || exit 1

PREFIX="error"
EXIT_ON_FAILURE=1
if [ "${1:-}" = "--warn" ]; then
    PREFIX="warning"
    EXIT_ON_FAILURE=0
fi

FAILURES=0
CHECKS=0

# Xcode only recognises `file:line: warning: …` and a bare `warning: …`, so anything without
# a line number is reported in the second form — otherwise the build phase's output is just
# text nobody sees.
report() {
    # report <file> <message>
    if [ "$PREFIX" = "warning" ]; then
        echo "warning: $1: $2"
    else
        echo "$1: error: $2"
    fi
    FAILURES=$((FAILURES + 1))
}

report_at() {
    # report_at <file> <line> <message>
    echo "$1:$2: $PREFIX: $3"
    FAILURES=$((FAILURES + 1))
}

check_absent() {
    # check_absent <description> <pattern> <path...>
    #
    # Swift only: the grep below carries `--include='*.swift'`. A caller handing this a
    # `.json`, a `.plist` or the project file used to get a silent pass, which is worse than
    # no check at all — so it is an error now.
    local description="$1"; shift
    local pattern="$1"; shift
    CHECKS=$((CHECKS + 1))

    local candidate
    for candidate in "$@"; do
        case "$candidate" in
            *.swift|*/) ;;
            *)
                if [ -f "$candidate" ]; then
                    report "$candidate" "check_absent was given a non-Swift path and only searches *.swift, so this check silently inspected nothing"
                fi
                ;;
        esac
    done

    local hits
    hits=$(grep -rn --include='*.swift' -E "$pattern" "$@" 2>/dev/null)
    [ -z "$hits" ] && return 0

    # A here-string rather than a pipe, so the counter increments in this shell.
    local hit rest
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        rest="${hit#*:}"
        report_at "${hit%%:*}" "${rest%%:*}" "$description"
    done <<< "$hits"

    return 1
}

check_count() {
    # check_count <file> <expected> <description> <pattern>
    local file="$1" expected="$2" description="$3" pattern="$4"
    CHECKS=$((CHECKS + 1))

    local found
    found=$(grep -cE "$pattern" "$file" 2>/dev/null)
    [ -n "$found" ] || found=0

    if [ "$found" != "$expected" ]; then
        report "$file" "$description (found $found, expected $expected)"
        return 1
    fi
    return 0
}

check_present() {
    # check_present <file> <description> <pattern>
    local file="$1" description="$2" pattern="$3"
    CHECKS=$((CHECKS + 1))

    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        report "$file" "$description"
        return 1
    fi
    return 0
}

echo "▸ Checking source invariants"

# ── The Retina Mode / DPI pairing ────────────────────────────────────────────
# Horizon Chase Turbo opened in a quarter-size window three times. Each time a prefix's DPI
# and its Retina Mode disagreed; each time the rule was fixed in one of the three places
# that had a copy of it.
DPI_COPIES=$(grep -rn --include='*.swift' -E '192 *: *96' PorTalistic | grep -v 'WineInterface+Container.swift')
CHECKS=$((CHECKS + 1))
if [ -n "$DPI_COPIES" ]; then
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        rest="${hit#*:}"
        report_at "${hit%%:*}" "${rest%%:*}" "the Retina/DPI pairing belongs only in Wine.Container.Settings.displayScaling(forRetinaMode:) — a second copy is what let the small window come back"
    done <<< "$DPI_COPIES"
fi

check_present "PorTalistic/Utilities/Wine/WineInterface+Container.swift" \
    "Retina Mode must default to off: on, a game that doesn't ask for a full-backing-resolution desktop renders into one corner of it and blanks the other display" \
    'retinaMode: Bool = false'

check_present "PorTalistic/Utilities/Wine/WineInterface+Container.swift" \
    "the single source for the DPI that accompanies Retina Mode has gone missing" \
    'static func displayScaling\(forRetinaMode'

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "toggleRetinaMode must derive the DPI rather than restate it" \
    'displayScaling\(forRetinaMode: toggle\)'

# ── The environment every wine process is handed ─────────────────────────────
# A caller that assembled its own environment left WINEMSYNC out; wineserver reads it once
# at startup and then serves the prefix long after that process is gone, so the next launch
# died in msync_init against a server it had no way to know about.
check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "the wine-mono and mshtml overrides are what stop a fresh prefix's wineboot waiting forever on a modal dialog nothing will click" \
    'baseDLLOverrides: String = "mscoree=d;mshtml=d"'

# Stronger than "the DXVK line must extend the base overrides", which is what this checked
# before the string became a composed list: `WINEDLLOVERRIDES` is one string, and the fault was
# a *second assignment* silently discarding the first. One assignment, built from parts.
check_count "PorTalistic/Utilities/Wine/WineInterface.swift" 1 \
    "WINEDLLOVERRIDES must be assigned exactly once, from the composed list — a second assignment is what let wineboot ask for wine-mono again" \
    'environmentVariables\["WINEDLLOVERRIDES"\] ='

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "DXVK must append to the override list rather than rewrite it" \
    'dllOverrides\.append\("dxgi,d3d10core,d3d11=n,b"\)'

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "a game's own DLL overrides have to be applied last, or a curated entry cannot override anything above it" \
    'overrides\.dllOverrides'

check_absent "WINEMSYNC and WINEDLLOVERRIDES are assembled in one place (Wine.assembleEnvironmentVariables) — a hand-built environment is how a launch ends up disagreeing with the running wineserver" \
    '"(WINEMSYNC|WINEDLLOVERRIDES)"\] *=' \
    PorTalistic/Utilities/Compatibility PorTalistic/Utilities/GameManager PorTalistic/Views

# Nothing puts a container's registry back after a launch. `legendary` spawns Wine detached
# from itself and returns, so there is no moment on that path that means "the game exited" —
# the revert landed while the game was still starting, turned Retina Mode back on under it,
# and the game wrote the resulting 4096x2660 desktop into its own saved settings.
check_absent "nothing may put a container's registry back after a launch: there is no moment on the Epic path that means \"the game exited\", so a revert lands under a live game — and the next launch states its own whole answer anyway" \
    'pendingReverts|reverts\.append|Provisioner\.shared\.revert' \
    PorTalistic/Utilities PorTalistic/Views

check_present "PorTalistic/Utilities/Migrator.swift" \
    "changing a default does nothing to containers already on disk — every one in the field was still stored Retina-on, so the migration that brings them forward has to exist" \
    'settingsMigratedOffRetina'

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "booting a container must stay bounded: wineboot does not return while a dialog is up, and an unbounded wait is two wine icons in the Dock and a game that never appears" \
    'runWrapped\(timeout: \.seconds\(300\)\)'

# ── One control, one implementation ─────────────────────────────────────────
# The install/play control was rebuilt as ActionIconButton and then left hardcoded a second
# time on the Home hero, so the same button behaved two ways in one app.
check_absent "the install/play control is ActionIconButton and only ActionIconButton — a second implementation is a control that behaves two ways in one app" \
    'struct (PlayButton|InstallButton|PrimaryActionButton|ButtonsView)' \
    PorTalistic/Views

for surface in \
    PorTalistic/Views/Unified/Components/GameCard/GameCard.swift \
    PorTalistic/Views/Unified/Components/GameCard/ListGameCard.swift \
    PorTalistic/Views/Navigation/GameDetailView.swift \
    PorTalistic/Views/Navigation/HomeView.swift
do
    check_present "$surface" \
        "every surface that offers install or play uses the shared ActionIconButton" \
        'ActionIconButton'
done

# ── A launch has to record what it launched with ───────────────────────────
# Three diagnoses in one week turned on "was that override actually set?", and there was no way
# to answer it after the fact. A DLL override that never reached the process and a native DLL
# that reached it and failed to load look identical from the outside — Wine falls back to its
# builtin either way and says nothing — and they need different fixes.
check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "a launch transcript has to record the environment it launched with, or an override that silently did nothing cannot be told from one that was never set" \
    'static func environmentSummary'

check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "the Epic transcript has to record its environment too — it is the path where the process that launches is not the process that runs" \
    'Wine\.environmentSummary'

# ── A game the person asked for comes to the front ─────────────────────────
# The hand-off existed and was wired into the GOG path only, so Epic games — most of a real
# library — opened behind the window the person had just pressed Play in. It is also not
# only about focus: Wine's Mac driver records a display-mode change and applies it when its
# process next becomes active, so a game left behind comes up windowed whatever its settings
# say. Second time a shared implementation reached some call sites and not others; see the
# action-button check above for the first.
for launcher in \
    PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift \
    PorTalistic/Utilities/GameManager/GOGGameManager.swift \
    PorTalistic/Utilities/GameManager/LocalGameManager.swift
do
    check_present "$launcher" \
        "every path that starts a Windows game has to follow it: the foreground hand-off (Wine's Mac driver defers the display mode until its process is active, and the person pressed Play) and the launch's whole lifetime — without this the operation ends with legendary, seconds after Play, while the game is still loading" \
        'superviseGame\(named: [a-zA-Z]'
done

# ── Stop has to stop the game, and a launch has to be escapable ────────────
# `waitUntilExit()` blocks its thread and knows nothing about tasks, so a launch sitting in it
# ignored cancellation entirely: Stop set the flag, nothing read it, and the game's entry
# stayed on "launching" for as long as the process lived. And terminating the process this app
# started does not stop the game — `legendary` spawns Wine detached, and even on the paths
# where the process *is* Wine the game is a descendant of it.
for launcher in \
    PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift \
    PorTalistic/Utilities/GameManager/GOGGameManager.swift \
    PorTalistic/Utilities/GameManager/LocalGameManager.swift
do
    check_present "$launcher" \
        "a launch must wait for the game in a way a cancelled task can escape, or Stop cannot work" \
        'waitUntilExitOrCancellation'

    check_present "$launcher" \
        "cancelling a launch has to stop the prefix the game runs in, from the moment it is cancelled: terminating the process this app started leaves the game running" \
        'forceQuit\??\.begin\(\)'

    check_present "$launcher" \
        "the game is followed by a child task of the launch (async let), never a detached one: a detached task outlives the launch that made it, so force-quitting a game from Operations would leave the watch running with nothing to report to" \
        'async let supervised'
done

# ── Nothing on the render path touches the disk ─────────────────────────────
# Cards draw hundreds of times a second while scrolling, and reaching for a path on a
# removable volume is what made macOS ask for permission mid-scroll.
# Only the files whose bodies run once per card per frame. The sheets, menus and the
# custom-thumbnail importer live next door in `GameCard+*.swift` and are allowed to touch
# the disk — they run when someone asks them to, not while a list is moving.
check_absent "nothing a card draws may touch the filesystem: a card is re-drawn hundreds of times a second, and reaching for a path on a removable volume is what makes macOS ask for permission while scrolling" \
    'FileManager\.default|fileExists\(|contentsOfDirectory|Data\(contentsOf:' \
    PorTalistic/Views/Unified/Components/GameCard/GameCard.swift \
    PorTalistic/Views/Unified/Components/GameCard/ListGameCard.swift \
    PorTalistic/Views/DesignSystem/GameArtwork.swift

# ── Filters are judged against the unfiltered library ──────────────────────
# Gating the toolbar on the filtered result removed the only controls that could undo a
# filter that matched nothing.
check_present "PorTalistic/Views/Navigation/LibraryView.swift" \
    "the toolbar's filter controls must be gated on hasAnyGames(inStorefront:), never on the filtered result — otherwise a filter matching nothing removes the only way out of it" \
    'hasAnyGames\(inStorefront:'

check_absent "anything the user picks from must iterate Game.Storefront.available, not allCases — Steam is hidden and has no games, so offering it is offering a filter whose only effect is to empty the library" \
    'Storefront\.allCases' \
    PorTalistic/Views

# ── Nothing at startup reads an external volume ────────────────────────────
check_present "PorTalistic/Utilities/Compatibility/Provisioner.swift" \
    "provisioning at launch must skip games on external volumes, or the app asks for removable-volume access every time it opens" \
    'isOnAnExternalVolume'

check_present "PorTalistic/Utilities/Extensions/Built-in/URL+Extensions.swift" \
    "isOnAnExternalVolume has to stay a path test — asking the volume about itself is the thing that raises the permission prompt" \
    'resolvingSymlinksInPath\(\)\.pathComponents'

# ── The self-built Wine has to name a freetype it can find ─────────────────
check_present "Compatibility/build-dxmt-wine.sh" \
    "the build must compile a resolvable freetype install name into win32u.so, or every game renders without text" \
    '@loader_path/\.\./\.\./\.\./Frameworks/libfreetype\.6\.dylib'

check_present "Compatibility/build-dxmt-wine.sh" \
    "the build must verify the soname it compiled in, rather than trusting that it worked" \
    'win32u\.so'

# ── A launch lasts as long as the game ────────────────────────────────────
# Four faults out of one fact: the launch operation used to end with the process this app
# started, which on the Epic path is legendary exiting seconds after Play.
check_present "PorTalistic/Views/Unified/Components/GameCard/GameCard+Extensions.swift" \
    "the Play button's spinner follows the game's own phase, never a timer — a fixed six seconds stopped it while the game was still loading, and let a second press start a second copy" \
    'launchOperation\?\.launchPhase'

# Quitting cancels what writes to disk. It must not cancel the launches that now keep running
# games in the queue: that would force-quit the game being played, which is the "Force quit all
# games when PorTalistic closes" setting's decision and nobody else's.
check_absent "quitting stops file operations only (GameOperationManager.stopFileOperationsForQuit) — cancelling every operation now force-quits the game being played" \
    'cancelAllOperations' \
    PorTalistic

check_present "PorTalistic/AppDelegate.swift" \
    "quitting has to wait for the downloads it stops, or legendary and gogdl never write down where they got to and the next launch starts from nothing" \
    'stopFileOperationsForQuit'

# ── An interrupted install is picked up, not lost ─────────────────────────
# Closing the app mid-download left the download running, orphaned: it finished with nothing to
# report it, and reopening showed a game that was neither installed nor installing.
for installer in \
    PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift \
    PorTalistic/Utilities/GameManager/GOGDLInterface.swift
do
    check_present "$installer" \
        "an install has to be noted before it starts, or one stopped by quitting cannot be picked up on the next launch" \
        'PendingInstalls\.remember'
done

check_present "PorTalistic/AppDelegate.swift" \
    "something has to pick interrupted installs back up, once the library has loaded" \
    'PendingInstalls\.resumeInterrupted'

# ── Nothing this app starts may outlive it ────────────────────────────────
# Found on a real machine: legendary still installing a game, with eighteen workers under it,
# started by a build that had quit long before — downloading where nothing could see it, and
# holding the installed-games lock that made the next launch's resumed install fail in a modal.
for runner in \
    PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift \
    PorTalistic/Utilities/GameManager/GOGDLInterface.swift
do
    check_present "$runner" \
        "every tool this app runs has to be known about while it runs, or quitting cannot be sure it is gone" \
        'ChildProcesses\.register'
done

check_present "PorTalistic/Utilities/GameOperation/GameOperationManager.swift" \
    "quitting ends by making sure: a download still shutting down when the app terminates carries on without it" \
    'ChildProcesses\.stopSurvivors'

check_present "PorTalistic/AppDelegate.swift" \
    "opening has to stop what an earlier session left running, before anything new starts" \
    'ChildProcesses\.stopOrphans'

check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "installing, updating and repairing must wait for legendary's installed-games lock rather than failing on it — it refuses outright, and this app races itself for it" \
    'executeStreamedWaitingForLock\(arguments:'

# ── One Stop, one rule ────────────────────────────────────────────────────
# An install the person stops is not resumed next launch; one stopped by quitting is. That
# difference lives in GameOperationManager.cancel(_:), so nothing in the interface may cancel an
# operation behind its back.
check_absent "every Stop in the interface goes through GameOperationManager.cancel(_:) — cancelling the operation directly skips the rule that decides whether an install comes back" \
    'operation\.cancel\(\)' \
    PorTalistic/Views

# ── Only work on a game's files moves it up the library ───────────────────
check_present "PorTalistic/Views/Unified/Models/GameListViewModel.swift" \
    "the front of the library is for games being written to, not games being played — a launch is an operation too, and it now lasts as long as the game" \
    'isExecuting && \$0\.type\.modifiesFiles'

# ── The app is called PorTalistic wherever its name can be read ────────────
# Force Quit listed a running game as "BioshockHD.exe (Mythic)". The engine's Mac driver names
# every Windows process after upstream, from a string compiled into winemac.drv, and
# Wine.ApplicationNaming corrects it once the process has a window — which it only does if
# something starts it.
check_present "PorTalistic/AppDelegate.swift" \
    "Wine.ApplicationNaming has to be started at launch, or every Windows program keeps the engine's \"(Mythic)\" in Force Quit, the Dock and ⌘-Tab" \
    'Wine\.ApplicationNaming\.shared\.start\(\)'

# The same fault in the app's own strings, found in the same sweep: the move-to-Applications
# alert, the quit warning and the Discord status all still said Mythic after the rename.
# Upstream's name belongs only where it credits upstream, where it names the engine (upstream's,
# and it keeps its name — see Branding.swift), or where the migration moves data from.
CHECKS=$((CHECKS + 1))
UPSTREAM_NAME=$(grep -rn --include='*.swift' -E '"[^"]*Mythic[^"]*"' PorTalistic Preflight.swift 2>/dev/null \
    | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*//' \
    | grep -v -E 'Mythic Engine|Mythic.s (Wine|Author|Game Compatibility)|Mythic on GitHub|fork of Mythic|Mythic, by vapidinfinity|Built on Mythic|MythicApp/Mythic|blackxfiied\.Mythic|previousApplicationSupportName|database Mythic maintains')
if [ -n "$UPSTREAM_NAME" ]; then
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        rest="${hit#*:}"
        report_at "${hit%%:*}" "${rest%%:*}" "this string calls the app Mythic — say \\(Branding.name). Upstream's name is for credits, the engine's name and the migration's source only"
    done <<< "$UPSTREAM_NAME"
fi

# Apple's D3DMetal is never the automatic answer. `D3DMetal.framework` arrives in the Game
# Porting Toolkit evaluation environment and is present inside the bundled engine, so a
# ranking that puts it ahead of anything makes a shippable default out of something that may
# not be distributable. Last, not absent — a Mac that already has it can still reach it.
check_present "PorTalistic/Utilities/Compatibility/RuntimeSelection.swift" \
    "Apple's D3DMetal has to rank last for a Direct3D-on-Metal game, behind wined3d — it is Apple's, it comes from the Game Porting Toolkit evaluation environment, and nothing should choose it automatically" \
    '^        dxmt \+ wined3d \+ appleD3DMetal$'

# ── Crash recovery ─────────────────────────────────────────────────────────
#
# An automatic process that reconfigures a game after a crash is one bug away from breaking a
# game that works, and one bug away from putting a session token on somebody else's server.
# Both failures are silent. These are the guards that are not expressible as a unit test.

# One set of thresholds. "How long is long enough to call a session clean" appears in the
# classifier, the planner and the tests, and three answers to it is three policies.
check_count "PorTalistic/Utilities/Compatibility/LaunchOutcome.swift" 1 \
    "confirmedGoodAfter has to be declared exactly once — a second copy is a second definition of \"this configuration works\"" \
    '^    static let confirmedGoodAfter'

check_absent "a recovery threshold is written out as a literal instead of coming from RecoveryPolicy" \
    'ranFor (>|>=) [0-9]|ranForSeconds (>|>=) [0-9]' \
    PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift \
    PorTalistic/Utilities/Compatibility/RecoveryPlanner.swift

check_count "PorTalistic/Utilities/Compatibility/LaunchOutcome.swift" 1 \
    "tooShortToBeASession has to be declared exactly once — a second copy is a second definition of \"that was not a session\"" \
    '^    static let tooShortToBeASession'

# The failure that looks like success. A game that opens, decides the machine will not do and
# closes again is not a crash and did start, so nothing in one launch says anything is wrong —
# and the app watched Asphalt Legends do it, ten seconds at a time, and changed nothing, for as
# many launches as it was given. The history is what makes it visible, so the history has to be
# counted and it has to reach the classifier.
check_present "PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift" \
    "the verdict is read without the game's history again, so a game that opens and closes itself every time is filed as somebody changing their mind and nothing is ever changed" \
    'shortSessionsInARow: record\.consecutiveShortSessions'

check_present "PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift" \
    "the run of too-short sessions is being counted at the call site again; it is a decision with three exclusions and it belongs in RecoveryPolicy, where the suite can ask it questions" \
    'RecoveryPolicy\.shortSessionsInARow\('

# A rung or a remedy that sets `graphicsBackend` used to change nothing: it reached the learned
# entry, the profile and the badge on the game's page, and never the runtime the game was given,
# which was chosen from the game's requirements alone. These three checks are that wiring — the
# entry's backend becoming a preference, the ranking reading it, and a build being able to say
# whether it provides one. Break any of them and every such rung and remedy is theatre again.
check_present "PorTalistic/Utilities/Compatibility/RuntimeProfile.swift" \
    "an entry naming a Direct3D implementation reaches the badge and not the ranking again, so every rung and remedy that asks for one changes nothing" \
    'refined\.requirements\.preferredDirect3D = backend'

check_present "PorTalistic/Utilities/Compatibility/RuntimeSelection.swift" \
    "the ranking no longer reads the asked-for Direct3D implementation, so a game sent to one stays where it was" \
    'preferring\(requirements\.preferredDirect3D'

check_present "PorTalistic/Utilities/Compatibility/RuntimeSelection.swift" \
    "nothing can say which Direct3D implementation a build provides, which is what a preference is matched against" \
    'func provides\(_ backend: RuntimeProfile\.GraphicsBackend\)'

# Nothing records whether a Wine build has Vulkan, and the build that ships DXMT says it has
# none in every transcript it writes — so asking for DXVK moves a game to something that cannot
# draw at all.
check_absent \
    "asks for DXVK, which nothing here can provide: no build records whether it has Vulkan, and the one shipping DXMT was built without it" \
    '^[^/]*graphicsBackend: \.dxvk' \
    PorTalistic/Utilities/Compatibility/RecoveryPlanner.swift \
    PorTalistic/Utilities/Compatibility/CrashDiagnosis.swift

# "Nothing ever appeared" is the strongest signal the loop has, and it was unreachable: the
# supervision waits a minute for the game to turn up, so a launch where nothing did always lasted
# at least that long — and the threshold for calling it a no-show was forty-five seconds.
check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "the wait for a game to appear is a literal again, so the verdict that judges it can drift below it and never fire" \
    'static let arrivalDeadline: TimeInterval'

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "the foreground hand-off no longer uses Wine.arrivalDeadline, so its wait and the verdict that judges it are two numbers again" \
    '\.seconds\(arrivalDeadline\)'

check_present "PorTalistic/Utilities/Compatibility/LaunchOutcome.swift" \
    "neverStartedWithin is a literal again; below the wait it judges, 'nothing ever appeared' can never be concluded at all" \
    'Wine\.arrivalDeadline \+'

# And the other half of it: the supervision stops watching when nothing turned up, which is not
# the same as the game not being there. Without this the loop reconfigures a large game while the
# person is watching it load.
check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "the post-mortem no longer asks whether anything is still running, so a game still on its way to the screen is judged as one that never started" \
    'outcome\.stillRunning = await anythingRunning\(under:'

check_present "PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift" \
    "the run of short sessions is counted without asking whether the game was still running, so a game the app merely stopped watching counts as one that refused to run" \
    'stillRunning: outcome\.stillRunning'

# BSD ps truncates its last column to the terminal width and uses 79 characters when there
# isn't one — which is how a GUI app runs it. A path longer than that is then never found, the
# answer is "nothing is running" for ever, and nothing says so.
check_present "PorTalistic/Utilities/ChildProcesses.swift" \
    "ps is asked without -ww again; its output is truncated to 79 characters with no terminal, so a runtime path longer than that is never matched and everything looks stopped" \
    '"-Axww"'

check_present "PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift" \
    "the rule for shutting a prefix down is back inline; it kills every process in a container that may be serving a game somebody is playing" \
    'RecoveryPolicy\.mayKillWineserver\('

# ── Force Quit is final ────────────────────────────────────────────────────
# Pressed while a game was starting, Force Quit found nothing to stop — the process hadn't been
# started yet — and the launch carried on and started the game; the supervision went on looking
# for its window for the rest of a minute, without pausing, on the main actor; and the recovery
# loop then judged the launch a no-show and reconfigured the game for having been stopped.
for path in \
    PorTalistic/Utilities/GameManager/GOGGameManager.swift \
    PorTalistic/Utilities/GameManager/LocalGameManager.swift \
    PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift
do
    check_present "$path" \
        "this launch path starts its process outside a StoppableLaunch, so a Force Quit pressed before the launch finds nothing to stop and the game starts anyway" \
        'try launch\.launch\(process\)'

    check_present "$path" \
        "this launch path asks a force-quit game to stop instead of killing it; SIGTERM lets legendary finish handing the game to Wine" \
        'StoppableLaunch = \.init\(halting: \{ \$0\.stopIfRunning\(SIGKILL\) \}\)'

    check_present "$path" \
        "this launch path ends a Force Quit without waiting for the passes its cancellation began; Play comes back while a Wine process that was still starting survives, or while the second pass is still on its way" \
        'await forceQuit\??\.finish\(\)'
done

check_absent \
    "a launch path starts its process directly again; nothing then stops a Force Quit pressed before the launch from starting the game" \
    '^[^/]*try process\.run\(\)' \
    PorTalistic/Utilities/GameManager/GOGGameManager.swift \
    PorTalistic/Utilities/GameManager/LocalGameManager.swift

check_count "PorTalistic/Utilities/Compatibility/Provisioner.swift" 3 \
    "setting a container up for a launch no longer stops between steps for a Force Quit, so every remaining step runs and then the game starts" \
    'try await stopIfForceQuit\(killing: container\.url\)'

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "the wait for a game's window ignores Force Quit again: it looks for the rest of its minute, without pausing, and hands the front to a game somebody has just stopped" \
    'guard !Task\.isCancelled else \{ return ours \}'

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "a launch the person force-quit is judged by the recovery loop again; a stopped launch reads as a no-show, and the game is reconfigured for having been closed" \
    'if Task\.isCancelled, !RecoveryPolicy\.judgesForceQuit'

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "a winetricks verb interrupted by a Force Quit is recorded as a verb that failed" \
    'catch let error where error is CancellationError \|\| Task\.isCancelled'

check_present "PorTalistic/Utilities/GameOperation/GameOperationManager.swift" \
    "pressing Force Quit no longer changes what a launch says about itself, so it goes on reading 'Starting' while it is being killed" \
    'operation\.isForceQuitting = true'

# What a cancelled step throws is not always a CancellationError — a runtime download throws
# URLError(.cancelled), legendary's output read after the kill can hold an ERROR line — and every
# other error became an alert saying the launch had failed.
check_present "PorTalistic/Utilities/GameOperation/GameOperation.swift" \
    "an error thrown by an operation that has been cancelled is reported as a failure again; a Force Quit comes up as an alert saying the launch failed" \
    'catch let error where Task\.isCancelled \|\| self\.isCancelled'

# A cancel between start()'s check and the task existing found nothing to cancel, and the launch
# ran with nothing in it able to tell. One side records under the lock and then looks at the flag;
# the other flags first and then looks under the lock.
check_present "PorTalistic/Utilities/GameOperation/GameOperation.swift" \
    "start() no longer looks for a cancel that arrived before its task was recorded; a Force Quit pressed as a launch is queued is lost and the game starts" \
    'if cancelledMeanwhile \{ task\.cancel\(\) \}'

OPERATION_FILE="PorTalistic/Utilities/GameOperation/GameOperation.swift"
FLAG_LINE=$(awk '/override func cancel\(\)/ { inside = 1 } inside && /super\.cancel\(\)/ { print NR; exit }' "$OPERATION_FILE")
LOOK_LINE=$(awk '/override func cancel\(\)/ { inside = 1 } inside && /taskLock\.withLock \{ task \}\?\.cancel\(\)/ { print NR; exit }' "$OPERATION_FILE")
CHECKS=$((CHECKS + 1))
if [ -z "$FLAG_LINE" ] || [ -z "$LOOK_LINE" ] || [ "$FLAG_LINE" -ge "$LOOK_LINE" ]; then
    report "$OPERATION_FILE" \
        "cancel() no longer flags the operation before looking for its task under the lock; a cancel that lands while start() is recording the task can be seen by neither side"
fi

# One wineserver -k, built in one place, able to start: inherited environment, WINEPREFIX, and the
# runtime's own library path — without which a Wineskin-derived engine's wineserver dies in dyld
# and the kill silently does nothing.
check_count "PorTalistic/Utilities/Wine/WineInterface.swift" 1 \
    "a wineserver -k is being built outside serverKill(by:prefix:) again; the copies drift, and the one without the runtime's library path kills nothing" \
    '\["-k"\]'

check_count "PorTalistic/Utilities/Wine/WineInterface.swift" 3 \
    "killAll, shutdownPrefix and Force Quit's own pass must all build their wineserver -k through serverKill(by:prefix:)" \
    'serverKill\(by: '

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "wineserver -k is started without the runtime's library path again; a Wineskin-derived engine's server dies in dyld before it can kill anything" \
    'environment\.merge\(supportLibraryEnvironment\(forRuntimeAt: runtimeRoot\)'

# Force Quit's passes are waited for, on a task that isn't cancelled — on the launch's own task a
# sleep and a wait for a process both return at once.
check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "Force Quit's first pass is no longer the container's own wineserver, waited for; the launch can end, and Play come back, with the kill still on its way" \
    'await Wine\.stopServer\(ofContainerAt: url\)'

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "Force Quit's second pass no longer asks every runtime's wineserver; a prefix held by another build of Wine keeps its game" \
    'await Wine\.shutdownPrefix\(at: url\)'

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "Force Quit runs on the launch's cancelled task again, where its pause and its waits all return at once" \
    'await Task\.detached\(priority: \.userInitiated\) \{'

# winetricks is a shell script; a Force Quit that only ended the wait let it run to the end of its
# verb. It is launched stoppably, and stopped with everything it started.
check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "winetricks is no longer stopped with its children; a Force Quit leaves the step it was on running" \
    'StoppableLaunch = \.init\(halting: \{ \$0\.killTree\(\) \}\)'

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "winetricks is launched outside its StoppableLaunch again; a Force Quit ends the wait and leaves the script running" \
    'runStreamed\(throwsOnChunkError: false, launchingWith: launch\)'

PROCESS_EXTENSIONS="PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift"
TREE_GUARD=$(awk '/func killTree\(\)/ { inside = 1 } inside && /guard pid > 1, isRunning else \{ return \}/ { print NR; exit }' "$PROCESS_EXTENSIONS")
TREE_STOP=$(awk '/func killTree\(\)/ { inside = 1 } inside && /kill\(pid, SIGSTOP\)/ { print NR; exit }' "$PROCESS_EXTENSIONS")
TREE_COUNT=$(awk '/func killTree\(\)/ { inside = 1 } inside && /ChildProcesses\.descendants\(of: pid\)/ { print NR; exit }' "$PROCESS_EXTENSIONS")
TREE_KILL=$(awk '/func killTree\(\)/ { inside = 1 } inside && /stopIfRunning\(SIGKILL\)/ { print NR; exit }' "$PROCESS_EXTENSIONS")
CHECKS=$((CHECKS + 1))
if [ -z "$TREE_GUARD" ] || [ -z "$TREE_STOP" ] || [ -z "$TREE_COUNT" ] || [ -z "$TREE_KILL" ] \
    || [ "$TREE_GUARD" -ge "$TREE_STOP" ] || [ "$TREE_STOP" -ge "$TREE_COUNT" ] || [ "$TREE_COUNT" -ge "$TREE_KILL" ]; then
    report "$PROCESS_EXTENSIONS" \
        "killTree must refuse pid 0 and launchd, hold the process still, count its family, and only then kill — in that order; counted afterwards, the family belongs to launchd and nobody can say whose it was"
fi

check_present "$PROCESS_EXTENSIONS" \
    "hasExited polls with a sleep that a cancelled task skips again; after a Force Quit it spins a core flat out for as long as the process lives" \
    'await Task\.detached \{ try\? await Task\.sleep\(for: \.milliseconds\(200\)\) \}\.value'

# What legendary wrote before it was killed is not a reason the launch failed, and whatever the
# launch throws on its way out of a Force Quit must not skip the kill being made certain.
check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "legendary's transcript is read for errors after a Force Quit again; a line from before the kill becomes a reason the launch failed" \
    'if !launch\.hasBeenStopped, let output = try\? String\(contentsOf: transcript\.url'

check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "an Epic launch force-quit with anything but a CancellationError in flight skips making the kill certain again" \
    '\} catch where launch\.hasBeenStopped \{'

# A native game is opened by a call that can't be interrupted and waits for the whole launch.
for path in \
    PorTalistic/Utilities/GameManager/GOGGameManager.swift \
    PorTalistic/Utilities/GameManager/LocalGameManager.swift
do
    CHECKS=$((CHECKS + 1))
    if ! awk '
        /try Task\.checkCancellation\(\)/ { checked = NR }
        /openApplication\(at: location/ {
            opened = NR
            if (!checked || opened - checked > 3) { exit 1 }
        }
        opened && NR > opened && NR <= opened + 8 && /guard !Task\.isCancelled else \{/ { guarded = NR }
        guarded && NR > guarded && NR <= guarded + 2 && /application\.forceTerminate\(\)/ { ended = 1 }
        END { exit (opened && ended) ? 0 : 1 }
    ' "$path"; then
        report "$path" \
            "a native game is opened without looking for a Force Quit on either side of openApplication; the game opens anyway, and one pressed while it opened is only heard by a wait that isn't listening yet"
    fi
done

# Applying a configuration is one Wine start per setting, and none of them looks for a
# cancellation; a Force Quit is looked for between them.
check_count "PorTalistic/Utilities/Compatibility/Provisioner.swift" 3 \
    "applying a configuration no longer stops between settings for a Force Quit; every remaining setting is written first" \
    'guard !Task\.isCancelled else \{ return \}'

# A launch has two phases before the game appears — the container being set up, and the game on
# its way — and everything that used to ask "is it starting" meant "is it not up yet". Comparing
# to `.starting` alone hides the spinner, and frees Play, for the whole time a configuration is
# being applied.
check_absent \
    "asks whether a launch is in the starting phase; there are two phases before a game appears and this one means neither — ask whether it is not running" \
    'launchPhase == \.starting' \
    PorTalistic

check_present "PorTalistic/Utilities/Compatibility/Provisioner.swift" \
    "a launch no longer says when it has finished putting the configuration in place, so the page cannot tell that half of a launch from the other" \
    'operation\?\.noteConfigurationApplied\(\)'

check_present "PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift" \
    "nothing announces that the journal changed, so a page showing what the app decided about a game only updates if you leave it and come back" \
    'journalRevision \+= 1'

check_present "PorTalistic/Views/Navigation/GameDetailView.swift" \
    "the game's page no longer watches for the recovery loop deciding something, so the configuration it shows is the one from when the page was opened" \
    'RecoveryCoordinator\.shared\.journalRevision'

check_present "PorTalistic/Utilities/GameOperation/GameOperation.swift" \
    "whether a launch is applying a new configuration is decided in the view again, where no test can reach it" \
    'var isApplyingConfiguration: Bool'

# Everything this loop decides is told to somebody, and every one of those ways of telling them
# has been silently broken at least once.
check_present "PorTalistic/AppDelegate.swift" \
    "notifications posted while PorTalistic is in front are dropped again — which is every notification this app sends, since a game exiting is what brings it back to the front" \
    'willPresent notification: UNNotification'

check_present "PorTalistic/Views/Navigation/GameDetailView.swift" \
    "a multi-line explanation is drawn as one row again, so its first line gets the checkmark and the rest read as though they were not applied" \
    'Self\.rows\(of: profile\.reasons\)'

check_count "PorTalistic/Views/Navigation/GameDetailView.swift" 2 \
    "the game's page no longer says when the app has run out of configurations to try (it is read twice: the panel is never empty while there is something to say, and the row itself), leaving the person to notice that nothing changes any more" \
    'profile\.hasExhaustedRecovery'

check_present "PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift" \
    "running out of options is no longer recorded, so it can only ever be a notification nobody may have been looking at" \
    'record\.hasExhaustedOptions = true'

check_present "PorTalistic/Utilities/Compatibility/RecoveryPlanner.swift" \
    "the ladder writes a paragraph per rung again; six failures in, the page explaining how a game runs is a list of things that didn't work" \
    'entry\.note = noting\('

# The line listing what has been tried separates its items with "; ", so a change described with
# one in it comes back as two things that were tried.
check_absent \
    "a change is described with a semicolon in it, which is what separates the items on the line listing what has been tried — it would be read back as two separate changes" \
    '(describedAs|summary): String\(localized: "[^"]*; ' \
    PorTalistic/Utilities/Compatibility/RecoveryPlanner.swift \
    PorTalistic/Utilities/Compatibility/CrashDiagnosis.swift

# Checked inside the clean branch rather than anywhere in the file: it is cleared in three
# places, and the two that matter less — a rung, a remedy — only ever run after a failure.
CHECKS=$((CHECKS + 1))
COORD="PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift"
CLEAN_LINE=$(grep -n '^        case \.clean:' "$COORD" | cut -d: -f1 | head -1)
CLEAN_CLEARS=$(awk -v start="${CLEAN_LINE:-0}" 'NR > start && NR <= start + 10 && index($0, "record.hasExhaustedOptions = false") { print NR; exit }' "$COORD")
if [ -z "$CLEAN_LINE" ] || [ -z "$CLEAN_CLEARS" ]; then
    report "$COORD" \
        "a clean session doesn't clear the 'nothing left to try' state, so a game that works still carries the warning that it cannot be made to — and it is only ever cleared after a failure otherwise"
fi

check_present "PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift" \
    "the planner is no longer told which Direct3D implementations exist on this Mac, so it offers to move a game to one that isn't installed and changes nothing" \
    'backendsAvailable: backendsAvailable'

check_present "PorTalistic/Utilities/Compatibility/RecoveryPlanner.swift" \
    "a rung offering a Direct3D implementation is no longer checked against what this Mac has; the ranking then finds nothing to move to and the person is told the game renders differently" \
    'if let backend = step\.graphicsBackend, !backendsAvailable\.contains\(backend\) \{ return false \}'

check_present "PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift" \
    "wouldNotStay doesn't reach the failure path, so the loop works out that a game refuses to run and then does nothing about it" \
    'case \.crashed, \.neverStarted, \.wouldNotStay:'

# Checked where it is passed rather than anywhere in the file: the verdict is handed to the
# notification and to the report as well, so a plain search for it stays green while the planner
# is the one left guessing.
CHECKS=$((CHECKS + 1))
RECOVERY_COORD="PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift"
PLAN_CALL=$(grep -n 'RecoveryPlanner.plan(for: record,' "$RECOVERY_COORD" | cut -d: -f1 | head -1)
PLAN_VERDICT=$(awk -v start="${PLAN_CALL:-0}" 'NR > start && NR <= start + 3 && index($0, "verdict: verdict,") { print NR; exit }' "$RECOVERY_COORD")
if [ -z "$PLAN_CALL" ] || [ -z "$PLAN_VERDICT" ]; then
    report "$RECOVERY_COORD" \
        "the planner is no longer told how the launch failed, so a game that refuses to start spends its first launches on the Retina desktop and Wine's render thread — neither of which it ever looked at"
fi

check_present "PorTalistic/Utilities/Wine/WineInterface.swift" \
    "the post-mortem is no longer told which Direct3D implementation actually rendered, so the ladder offers the game the one it is already using and a whole launch changes nothing" \
    'backendInEffect: plan\.graphicsBackend'

# The journal is written by one version and read by the next. A synthesised decoder refuses a
# file missing any non-optional key, and `load()` discards what it cannot decode — so a new
# field would quietly cost every machine every fix it had learned.
check_present "PorTalistic/Utilities/Compatibility/RecoveryJournal.swift" \
    "GameRecord is back on the synthesised decoder; the next field added to it throws away every journal already on disk, silently" \
    'attempts = try container\.decodeIfPresent'

check_present "PorTalistic/Utilities/Compatibility/RecoveryJournal.swift" \
    "an attempt this build cannot read takes the whole journal with it again — including the learned entry that took four crashes to find. A verdict added later is exactly that case" \
    'struct Forgiving<Wrapped: Decodable>'

# Every remedy and every rung has to carry the builtin fallback. A bare `n` is native-only:
# with no native file in the prefix it resolves to nothing and the game will not start at all,
# which is how a fix for BioShock Remastered became worse than the fault it fixed.
check_absent "a DLL override is set to a bare \"n\" — native-only, so a failed winetricks verb becomes a game that cannot launch. Use \"n,b\"" \
    ': "n"\]|: "n",|"n"\)$' \
    PorTalistic/Utilities/Compatibility/CrashDiagnosis.swift \
    PorTalistic/Utilities/Compatibility/RecoveryPlanner.swift

# The post-mortem is per launch path, and a path that doesn't pass its own transcript diagnoses
# the previous run's log — or nothing at all, silently, forever.
for path in \
    PorTalistic/Utilities/GameManager/GOGGameManager.swift \
    PorTalistic/Utilities/GameManager/LocalGameManager.swift \
    PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift
do
    check_present "$path" \
        "this launch path doesn't hand its transcript and plan to the post-mortem, so a crash on it is never diagnosed" \
        'transcriptAt: launchedTranscriptURL'
done

# Nothing is reconfigured while a game is running. A settings write applied mid-startup, with a
# wineserver still serving the prefix, is the fault that made Horizon Chase Turbo open in a
# small window three separate times.
check_absent "the recovery loop writes settings directly — everything it decides belongs in the journal and takes effect on the next launch" \
    'Provisioner\.shared\.apply|Wine\.setRetinaMode|Wine\.setCaptureDisplaysForFullscreen|container\.settings =' \
    PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift

# Nothing transmits yet, and that is the current promise: the whole loop works, and can be
# read, before a byte leaves the machine. When submission is built this check is what has to
# change — deliberately, in the commit that adds consent.
check_absent "a crash report is being transmitted. Nothing may leave the machine until consent exists and the person has been shown what a report contains" \
    'URLSession|dataTask|URLRequest' \
    PorTalistic/Utilities/Compatibility/CrashReport.swift \
    PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift

# A report's evidence is redacted, scrubbed and capped by one function. Anything building the
# list another way is the path a token leaves by.
check_present "PorTalistic/Utilities/Compatibility/CrashReport.swift" \
    "a report's evidence has to be redacted and path-scrubbed — a launch transcript has held a live bearer token, account id and coordinates" \
    '^[[:space:]]*var cleaned = Wine\.redactSecrets\(in:'

check_absent "raw fault lines are being put into a report without going through CrashReport.evidence(from:)" \
    'evidence: faults|evidence: CrashDiagnosis\.faultLines' \
    PorTalistic/Utilities/Compatibility/RecoveryCoordinator.swift

# ── Runtime retention ──────────────────────────────────────────────────────
#
# Deleting a Wine build is the one destructive thing the app does to itself, and every guard
# on it is invisible when it goes: nobody notices that a prefix with save games in it was
# swept until they look for the save games.

# One definition of the number, so the sweep, the tests and what the user is told cannot
# disagree about how many builds are kept.
check_count "PorTalistic/Utilities/Engine/RuntimeRetention.swift" 1 \
    "keptPerFamily has to be declared exactly once — a second copy of the retention count is a second policy" \
    '^    static let keptPerFamily'

check_absent "the retention count is written out as a literal somewhere other than its own declaration" \
    'keptPerFamily = [0-9]|dropFirst\(3\)|prefix\(3\)' \
    PorTalistic/Utilities/Engine/RuntimeInstaller.swift PorTalistic/Utilities/Compatibility/Provisioner.swift

# The two rules that make the sweep safe rather than merely correct.
check_present "PorTalistic/Utilities/Engine/RuntimeRetention.swift" \
    "the sweep has to skip anything the app didn't install, or it deletes the user's own Game Porting Toolkit or Whisky" \
    'origin == \.managed'

check_present "PorTalistic/Utilities/Engine/RuntimeRetention.swift" \
    "the sweep has to keep a build a container was created against — a container is a Wine prefix with save games in it, and Wine cannot downgrade one" \
    'pinnedRuntimeIDs\.contains'

# Hung off the install rather than off a call site: there are two places that install a
# runtime, and a sweep wired to one of them is a sweep that doesn't happen for the other.
check_present "PorTalistic/Utilities/Engine/RuntimeInstaller.swift" \
    "nothing prunes old Wine builds any more, so every version ever published accumulates on disk" \
    '^[[:space:]]*RuntimeRetention\.sweep\(\)'

# Catalogue order is preference order and a manifest's entries are appended, so without this
# a newer build of a lineage is downloaded, installed, and never selected.
check_present "PorTalistic/Utilities/Compatibility/CompatibilityManifest.swift" \
    "the merged catalogue has to be ordered newest-first within each family, or a fetched upgrade is never the one that runs" \
    '^[[:space:]]*return Self\.newestFirstWithinFamilies'

# The signature has to cover the manifest as committed. This is the one failure in the whole
# fetch path that is completely silent: a manifest edited after signing looks committed and
# correct, every app that fetches it discards it before parsing, and the remote fix path simply
# does nothing — forever, for everybody, with no error anywhere.
CHECKS=$((CHECKS + 1))
if [ ! -f Compatibility/manifest.json.sig ]; then
    report "Compatibility/manifest.json" \
        "no manifest.json.sig beside it, so no app will trust the manifest — run 'swift Compatibility/sign-manifest.swift'"
elif [ ! -f Compatibility/manifest.json.sha256 ]; then
    report "Compatibility/manifest.json" \
        "no manifest.json.sha256, so nothing can tell whether the signature still covers this manifest — re-run 'swift Compatibility/sign-manifest.swift'"
else
    RECORDED=$(tr -d '[:space:]' < Compatibility/manifest.json.sha256)
    ACTUAL=$( (sha256sum Compatibility/manifest.json 2>/dev/null || shasum -a 256 Compatibility/manifest.json) | cut -d' ' -f1 )

    if [ "$RECORDED" != "$ACTUAL" ]; then
        report "Compatibility/manifest.json" \
            "the manifest has changed since it was signed, so every app will discard it and no fetched fix reaches anybody — re-run 'swift Compatibility/sign-manifest.swift'"
    fi
fi

# ── The compatibility manifest ─────────────────────────────────────────────
#
# `resolvedGames()` replaces the compiled-in seed outright rather than merging with it, so a
# manifest that omits a seeded game silently un-fixes that game for everyone who fetches it —
# the one failure mode of publishing data that the app cannot detect at runtime. And the
# decoder ignores keys it does not know, so a mistyped field is not an error anywhere: the
# entry loads, the fix is absent, and the game behaves the way it did before anyone looked at
# it. Both are checked against the source here because neither can be checked in the app.
CHECKS=$((CHECKS + 1))
MANIFEST_REPORT=$(python3 - <<'PY' 2>&1
import json, re, sys

manifest_path = "Compatibility/manifest.json"
wire_path = "PorTalistic/Utilities/Compatibility/CompatibilityManifest.swift"
seed_path = "PorTalistic/Utilities/Compatibility/CompatibilityDatabase.swift"

try:
    manifest = json.load(open(manifest_path))
except Exception as error:
    print(f"the manifest is not valid JSON, so nothing in it reaches anybody: {error}")
    sys.exit(0)

wire = open(wire_path).read()

def declared(struct):
    body = re.search(r"struct " + struct + r": Decodable \{(.*?)\n        \}", wire, re.S)
    if body is None:
        body = re.search(r"struct " + struct + r": Decodable \{(.*?)\n    \}", wire, re.S)
    if body is None:
        return None
    return set(re.findall(r"(?:let|var) (\w+):", body.group(1)))

for struct, entries in (("RuntimeEntry", manifest.get("runtimes", [])),
                        ("GameEntry", manifest.get("games", []))):
    fields = declared(struct)
    if fields is None:
        print(f"cannot find {struct} in CompatibilityManifest.swift, so the manifest's keys cannot be checked")
        continue
    for entry in entries:
        name = entry.get("id") or (entry.get("titles") or ["<untitled>"])[0]
        for key in entry:
            if key not in fields:
                print(f"'{name}' sets \"{key}\", which {struct} does not decode — the entry loads and the setting is dropped")

settings_fields = declared("SettingsEntry") or set()
support_fields = declared("SupportLibrariesEntry") or set()

for entry in manifest.get("games", []):
    name = (entry.get("titles") or ["<untitled>"])[0]
    for key in entry.get("settings") or {}:
        if key not in settings_fields:
            print(f"'{name}' sets settings.\"{key}\", which SettingsEntry does not decode — the entry loads and the setting is dropped")
    for dll, spec in (((entry.get("settings") or {}).get("dllOverrides")) or {}).items():
        if spec.strip() == "n":
            print(f"'{name}' overrides {dll} with a bare \"n\" — native-only, so a missing file is a game that will not launch at all. Use \"n,b\"")

for entry in manifest.get("runtimes", []):
    for key in entry.get("supportLibraries") or {}:
        if key not in support_fields:
            print(f"'{entry.get('id')}' sets supportLibraries.\"{key}\", which SupportLibrariesEntry does not decode")

# Every seeded game has to appear, because the manifest replaces the seed rather than adding
# to it. Matched on the storefront-qualified id, which is what the app matches on too.
seed = open(seed_path).read()
seeded = set()
for storefront, identifier in re.findall(r"\.init\(storefront: \.(\w+), id: \"([^\"]+)\"\)", seed):
    seeded.add(f"{storefront}:{identifier}")

published = {identifier for entry in manifest.get("games", []) for identifier in (entry.get("ids") or [])}

for identifier in sorted(seeded - published):
    print(f"{identifier} is fixed in the compiled-in seed but missing from the manifest, which replaces the seed — publishing this would un-fix that game")
PY
)
if [ -n "$MANIFEST_REPORT" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        report "Compatibility/manifest.json" "$line"
    done <<< "$MANIFEST_REPORT"
fi

# ── legendary's housekeeping vs. the resume file ───────────────────────────
# `legendary cleanup` deletes legendary's temporary files, and `<game>.resume` is one of them:
# the record of which files a download has already finished. Running it on quit — which the app
# did, moments after stopping the downloads so they could write that file — is why every
# resumed install started again from zero. One guarded caller, and no bare ones.
check_absent \
    "runs \`legendary cleanup\` directly; it deletes the file an interrupted download resumes from, so it goes through Legendary.cleanUpStaleData()" \
    'arguments *= *\["cleanup"\]' \
    PorTalistic/AppDelegate.swift PorTalistic/Views

check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "the guard on legendary's housekeeping is gone, so it can delete a running download's resume state" \
    'mayCleanUp\(pendingEpicInstalls:'

check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "legendary's housekeeping counts installs alone again; an update and a repair write the same resume state, so it would delete theirs" \
    'fileOperationsInFlight: Game\.operationManager\.queue\.filter \{ \$0\.type\.modifiesFiles \}'

check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "legendary's housekeeping counts every storefront's pending installs again, so one stuck GOG note switches it off for good" \
    'PendingInstalls\.all\.filter \{ \$0\.storefront == \.epicGames \}'

# Both sides of the suspension point. `transformProcess` consults the main actor, and the
# library is on screen by then — a download started in that window had its resume state deleted
# by a cleanup that checked before the download existed.
CHECKS=$((CHECKS + 1))
if [ "$(grep -c 'guard await mayCleanUpNow() else {' \
        PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift 2>/dev/null)" != "2" ]; then
    report "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
        "legendary's housekeeping does not ask twice; the check has to bracket the suspension in transformProcess, or a download started in that window loses its resume state"
fi

# ── Nothing the app starts for itself is left unwaited ─────────────────────
check_absent \
    "starts \`legendary sync-saves\` directly; unregistered and unawaited, it is an orphan on quit — use Legendary.synchroniseCloudSaves()" \
    'arguments *= *\["-y", "sync-saves"\]' \
    PorTalistic/AppDelegate.swift PorTalistic/Views

check_absent \
    "starts a process without awaiting it; the app quits out from under it and it becomes the orphan ChildProcesses exists to stop" \
    'try process\.run\(\)' \
    PorTalistic/AppDelegate.swift

check_present "PorTalistic/Utilities/ChildProcesses.swift" \
    "there is no way to ask whether anything is still running, so quitting has to guess from the operation queue — which does not know about the app's own errands" \
    'static var hasLiveProcesses'

check_present "PorTalistic/AppDelegate.swift" \
    "quitting with an empty queue no longer waits for the app's own child processes, so its housekeeping and cloud saves are orphaned on every quit" \
    'ChildProcesses\.hasLiveProcesses'

check_absent \
    "returns before stopping surviving child processes when no operation is running; the app's own errands are not operations" \
    'guard !stopping\.isEmpty else \{ return \}' \
    PorTalistic/Utilities/GameOperation/GameOperationManager.swift

check_present "PorTalistic/AppDelegate.swift" \
    "legendary's housekeeping does not run at launch; if it moved back to quit it will delete the resume state quitting just saved" \
    'Legendary\.cleanUpStaleData\(\)'

# ── Stopping a process may not raise ───────────────────────────────────────
# `Process.terminate()` and `Process.interrupt()` raise an Objective-C exception when the
# process has not been launched, and Swift cannot catch an `NSException` — so it is a crash,
# not an error. Every call to them in this app sits in a cancellation handler, which is exactly
# where an unlaunched or already-exited process is reachable: force-quitting a game killed the
# app on `-[NSConcreteTask terminate]: task not launched`, and took the `Wine.killAll` on the
# next line with it, so the game it was meant to stop kept running.
check_absent \
    "calls terminate()/interrupt() on a Process; they raise an uncatchable NSException when it is not running — use stopIfRunning()" \
    '(process|\$0)\??\.(terminate|interrupt)\(\)' \
    PorTalistic

check_present "PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift" \
    "the non-raising way to stop a process is gone, so every cancellation handler is a crash waiting for the process to have exited first" \
    'func stopIfRunning'

check_count "PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift" 2 \
    "stopIfRunning and interruptThenInsist must both refuse a process with no pid of its own; an unlaunched Process reports 0, kill(0, ...) signals this app's own process group, and pgrep -P 0 names launchd, whose descendants are every app the person has open" \
    'guard pid > 0, isRunning else \{ return \}'

# The same class, on the two `FileHandle` calls that raise. `availableData` raises
# `NSFileHandleOperationException` on a read error, and `runStreamed` closes these handles from
# the process's termination handler while a readability callback may already be scheduled on
# another queue. The non-throwing `write(_:)` raises on `EPIPE`, reachable whenever legendary
# has exited before the reply to its optional-packs prompt is written.
check_absent \
    "reads a FileHandle with availableData; it raises an uncatchable NSException on a read error — use read(upToCount:)" \
    '^[^/]*availableData' \
    PorTalistic/Utilities/Extensions PorTalistic/Utilities/GameManager PorTalistic/Utilities/Wine

# Scoped to this one file on purpose: on a *regular file* "block until the count or EOF" is
# exactly right, and two callers rely on it (`WindowsExecutable` reading a fixed-size header,
# `RuntimeInstaller` chunking an archive). It is only wrong for an incremental read from a pipe,
# which is what lives here.
check_absent \
    "reads a stream with read(upToCount:); it blocks until the full count or EOF, which freezes live progress and deadlocks an install waiting on its own prompt — use read(2)" \
    '^[^/]*read\(upToCount:' \
    PorTalistic/Utilities/Extensions/Built-in/FileHandle+Extensions.swift

check_absent \
    "writes a FileHandle with the non-throwing write(_:); it raises on EPIPE — use write(contentsOf:)" \
    '^[^/]*[Hh]andle\.write\([^c]' \
    PorTalistic

check_present "PorTalistic/Utilities/ChildProcesses.swift" \
    "quitting terminates surviving downloads instead of interrupting them; legendary and gogdl only write their resume state on SIGINT, so this is how a stopped download comes back from nothing" \
    'stopIfRunning\(SIGINT\)'

# A popup closing is the only signal a page gets that its cookies changed. Without a reload of
# the opener, Epic's store shows a Sign In button over a session that is signed in — and the
# giveaway is that buying the game works anyway. Both closes count: the page closing itself,
# and the person closing the window.
check_present "PorTalistic/Views/Unified/Components/WebView.swift" \
    "a popup closing has to reload the page that opened it, or a sign-in finished in a popup leaves the store still showing Sign In" \
    '^            opener\.reload\(\)$'

check_present "PorTalistic/Views/Unified/Components/WebView.swift" \
    "the window delegate is what catches a popup the person closes by hand — without it only self-closing popups refresh the opener" \
    '^    func windowWillClose\(_ notification: Notification\) \{$'

# ── Web data stores ───────────────────────────────────────────────────────
#
# `WKWebsiteDataStore(forIdentifier:)` inside a view's `body` builds a new store on every
# redraw and retains none of them, so navigating away deallocates the store before WebKit has
# flushed — and the cookies it was holding go with it. Signing in, leaving the page and coming
# back logged out is what that looks like, and it reads as the website's fault rather than ours.
check_absent "a WKWebsiteDataStore is being constructed directly — use WebDataStore.persistent(for:), which holds one per identifier for the life of the process" \
    'WKWebsiteDataStore\(forIdentifier:' \
    PorTalistic/Views/Navigation/StoreView.swift \
    PorTalistic/Views/Unified/Windows/EpicWebAuthView.swift \
    PorTalistic/Views/Unified/Windows/GOGWebAuthView.swift \
    PorTalistic/Views/Unified/Components/WebView.swift

check_count "PorTalistic/Views/Unified/Components/WebDataStore.swift" 1 \
    "there has to be exactly one place that constructs a persistent web data store" \
    '^        let store: WKWebsiteDataStore = \.init\(forIdentifier: identifier\)$'

# Leaving a store page is the only moment the app can know a purchase happened — nothing
# watches a storefront for them.
check_present "PorTalistic/Views/Navigation/StoreView.swift" \
    "leaving the store page has to refresh that storefront's library, or a game bought in the app shows up nowhere until the next launch" \
    'refreshFromStorefronts\($'

# And it has to bypass the storefront tool's own cache. `legendary list` without
# `--force-refresh` answers from `metadata/`, so a plain refresh reports the library as it was
# before the purchase — correctly, from a stale source.
check_present "PorTalistic/Views/Navigation/StoreView.swift" \
    "the refresh after a store visit has to force a remote fetch, or legendary answers from its own cache and the new game is still missing" \
    '^                                storefront, forcingRemoteFetch: true$'

# ── Storefront stores ──────────────────────────────────────────────────────
#
# One store view, parameterised. A second copy is how the sidebar, the window title and the
# Discord presence ended up disagreeing about what a store is called.
check_count "PorTalistic/Views/Navigation/StoreView.swift" 1 \
    "there has to be exactly one store view — a per-storefront copy is a per-storefront name to keep in sync" \
    '^struct StoreView: View'

check_absent "a store URL is hardcoded in a view — it belongs on Game.Storefront.storeURL, with the name and the cookie jar" \
    'store\.epicgames\.com|www\.gog\.com|store\.steampowered\.com' \
    PorTalistic/Views/Navigation/StoreView.swift PorTalistic/Views/Navigation/ContentView.swift

# The fault this one stands for was live on GOG and already fixed on Epic: a
# `@CodableAppStorage` UUID default is re-evaluated by every reader, so each view gets its own
# cookie jar and a sign-in in one place is invisible in the other.
check_absent "a WebKit data store identifier defaults to a fresh UUID in a view — @CodableAppStorage does not persist its default, so every reader gets a different cookie jar. Use the storefront's own persisted identifier" \
    'CodableAppStorage\("[a-zA-Z]*[wW]ebDataStore"\)' \
    PorTalistic/Views/Unified/Windows/GOGWebAuthView.swift \
    PorTalistic/Views/Unified/Windows/EpicWebAuthView.swift \
    PorTalistic/Views/Navigation/StoreView.swift

# A refusal the person can't act on is the thing they read when a game won't start. "PorTalistic
# has no way to run X" reads as "this game is unsupported"; the truth is almost always "the Wine
# build that runs it hasn't been published yet", and those call for opposite reactions.
# Both of them. `check_present` passed with one call site fixed and the other left bare, which
# is exactly the half-done state this is meant to catch.
check_count "PorTalistic/Utilities/Compatibility/Provisioner.swift" 2 \
    "both no-viable-runtime refusals on the launch path have to name what could not be provided — without it the message tells the person only what they already knew" \
    '^            throw NoViableRuntimeError\(title: game\.title, unmet: requirements\.unmetDescriptions\)$'

# ── Per-game actions ───────────────────────────────────────────────────────
#
# Uninstall, Update and Verify all have to be gated on the game actually being installed, and
# each has to exist once. There were *three* hardcoded Uninstall buttons — the component, the
# card's right-click menu and the detail view — and only the component was ever gated, so the
# other two stayed clickable for a game that was never installed. Same shape as the
# PrimaryActionButton fault in invariant 5.
for control in UninstallButton VerificationButton UpdateButton; do
    CHECKS=$((CHECKS + 1))
    if ! awk "/struct $control: View \{/,/^        \}\$/" \
        PorTalistic/Views/Unified/Components/GameCard/GameCard+Extensions.swift 2>/dev/null \
        | grep -qE '^[[:space:]]*\.disabled\(!game\.isInstalled\)'; then
        report "PorTalistic/Views/Unified/Components/GameCard/GameCard+Extensions.swift" \
            "$control isn't gated on game.isInstalled, so it is offered for a game that has no files on disk"
    fi
done

check_absent "a second, hardcoded Uninstall/Verify/Repair button — use GameCard.Buttons, which is the copy that carries the gating" \
    'Button\("Uninstall|Button\("Verify|Button\("Repair Game' \
    PorTalistic/Views/Navigation/GameDetailView.swift \
    PorTalistic/Views/Unified/Components/GameCard/GameCard+Extensions.swift \
    PorTalistic/Views/Unified/Components/GameCard/ListGameCard.swift \
    PorTalistic/Views/Navigation/HomeView.swift

# ── Signing ────────────────────────────────────────────────────────────────
#
# Three settings decide whether a build opens on somebody else's Mac, and all three fail in the
# same invisible way: the build succeeds, the app runs here, and it is refused everywhere else
# with "PorTalistic is damaged and can't be opened" — which reads as a corrupt download.
CHECKS=$((CHECKS + 1))
SIGNING=$(python3 - <<'PY' 2>&1
import re, pathlib

source = pathlib.Path("PorTalistic.xcodeproj/project.pbxproj").read_text()

for match in re.finditer(r"/\* (Debug|Release) \*/ = \{\n\t\t\tisa = XCBuildConfiguration;(.*?)\n\t\t\};",
                         source, re.S):
    name, body = match.group(1), match.group(2)

    # The app target only. The test bundle is hosted by it and signs however it likes.
    if "PRODUCT_BUNDLE_IDENTIFIER = com.mcstig.PorTalistic;" not in body:
        continue

    identity = re.search(r"CODE_SIGN_IDENTITY = ([^;]+);", body)
    hardened = re.search(r"ENABLE_HARDENED_RUNTIME = ([^;]+);", body)

    if name == "Release":
        if identity is None or "Developer ID Application" not in identity.group(1):
            print("the Release configuration is not signed with a Developer ID Application identity — an Apple Development certificate cannot be notarised, and the build is refused on every Mac but the one that signed it")

    if hardened is None or hardened.group(1).strip() != "YES":
        print(f"the {name} configuration has the hardened runtime off, and notarisation requires it")

# App Sandbox would break every game launch: Wine runs as a child process that reads and writes
# the user's game folders and spawns children of its own, none of which a sandboxed parent
# permits. It is one checkbox away at all times.
entitlements = pathlib.Path("PorTalistic/PorTalistic.entitlements")
if entitlements.exists() and "app-sandbox" in entitlements.read_text():
    print("the App Sandbox entitlement is set. Wine runs as a child process outside the bundle — sandboxed, no game will launch")

# Both configurations have to name the same team. A Release signed by a team the developer
# never picked is a release nobody can staple, and the mismatch is invisible in Xcode.
teams = set()
for match in re.finditer(r"/\* (?:Debug|Release) \*/ = \{\n\t\t\tisa = XCBuildConfiguration;(.*?)\n\t\t\};",
                         source, re.S):
    body = match.group(1)
    if "PRODUCT_BUNDLE_IDENTIFIER = com.mcstig.PorTalistic;" not in body:
        continue
    team = re.search(r'DEVELOPMENT_TEAM = "?([^";]*)"?;', body)
    teams.add(team.group(1).strip() if team else "")

if len(teams) > 1:
    print(f"Debug and Release name different signing teams ({', '.join(sorted(teams))}) — a release signed by a team nobody picked cannot be stapled")
PY
)
if [ -n "$SIGNING" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        report "PorTalistic.xcodeproj/project.pbxproj" "$line"
    done <<< "$SIGNING"
fi

check_present "Scripts/release.sh" \
    "the release script has to verify Gatekeeper actually accepts the result — every step before it can report success on a build that is still refused elsewhere" \
    '^spctl --assess --type execute'

# Xcode hardens what it builds and ignores what it copies. `legendary` and `gogdl` are folder
# references in `Contents/Resources`, so they arrive unsigned and unhardened, and Apple refuses
# the entire archive for it — after the build, after the export, after the upload.
check_present "Scripts/release.sh" \
    "the release script has to sign and harden the Mach-O helpers under Resources — Xcode does not touch a copied folder reference, and notarisation refuses the whole archive over it" \
    '^            --entitlements Scripts/helper-entitlements\.plist'

check_present "Scripts/release.sh" \
    "the app has to be re-signed after its nested helpers are — its signature seals them, and signing them afterwards invalidates it" \
    '^    --entitlements PorTalistic/PorTalistic\.entitlements'

# `notarytool submit --wait` exits 0 whether Apple accepts or refuses. Reading `$?` instead of
# the status announced a successful notarisation of a rejected build, and the first symptom was
# stapling failing with "Record not found" — which reads like an Apple outage.
check_present "Scripts/release.sh" \
    "the notarisation verdict has to be read from the status, not from the exit code — notarytool exits 0 on a refusal" \
    '^if \[ "\$STATUS" != "Accepted" \]; then'

# The helpers may disable library validation. PorTalistic itself never may: it is the thing
# loading the frameworks a user would be asked to trust.
CHECKS=$((CHECKS + 1))
if grep -q "disable-library-validation" PorTalistic/PorTalistic.entitlements 2>/dev/null; then
    report "PorTalistic/PorTalistic.entitlements" \
        "the app itself disables library validation. That belongs on the bundled Python helpers, not on PorTalistic"
fi

# ── Patreon ────────────────────────────────────────────────────────────────
#
# PorTalistic is free and patron-supported. The link appears in three places and exists once.
# A literal written out in a view is how one of them ends up pointing somewhere else — and
# this codebase already shipped one fork-era URL that went through a find-and-replace into a
# GitHub Sponsors page that did not exist.
CHECKS=$((CHECKS + 1))
PATREON_LITERALS=$(grep -rln --include='*.swift' 'patreon\.com' PorTalistic 2>/dev/null | grep -v 'Utilities/Branding\.swift$')
if [ -n "$PATREON_LITERALS" ]; then
    while IFS= read -r file; do
        report "$file" "a patreon.com URL is written out here — use Branding.patreonURL, the one place it is defined"
    done <<< "$PATREON_LITERALS"
fi

for path in PorTalistic/Views/Navigation/ContentView.swift PorTalistic/PorTalisticApp.swift PorTalistic/WhatsNewCollection.swift; do
    check_present "$path" \
        "the Patreon link is missing from here — the sidebar, the Help menu and What's New are the three places people are asked to support the project" \
        'Branding\.patreonURL'
done

# The sidebar button has to sit *above* the footer's `#if DEBUG`, not inside it. Everything
# under that line only exists in Debug builds, and a support button only the developer can see
# supports nobody.
CHECKS=$((CHECKS + 1))
PATREON_LINE=$(grep -n 'Link(destination: Branding\.patreonURL)' PorTalistic/Views/Navigation/ContentView.swift | head -1 | cut -d: -f1)
FOOTER_LINE=$(grep -n 'private var footer: some View' PorTalistic/Views/Navigation/ContentView.swift | head -1 | cut -d: -f1)
if [ -n "$PATREON_LINE" ] && [ -n "$FOOTER_LINE" ]; then
    DEBUG_LINE=$(awk -v start="$FOOTER_LINE" 'NR > start && /^#if DEBUG/ { print NR; exit }' PorTalistic/Views/Navigation/ContentView.swift)
    if [ -n "$DEBUG_LINE" ] && [ "$PATREON_LINE" -gt "$DEBUG_LINE" ]; then
        report_at "PorTalistic/Views/Navigation/ContentView.swift" "$PATREON_LINE" \
            "the Patreon button is inside the footer's #if DEBUG, so no release build shows it"
    fi
fi

# ── Target membership ──────────────────────────────────────────────────────
#
# A test file added to the app target is resolved against that group's folder, so the build
# fails with "Build input file cannot be found" naming a path the file was never at — which
# reads as a missing file rather than as a wrong target. Cheap to check, and it has already
# cost one build.
CHECKS=$((CHECKS + 1))
MEMBERSHIP=$(python3 - <<'PY' 2>&1
import re, pathlib

project = pathlib.Path("PorTalistic.xcodeproj/project.pbxproj")
source = project.read_text()

phases = dict(re.findall(r"([0-9A-Z]{24}) /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;(.*?)\n\t\t\};",
                         source, re.S))

for phase, body in phases.items():
    target = re.search(r"([0-9A-Z]{24}) /\* (\w+) \*/ = \{\n\t\t\tisa = PBXNativeTarget;(?:(?!\n\t\t\};).)*?" + phase,
                       source, re.S)
    name = target.group(2) if target else phase
    compiled = re.findall(r"/\* ([\w.+-]+) in Sources \*/", body)

    if name == "PorTalistic":
        for stray in compiled:
            if "Tests.swift" in stray:
                print(f"{stray} is compiled into the app target — it belongs to PorTalisticTests, and the app target resolves its path against the wrong folder")
    elif name == "PorTalisticTests":
        for stray in compiled:
            if "Tests.swift" not in stray:
                print(f"{stray} is compiled into the test target; the suite is hosted by the app and reaches app code through @testable import")

for path in pathlib.Path("PorTalisticTests").glob("*.swift"):
    if f"/* {path.name} in Sources */," not in source:
        print(f"{path.name} exists but no target compiles it, so nothing in it ever runs")
PY
)
if [ -n "$MEMBERSHIP" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        report "PorTalistic.xcodeproj/project.pbxproj" "$line"
    done <<< "$MEMBERSHIP"
fi

# ── A refresh may not overwrite the library's own objects ──────────────────
# `Set.update(with:)` REPLACES the matching member, and `Game`'s `==` is by id alone — so a
# freshly built catalogue entry takes the place of the library's object wholesale, resetting
# the favourite, the last-played date, custom artwork, launch arguments, the container and
# every settings override. Both refresh loops have to merge into what is already there.
check_present "PorTalistic/Utilities/GameDataStore.swift" \
    "the catalogue loop replaces library objects instead of merging into them, which resets favourites, artwork and settings on every refresh" \
    'try existing\.merge\(with: game, requiring: \.identicalIgnoredKeys\)'

check_present "PorTalistic/Utilities/GameDataStore.swift" \
    "the catalogue fold is back inline; it has to stay a named function or nothing can test it, and the fault it prevents is invisible unless the loop runs" \
    'static func absorb\(catalogue: \[Game\], into library: inout Set<Game>\)'

check_present "PorTalistic/Utilities/GameDataStore.swift" \
    "the catalogue loop no longer sets the installation state, so an uninstall performed outside the app is never noticed (the merge rule keeps the greater of the two states)" \
    'existing\.installationState = game\.installationState'

# ── Nothing may leave the installed list without saying so ─────────────────
check_absent \
    "drops an installed game whose platform is unrecognised without a word; the only symptom is an installed game showing Download" \
    'guard let platform: Game\.Platform = installedGame\.platform else \{ return nil \}' \
    PorTalistic/Utilities/GameManager

check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "installed DLC is no longer filtered out, so an entitlement enters the library as a game with no metadata, no download size and an Install that does nothing" \
    'guard !installedGame\.isDLC else \{ return nil \}'

# ── The install sheet may not ask about a platform the game hasn't got ─────
# The sheet opens with `platform` at a default, and asking legendary about a build that does
# not exist returns an error that was shown as "no download size". The probe waits for the real
# platform list, and a new probe replaces the one in flight rather than being dropped — the
# dropped one was reliably the only correct one.
for sheet in \
    "PorTalistic/Views/Unified/Sheets/GameInstallationView/Epic Games/EpicGamesGameInstallationView.swift" \
    "PorTalistic/Views/Unified/Sheets/GameInstallationView/GOG/GOGGameInstallationView.swift"
do
    check_present "$sheet" \
        "the install sheet probes before it knows which platforms the game offers, which is what showed no download size" \
        'guard supportedPlatforms != nil else \{ return \}'

    check_present "$sheet" \
        "a new metadata probe no longer replaces the one in flight; the one that gets dropped is the request made once the real platform is known" \
        'metadataProbe\?\.cancel\(\)'

    check_present "$sheet" \
        "resolving the platform list no longer re-triggers the probe, so a game whose only platform is the default is never asked about at all" \
        'onChange\(of: supportedPlatforms'

    check_present "$sheet" \
        "the Install button shares the metadata lookup's busy flag again: pressing it writes the probe's spinner, and OperationButton's defer clears it under a probe still running" \
        'operating: \$isStartingInstallation'

    check_present "$sheet" \
        "the size lookup has no spinner of its own; giving the Install button a separate flag leaves the lookup invisible unless something draws it" \
        'ProgressView\(\)'

done

# The opposite mistake, made once: a short deadline in the view killed a lookup that was only
# slow. `legendary info` renews the Epic login before it answers, and that round-trip alone can
# outlast thirty seconds. Bounding it is the process timeout's job, not the sheet's.
check_absent \
    "re-adds a deadline in the install sheet; legendary info is bounded by its own process timeout, and a short one here kills lookups that are merely slow to authenticate" \
    'Task\.sleep\(for: \.seconds\(30\)\)' \
    "PorTalistic/Views"

check_absent \
    "disables Install while the download size is being looked up; the size is advice, and a failed lookup locked people out of installing" \
    '\.disabled\((fetchingOptionalPacks|isFetchingMetadata)\)' \
    "PorTalistic/Views"

check_absent \
    "drops a pending metadata probe instead of replacing it" \
    'guard !(fetchingOptionalPacks|isFetchingMetadata) else \{ return \}' \
    "PorTalistic/Views"

check_absent \
    "swallows an installation that failed to start, closing the sheet with no operation, no message and no log line" \
    '_ = try\? await EpicGamesGameManager\.install' \
    "PorTalistic/Views"

# ── Asking how big a game is may not run an installer ──────────────────────
# `legendary install` takes the installed-data lock, waits at a prompt, and reports a size only
# as a line of prose. Asking it just to find out the size failed whenever anything else was
# downloading, and the failure was discarded — which is why some games showed no size while
# Heroic, which asks `legendary info --json`, could answer for the same game.
check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "the pre-installation size lookup no longer asks legendary info --json; scraping legendary install for it takes the lock and hangs on a prompt" \
    '"info", game\.id, "--platform", matchPlatform\(for: platform\), "--json"'

# Narrow on purpose. What was wrong was running `legendary install` as a *probe* — without -y,
# holding the lock, waiting at a prompt — just to read a size out of it. Reading legendary's
# analysis during a real install is fine, and a resumed download needs it (see ResumeBaseline).
check_absent \
    "runs legendary install as a probe to learn a size; it takes the lock and waits at a prompt — ask legendary info --json" \
    '\["install", game\.id, "--platform"' \
    PorTalistic/Utilities

# A game whose platform list comes back empty must still be installable. Falling back to no
# platforms left the picker blank, the selection on its default, and the game permanently
# un-installable with no size and no spinner.
check_present "PorTalistic/Views/Unified/Sheets/GameInstallationView/Epic Games/EpicGamesGameInstallationView.swift" \
    "an undetectable platform list falls back to nothing again, which makes the game un-installable rather than merely unlabelled" \
    'retrieved\.isEmpty \? Set\(Game\.Platform\.allCases\) : retrieved'

# The free-space check has to ask about the volume the game is going to. Asking about the app's
# own volume meant an external install drive was never checked at all.
check_absent \
    "checks free space on the app's own volume rather than the chosen install directory" \
    'attributesOfFileSystem\(forPath: Bundle\.appHome' \
    PorTalistic/Views

# Cancelling a download has to end the operation, not just the downloading. An interrupt the
# tool never acts on leaves `waitUntilExit()` blocked, the operation unfinished, and a progress
# bar for a stopped download on screen until the app restarts.
check_present "PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift" \
    "there is no escalation after an interrupt, so a download that ignores SIGINT strands its operation forever" \
    'func interruptThenInsist'

check_present "PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift" \
    "streaming waits on the blocking waitUntilExit() again; a cancelled download then never returns, and its operation is stranded in the queue with a progress bar on screen" \
    'await self\.waitUntilExitOrCancellation\(\)'

check_absent \
    "cancels a download with a bare interrupt; it has to escalate, or the operation never finishes" \
    '^[^/]*process\.stopIfRunning\(SIGINT\)' \
    PorTalistic/Utilities/GameManager

# ── A stopped install takes its download with it ───────────────────────────
# `PendingInstalls` forgets an install the person stopped, so nothing will ever resume what it
# wrote. Leaving the bytes there put fifteen gigabytes of one game and six of another in the
# folder the next install goes into — and counted them against the free-space check that then
# refused it.
check_present "PorTalistic/Utilities/GameOperation/GameOperationManager.swift" \
    "stopping an install forgets its note but keeps its partial download, which nothing will ever resume" \
    'operation\.discardsDownloadWhenStopped = true'

check_present "PorTalistic/Utilities/GameOperation/GameOperationManager.swift" \
    "there is nothing that removes a stopped download, so cancelling silently costs disk space" \
    'func discardPartialDownload'

# The guard that stops a bad folder name costing somebody their whole library: `base + ""`,
# `base + "."` and `base + "/"` all resolve to the install directory itself.
check_present "PorTalistic/Utilities/GameOperation/GameOperation.swift" \
    "a download destination is no longer confined to the install directory; an empty or malformed folder name then names the directory itself, and removing it removes every game in it" \
    'guard resolved != root, resolved\.path\.hasPrefix\(root\.path \+ "/"\) else \{ return \}'

check_present "PorTalistic/Utilities/GameOperation/GameOperationManager.swift" \
    "the stopped-download cleanup no longer waits for the folder to stop changing, so it can delete underneath a download that has started again" \
    'func hasSettled'

# A folder's modification date does not move while a download fills files that already exist, so
# a lull inside a running download read as 'finished'. The tools' own processes are the signal.
check_present "PorTalistic/Utilities/GameOperation/GameOperationManager.swift" \
    "the cleanup judges 'nothing is writing' from the folder alone again; a download filling existing files never touches its modification date" \
    'ChildProcesses\.stoppingProcessesRemain'

# The set of processes being stopped has to shrink again. It only ever grew — a cancelled update
# notes pids and never triggers a clean-up to prune them — and macOS recycles pids, so in a long
# session it would answer yes about a stranger's process and switch the clean-up off for good.
check_present "PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift" \
    "the processes a cancellation was stopping are never untracked, so recycled pids eventually make every clean-up wait and give up" \
    'ChildProcesses\.noteStopped\(\[pid\] \+ workers\)'

check_present "PorTalistic/Utilities/GameOperation/GameOperationManager.swift" \
    "the rule for deleting a stopped download is back inline; it is the one decision here that destroys something irreversibly, and inline it cannot be tested" \
    'func mayDiscardPartialDownload'

# Whether a game is installed has to come from the tools' own records. Asking the library is
# circular: a library that has the state wrong is what offers Install for a game already on
# disk, and that is the case this guard exists to survive.
check_present "PorTalistic/Utilities/GameOperation/GameOperationManager.swift" \
    "the stopped-download cleanup decides 'is it installed' from the library, which is the one source that is wrong in exactly the case this guards against" \
    'try\? Legendary\.getGameInstallationData\(gameID: id\)'

check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "the Epic install no longer notes where legendary put the download, so a stopped one cannot be found to remove" \
    'destination\.note\(chunk\)'

check_present "PorTalistic/Utilities/GameManager/GOGDLInterface.swift" \
    "the GOG install no longer notes its destination, so a stopped one cannot be found to remove" \
    'noted\.set\(destination\)'

# A download is not one process. Signalling only the tool this app started stopped the tool and
# left its workers downloading — which recreated the folder a cancellation had just cleaned up.
check_present "PorTalistic/Utilities/ChildProcesses.swift" \
    "there is no way to find a download's worker processes, so stopping one stops only the tool and the workers carry on writing" \
    'static func descendants\(of pid: pid_t\)'

check_present "PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift" \
    "stopping a download no longer takes its workers with it; they are children of the tool, not of this app, and they keep writing after it has gone" \
    'ChildProcesses\.descendants\(of: pid\)'

# The workers have to be found *before* the tool is signalled — once it exits they re-parent to
# launchd and pgrep -P cannot name them — and interrupted with it, not ten seconds later.
CHECKS=$((CHECKS + 1))
PROCESS_EXT="PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift"
GATHER_LINE=$(grep -n 'let workers = await ChildProcesses.descendants(of: pid)' "$PROCESS_EXT" | cut -d: -f1 | head -1)
SIGNAL_LINE=$(grep -n 'stopIfRunning(SIGINT)' "$PROCESS_EXT" | cut -d: -f1 | head -1)
if [ -z "$GATHER_LINE" ] || [ -z "$SIGNAL_LINE" ] || [ "$GATHER_LINE" -ge "$SIGNAL_LINE" ]; then
    report "$PROCESS_EXT" \
        "a download's workers are found after the tool is signalled, which is too late: once the tool exits they re-parent to launchd, pgrep -P cannot name them, and they keep downloading"
fi

# ── A stop that comes before the launch ────────────────────────────────────
# A cancellation handler can run before the task it cancels has launched anything. Taken through
# the unlaunched process's pid of 0, stopping a download interrupted — then terminated, then
# killed — every app the person had open: `pgrep -P 0` is launchd. And the stop itself was lost,
# so the task launched the download anyway and left it running with nothing able to stop it.
CHECKS=$((CHECKS + 1))
INSIST_LINE=$(grep -n 'func interruptThenInsist' "$PROCESS_EXT" | cut -d: -f1 | head -1)
INSIST_GUARD=$(awk -v start="${INSIST_LINE:-0}" 'NR > start && index($0, "guard pid > 0, isRunning else { return }") { print NR; exit }' "$PROCESS_EXT")
INSIST_NOTE=$(grep -n 'ChildProcesses.noteStopping(\[pid\])' "$PROCESS_EXT" | cut -d: -f1 | head -1)
if [ -z "$INSIST_LINE" ] || [ -z "$INSIST_GUARD" ] || [ -z "$INSIST_NOTE" ] || [ "$INSIST_GUARD" -ge "$INSIST_NOTE" ]; then
    report "$PROCESS_EXT" \
        "interruptThenInsist acts before making sure there is a launched, running process; a pid of 0 makes pgrep name launchd, and every app the person has open, as the download's workers"
fi

check_present "PorTalistic/Utilities/ChildProcesses.swift" \
    "descendants(of:) follows pid 0 or 1 again; pgrep -P 0 is launchd, and launchd's descendants are every app the person has open" \
    'guard pid > 1 else \{ return \[\] \}'

check_present "PorTalistic/Utilities/ChildProcesses.swift" \
    "isAlive no longer refuses pid 0; kill(0, 0) succeeds for as long as the app exists, so a clean-up waiting on it waits out its budget and gives up" \
    'pid > 0 && kill\(pid, 0\) == 0'

check_present "$PROCESS_EXT" \
    "runStreamed can return with its process still running again; every caller reads terminationStatus next, which raises on a running process" \
    'if isRunning \{ throw CancellationError\(\) \}'

check_present "$PROCESS_EXT" \
    "a launch no longer looks for a stop that arrived while it was launching; that stop is lost, and the download runs on with nothing able to stop it" \
    'if stoppedMeanwhile \{ halt\(process\) \}'

check_absent \
    "stops a download by interrupting its Process directly; a stop that arrives before the launch is then lost — go through StoppableLaunch" \
    '^[^/]*(process|running)\??\.(interruptThenInsist|interrupt)\(\)' \
    PorTalistic/Utilities/GameManager

check_count "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" 2 \
    "legendary is no longer launched through a StoppableLaunch (executeStreamed passes it on, executeStreamedWaitingForLock supplies it); a Stop pressed while an attempt is being prepared is lost, and the download starts anyway" \
    'launchingWith: launch,'

check_present "PorTalistic/Utilities/GameManager/GOGDLInterface.swift" \
    "gogdl is no longer launched through a StoppableLaunch; a Stop pressed while the install is being prepared is lost, and the download starts anyway" \
    'launchingWith: launch\)'

# Every legendary download — install, update, repair — goes through the one path that sets its
# quality of service, stops its workers, retries with a bigger cache and reads its exit code.
# Repair had been calling executeStreamed directly and had none of them.
check_count "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" 1 \
    "a legendary download calls executeStreamed directly instead of executeStreamedWaitingForLock; it then runs throttled, leaves its workers downloading when stopped, and reports a crash as success" \
    'executeStreamed\(process'

# The compiler holds this one — executeStreamedWaitingForLock has no way to be told to ignore
# legendary's ERROR lines — and these hold the compiler to it: one declaration of the flag (on
# executeStreamed itself), and nothing anywhere passing false.
check_count "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" 1 \
    "executeStreamedWaitingForLock can be told to ignore legendary's ERROR lines again; that is how a missing manifest and a lock held elsewhere finished as successful repairs — excuse recoverable lines in isRecoverable instead" \
    'throwsOnChunkError: Bool'

check_absent \
    "a legendary download ignores its ERROR lines wholesale; a missing manifest and a lock held elsewhere then finish as success — excuse the recoverable lines in isRecoverable instead" \
    'throwsOnChunkError: false' \
    PorTalistic/Utilities/GameManager/Legendary

# A resumed download reports progress over what is left, so without a baseline one picked up at
# 15% shows 1% — the bytes are kept and the folder keeps growing, but the bar says it has barely
# begun.
check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "a resumed install reports this run's progress as if it were the whole game's, so it restarts the bar from zero" \
    'baseline: baseline'

# On a resumed run legendary's `Install size` is what is left, so the whole game is left + skipped.
# Dividing by what is left alone showed 100% for any download resumed past halfway.
check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "resume progress divides by what is left rather than by the whole game; past halfway it reads 100% for the entire remaining download" \
    'skippedMiB / \(remainingMiB \+ skippedMiB\)'

# Removing a stopped download's folder has to remove legendary's list of what it had finished.
# That list is trusted without re-hashing anything, so left behind it marks a half-written file
# from the next attempt as complete — and the game installs with it truncated.
CHECKS=$((CHECKS + 1))
MANAGER="PorTalistic/Utilities/GameOperation/GameOperationManager.swift"
RECORD_LINE=$(grep -nE '^[^/]*Legendary\.discardResumeState\(forGameID: id\)' "$MANAGER" | cut -d: -f1 | head -1)
REMOVE_LINE=$(grep -nE '^[^/]*try FileManager\.default\.removeItem\(at: location\)' "$MANAGER" | cut -d: -f1 | head -1)
if [ -z "$RECORD_LINE" ] || [ -z "$REMOVE_LINE" ] || [ "$RECORD_LINE" -ge "$REMOVE_LINE" ]; then
    report "$MANAGER" \
        "legendary's resume record is not removed before the stopped download's files; a record that outlives its files lets a later attempt skip a half-written one as finished"
fi

# ── Downloads run at the quality of service of something a person is waiting on ─
# Spawned from a `.utility` task with no QoS of its own, a download ran at utility: on Apple
# Silicon that is the efficiency cores and throttled disk I/O, for a tool that decompresses every
# chunk it fetches. It capped downloads far below the connection.
check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "legendary downloads inherit utility quality of service again, which throttles their disk writes" \
    'process\.qualityOfService = \.userInitiated'

check_present "PorTalistic/Utilities/GameManager/GOGDLInterface.swift" \
    "gogdl downloads inherit utility quality of service again, which throttles their disk writes" \
    'process\.qualityOfService = \.userInitiated'

# legendary's speed is a one-second figure; shown raw it lurches between 34, 15 and zero while
# the download as a whole is steady. And the two lines that explain a genuine dip — how full the
# cache is, how fast the disk is being written — were parsed out and thrown away.
check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "the download speed is shown as legendary's raw one-second figure again, which swings to zero on every pause between bursts" \
    'status\?\.averagedThroughput\(adding:'

check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "legendary's cache usage is no longer read, so there is no way to tell a download waiting on the disk from one waiting on the network" \
    'forKey: \.downloadCacheUsage'

# ── A process's output is read to the end, whatever the caller thinks of it ──
# Throwing out of the read loop on the first bad line stopped reading. legendary logs ERROR for
# things it recovers from, so its stderr then filled and it blocked on its next write — a
# download that simply stopped, with no progress and no exit.
check_present "PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift" \
    "the stream reader throws on the first bad line again, which stops reading and leaves the process blocked on a full pipe" \
    'if throwsOnChunkError, firstError == nil \{ firstError = error \}'

check_absent \
    "the stream reader throws from inside its read loop; it has to keep draining the pipe and throw at the end" \
    'if throwsOnChunkError \{ throw error \}' \
    PorTalistic/Utilities/Extensions

# The retry with a bigger cache has to leave room to breathe. legendary's figure is its peak need
# plus 64 MiB, and at the peak that stalls the whole download on any one slow chunk.
check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "the shared-memory retry passes legendary's bare minimum again, which stalls the download to zero on any slow chunk at the cache's peak" \
    'String\(megabytes \+ 1024\)'

# ── The Dock icon's badge comes down ───────────────────────────────────────
# A stopped download's badge — ring and count — stayed on the Dock icon until the app quit.
# DockProgress redraws only when the progress it follows changes, and a stopped download's never
# changes again, so something has to take it down; and Stop has to ask at once, because the
# operation itself takes seconds to end. What it counts is tested (DockBadgeTests); that anything
# takes it down, and that Stop asks, are properties of the source.
check_present "$MANAGER" \
    "nothing takes the Dock icon's download badge down any more, so a stopped download's stays on the icon until the app quits" \
    'DockProgress\.resetProgress\(\)'

check_count "$MANAGER" 1 \
    "the Dock icon's badge is set up somewhere other than updateDockProgress(); a second place is a second idea of when it is up" \
    'DockProgress\.style = '

CHECKS=$((CHECKS + 1))
if ! awk '/func cancel\(_ operation: GameOperation\)/ { inside = 1 }
          inside && /updateDockProgress\(\)/ { found = 1 }
          inside && /^    }$/ { exit }
          END { exit !found }' "$MANAGER"; then
    report "$MANAGER" \
        "a Stop no longer takes the Dock icon's badge down itself, so it stays up for as long as the tool takes to stop"
fi

# ── Glass belongs inside a button, never around it ─────────────────────────
# The hero's Play, menu and star were buttons with padding and glass wrapped around them from
# outside. Hover lit a violet pill in the middle of a dark ring, and the ring ignored clicks: a
# click on the rim of a card's star went through to the artwork and opened the game's page.
# Floating controls use `.buttonStyle(.portalFloating)`, which draws the glass as part of the
# button, and glass itself is drawn only by the design system.
check_absent "glass is wrapped around a control from outside: its rim looks pressable and isn't, and hover lights only the middle. Use .buttonStyle(.portalFloating), which puts the glass inside the button" \
    'floating(Capsule|Surface)\(.*interactive' \
    PorTalistic/Views/Navigation PorTalistic/Views/Unified PorTalistic/Views/Onboarding PorTalistic/Views/SparkleUpdater

check_absent "glass is drawn outside the design system; Surfaces.swift is where both of the app's looks are decided, and where a floating button gets its glass as part of itself" \
    '\.glassEffect\(' \
    PorTalistic/Views/Navigation PorTalistic/Views/Unified PorTalistic/Views/Onboarding PorTalistic/Views/SparkleUpdater

check_present "PorTalistic/Views/Unified/Components/GameCard/GameCard.swift" \
    "the favourite star on a card is no longer a whole-circle button, so the rim of its circle is not part of it and a click there opens the game's page" \
    'PortalButtonStyle\(emphasis: \.onArtwork'

# legendary's exit code is not a verdict: it exits 0 after a third-party-store title or a file it
# could not write. Its self-recovering ERROR lines are excused one by one instead, so a genuine
# failure still fails.
check_absent \
    "treats legendary exiting 0 as success whatever it logged; it exits 0 after genuine failures too" \
    'process\.terminationStatus == 0 \{' \
    PorTalistic/Utilities/GameManager/Legendary

check_present "PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift" \
    "legendary's self-recovering ERROR lines fail the operation again, reporting downloads that recovered and finished as broken" \
    'guard !isRecoverable\(String\(errorReason\)\) else \{ continue \}'

# ── Scrolling does no work a frame doesn't need ────────────────────────────
# Scrolling the library was choppy with the processor idle: the cost was per frame, in drawing.
# Glass and materials on cards worked out what was behind them again on every frame they moved;
# every card cast a shadow at an opacity of zero and blended a clear scrim over itself; every
# list row and hero drew its gradient mask offscreen again for a picture that had not changed;
# and a hover write that changed nothing redrew every card at the start of every scroll.
check_absent "glass or a material inside a card, which scrolls, so it is worked out again on every frame the card moves — use artworkChip(in:)" \
    '^[^/]*(\.(floatingSurface|glassEffect)\(|\.(ultraThin|thin|regular|thick|ultraThick|bar)Material)' \
    PorTalistic/Views/Unified/Components/GameCard/GameCard.swift \
    PorTalistic/Views/Unified/Components/GameCard/ListGameCard.swift

CARD="PorTalistic/Views/Unified/Components/GameCard/GameCard.swift"
CHECKS=$((CHECKS + 1))
SHADOWS=$(awk '
    { recent[NR % 5] = $0 }
    $0 ~ "^[^/]*[.]shadow[(]" {
        lifted = 0
        for (i = 1; i <= 4; i++) if (recent[(NR - i) % 5] ~ "if isHovering") lifted = 1
        if (!lifted) print NR
    }' "$CARD")
if [ -n "$SHADOWS" ]; then
    while IFS= read -r line; do
        report_at "$CARD" "$line" "a card casts a shadow while it isn't lifted — a shadow is a pass of its own, on every card, on every frame of a scroll, even at an opacity of zero"
    done <<< "$SHADOWS"
fi

ROW="PorTalistic/Views/Unified/Components/GameCard/ListGameCard.swift"
CHECKS=$((CHECKS + 1))
MASKS=$(awk '
    $0 ~ "^[^/]*[.]mask[(]" { open[NR] = 1 }
    $0 ~ "[.]drawingGroup[(][)]" { for (line in open) if (NR - line <= 20) delete open[line] }
    END { for (line in open) print line }' "$ROW")
if [ -n "$MASKS" ]; then
    while IFS= read -r line; do
        report_at "$ROW" "$line" "a list row masks its artwork without flattening it, so every visible row draws the mask offscreen again on every frame of a scroll — follow it with .drawingGroup()"
    done <<< "$MASKS"
fi

SURFACES="PorTalistic/Views/DesignSystem/Surfaces.swift"
CHECKS=$((CHECKS + 1))
if ! awk '/func artworkFadesOut/ { inside = 1 }
          inside && /drawingGroup\(\)/ { found = 1 }
          inside && /^    }$/ { exit }
          END { exit !found }' "$SURFACES"; then
    report "$SURFACES" \
        "artworkFadesOut() no longer flattens what it masks, so every hero redraws its whole width offscreen on every frame of a scroll"
fi

check_present "$SURFACES" \
    "the artwork scrim draws a gradient even when it is off, blending a clear layer over every card on every frame of a scroll" \
    'if opacity > 0 \{'

check_absent "a view writes the hovered game directly; CardHoverState.pointer(isOver:gameID:) and clear() write only when something changes, and every card on screen redraws for any write" \
    '^[^/]*hover\.gameID = ' \
    PorTalistic/Views

# ── Names are sorted the way people read them ──────────────────────────────
# `<` on titles compares code points: every lowercase name after every capitalised one, and
# "Game 10" before "Game 2". Game.nameOrder is the one rule, and the library's A-Z / Z-A choice
# has to reach the list that draws it.
check_absent "games sorted by name with < on their titles, which puts every lowercase name after every capitalised one and \"Game 10\" before \"Game 2\" — use Game.nameOrder" \
    '^[^/]*\.title < ' \
    PorTalistic

check_present "PorTalistic/Views/Unified/Components/GameListView.swift" \
    "the library list no longer reads the A to Z / Z to A choice, so the Sort menu changes nothing" \
    'titleOrder: titleOrder, installedFirst: installedFirst'

check_present "PorTalistic/Views/Navigation/LibraryView.swift" \
    "the Sort menu is gone from the library's toolbar" \
    'Toggle\("Installed Games First"'

# `GameDataStore.library` is a `Set`. Without the annotation, `filter` is `Set`'s, which
# returns another `Set` — unordered, and hashing every game it keeps to build a collection
# that is about to be sorted into an array regardless. It also stopped the build outright,
# because the comparator takes `[Game]`.
check_present "PorTalistic/Views/Unified/Models/GameListViewModel.swift" \
    "the library's filter dropped its [Game] annotation, so it builds a Set out of a Set on the way to a sort" \
    'let matching: \[Game\] = GameDataStore\.shared\.library'

# ── The tests themselves ───────────────────────────────────────────────────
CHECKS=$((CHECKS + 1))
if [ "$(ls -1 PorTalisticTests/*.swift 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
    report "PorTalisticTests" "the regression suite is gone"
fi

check_present "PorTalistic.xcodeproj/project.pbxproj" \
    "the PorTalisticTests target is gone from the project, so nothing runs the regression suite" \
    'PorTalisticTests'

# ── Provisioning looks again, and downloads each build once ────────────────
# A pass used to run once per launch, before the manifest fetched at launch arrived, so a newly
# published Wine build was never installed from it — and nothing else ever asked for a pass. These
# are the three things that ask now; losing any one brings back a silent case.
PROVISIONER="PorTalistic/Utilities/Compatibility/Provisioner.swift"

check_present "PorTalistic/Utilities/Compatibility/CompatibilityManifest.swift" \
    "a refreshed manifest no longer asks for a provisioning pass, so a newly published Wine build is never installed until the app is opened again" \
    '^[[:space:]]*Provisioner\.shared\.requestPass\(because:'

check_present "PorTalistic/Utilities/GameOperation/GameOperationManager.swift" \
    "the operation queue emptying no longer asks for a provisioning pass: a pass skipped for a running download never runs, and a game that just installed waits for Play to fetch its Wine" \
    '^[[:space:]]*Provisioner\.shared\.requestPass\(because:'

check_present "PorTalistic/Utilities/GameDataStore.swift" \
    "a library refresh that changes which games are installed no longer asks for a provisioning pass" \
    '^[[:space:]]*Provisioner\.shared\.requestPass\(because:'

check_present "$PROVISIONER" \
    "schedulePass no longer stands aside under the test suite, which is hosted by the app — a test that empties the operation queue would start a real provisioning pass: the engine, runtime downloads, the real library" \
    '^[[:space:]]*guard !AppDelegate\.isRunningTests else \{ return \}'

check_present "$PROVISIONER" \
    "planLaunch no longer waits for the manifest fetched at launch, so Play in the app's first seconds plans without newly published builds and curated game entries" \
    '^[[:space:]]*await CompatibilityManifest\.waitForPendingRefresh\(atMost:'

# One download per build: every runtime install goes through the single-flight registry, so a
# launch joins the pass's download instead of starting a second one that fails at the move.
check_count "$PROVISIONER" 1 \
    "RuntimeInstaller.install is called from more than one place in the Provisioner — every install must go through runtimeInstalls, or a launch and a pass download the same build twice" \
    'RuntimeInstaller\.install\('
check_present "$PROVISIONER" \
    "runtime installs no longer go through the single-flight registry" \
    '^[[:space:]]*return try await runtimeInstalls\.value\(for: release\.id\)'
check_count "$PROVISIONER" 1 \
    "Wine.DXMT.install is called from more than one place in the Provisioner — it must go through direct3DLayerInstalls" \
    'Wine\.DXMT\.install\(into:'
check_present "$PROVISIONER" \
    "DXMT installs no longer go through the single-flight registry" \
    '^[[:space:]]*_ = try await direct3DLayerInstalls\.value\(for: runtime\.id\)'

# The same goes for installs asked for by hand: Settings' Install and DXMT buttons, and the engine
# sheet onboarding shows while a pass is already fetching the engine.
check_absent "a view installs a runtime itself, bypassing the Provisioner's one-download-per-build registry — use Provisioner.shared.installRuntime" \
    'RuntimeInstaller\.install\(' \
    PorTalistic/Views/
check_absent "a view installs DXMT itself, bypassing the Provisioner — use Provisioner.shared.installDirect3DLayer(into:)" \
    'Wine\.DXMT\.install\(into:' \
    PorTalistic/Views/
check_present "PorTalistic/Views/Unified/Sheets/EngineInstallationView.swift" \
    "the engine sheet no longer follows a pass's engine install, so a first run starts two engine installs into one directory" \
    'while Provisioner\.shared\.isInstallingEngine'

# And it is visible: a background download of a few hundred megabytes used to look exactly like
# nothing happening.
check_present "PorTalistic/Views/Navigation/ContentView.swift" \
    "the sidebar no longer shows what the app is downloading by itself" \
    '^[[:space:]]*provisioningBlock$'
check_present "PorTalistic/Views/Navigation/ContentView.swift" \
    "the sidebar's provisioning card no longer reads the Provisioner's activity" \
    'if let status = provisioner\.activity\.localizedDescription'

# ── Updates come from this project, and are asked about ────────────────────
# A fork that reads upstream's feed replaces itself with upstream on the first update check. And
# the check at launch installs nothing: it asks "Update and Restart" or "Later".
check_present "PorTalistic/Info.plist" \
    "SUFeedURL no longer points at this project's appcast — a fork that reads another project's feed replaces itself with that project on the first update check" \
    '<string>https://raw\.githubusercontent\.com/mcstig/PorTalistic/main/appcast\.xml</string>'
check_present "PorTalistic/Info.plist" \
    "Info.plist has no SUPublicEDKey — every update is checked against it, so without one this app can never update. Run Scripts/set-update-key.sh" \
    '<key>SUPublicEDKey</key>'
check_count "PorTalistic/Info.plist" 0 \
    "Info.plist names upstream Mythic — its feed or its key would hand this app's updates to upstream" \
    'getmythic|MythicApp'
check_present "PorTalistic/Utilities/Branding.swift" \
    "Branding.appcastURL isn't this project's appcast; it is the updater's switch and has to match SUFeedURL" \
    '^[[:space:]]*static let appcastURL: URL\? = \.init\(string: "https://raw\.githubusercontent\.com/mcstig/PorTalistic/main/appcast\.xml"\)'
check_absent "updates install without asking again — the check at launch must ask, Update and Restart or Later" \
    'sparkleUpdateAction|AutoUpdateAction|automaticallyDownloadsUpdates = true|automaticallyChecksForUpdates = true' \
    PorTalistic/
check_present "PorTalistic/Utilities/SparkleUpdateController.swift" \
    "nothing checks for updates when the app opens any more" \
    '^[[:space:]]*SparkleUpdateController\.shared\.checkForUpdates\(userInitiated: false\)'
check_present "PorTalistic/Utilities/SparkleUpdateController.swift" \
    "Update and Restart no longer restarts by itself — it asks a second time" \
    '^[[:space:]]*if restartWhenReady \{'
check_present "PorTalistic/Views/SparkleUpdater/SparkleUpdaterPreviewView.swift" \
    "the update prompt no longer offers Later" \
    'Text\("Later"\)'

# And a release reaches people only through appcast.xml, which only ever offers a higher build.
check_present "Scripts/release.sh" \
    "release.sh no longer adds the release to appcast.xml, so no installed copy is ever offered it" \
    'python3 Scripts/update-appcast\.py'
check_present "Scripts/update-appcast.py" \
    "update-appcast.py no longer refuses a build number that isn't higher — Sparkle would never offer that release, and nothing would say so" \
    'int\(existing\) >= int\(args\.build\)'

# ── Every runtime compiled in is a published one ───────────────────────────
# A runtime moves from `unreleased` into `shipped` only once its release is cut, and cutting
# it is when it gets its entry in the signed manifest. So each compiled-in id, URL and digest
# has to be in the manifest as well: one that isn't was never published — every user gets a
# 404 on first launch — or the two disagree, which the manifest merge only logs.
RUNTIME_CATALOGUE="PorTalistic/Utilities/Engine/RuntimeRelease.swift"
RUNTIME_MANIFEST="Compatibility/manifest.json"

# "<id> <url> <digest>" for each runtime's own download; support libraries come after the
# digest and have no id, so they are skipped.
SHIPPED_RUNTIMES=$(sed -n '/private static let shipped: \[RuntimeRelease\]/,/^    \]/p' "$RUNTIME_CATALOGUE" | awk '
    /^ *id: "/ { v = $0; sub(/.*id: "/, "", v); sub(/".*/, "", v); id = v; url = ""; next }
    id != "" && url == "" && /downloadURL: \.init\(string: "/ { v = $0; sub(/.*string: "/, "", v); sub(/".*/, "", v); url = v; next }
    id != "" && url != "" && /^ *sha256: "/ { v = $0; sub(/.*sha256: "/, "", v); sub(/".*/, "", v); print id, url, tolower(v); id = ""; url = "" }
')
MANIFEST_RUNTIMES=$(awk '
    /"id": "/ { v = $0; sub(/.*"id": "/, "", v); sub(/".*/, "", v); id = v; url = ""; next }
    id != "" && url == "" && /"downloadURL": "/ { v = $0; sub(/.*"downloadURL": "/, "", v); sub(/".*/, "", v); url = v; next }
    id != "" && url != "" && /"sha256": "/ { v = $0; sub(/.*"sha256": "/, "", v); sub(/".*/, "", v); print id, url, tolower(v); id = ""; url = "" }
' "$RUNTIME_MANIFEST")

if [ -z "$SHIPPED_RUNTIMES" ]; then
    CHECKS=$((CHECKS + 1))
    report "$RUNTIME_CATALOGUE" "found no runtimes in \`shipped\` — the catalogue changed shape and the published-runtime check inspected nothing"
else
    while IFS= read -r SHIPPED_RUNTIME; do
        [ -z "$SHIPPED_RUNTIME" ] && continue
        CHECKS=$((CHECKS + 1))
        if ! grep -qxF "$SHIPPED_RUNTIME" <<< "$MANIFEST_RUNTIMES"; then
            report "$RUNTIME_CATALOGUE" "${SHIPPED_RUNTIME%% *} is compiled in, but $RUNTIME_MANIFEST has no entry with the same URL and digest — publish the release and add it to the manifest first"
        fi
    done <<< "$SHIPPED_RUNTIMES"
fi

# ── Result ─────────────────────────────────────────────────────────────────
if [ "$FAILURES" -eq 0 ]; then
    echo "✓ $CHECKS invariants hold"
    exit 0
fi

echo "✗ $FAILURES of $CHECKS invariants violated"
[ "$EXIT_ON_FAILURE" -eq 1 ] && exit 1
exit 0
