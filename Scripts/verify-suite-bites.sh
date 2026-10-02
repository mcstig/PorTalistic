#!/bin/bash
#
#  verify-suite-bites.sh
#  PorTalistic
#
#  Created by Claude Opus 5 on 15/9/2026.
#
#  Puts each fault back and checks that the suite notices.
#
#  A regression suite that passes proves nothing on its own — a test can be green because the
#  code is right or because the test doesn't look at it, and the two are indistinguishable
#  until you break the code on purpose. This reintroduces each fault as a one-line edit, runs
#  the tests, and reports which tests caught it. Every mutation must fail at least one test.
#
#  Each edit is backed up byte-for-byte and restored immediately after its test run —
#  including on interrupt — and every restore is checked against the original's SHA-256
#  before the script moves on. Takes a few minutes: each mutation is an incremental rebuild
#  plus a test run.
#
#  Usage: Scripts/verify-suite-bites.sh

set -u

cd "$(dirname "$0")/.." || exit 1

BACKUP_DIR="$(mktemp -d)"
LOG="$(mktemp)"
MUTATED_FILE=""
MUTATED_SUM=""
RESTORE_FAILURES=0

digest() { shasum -a 256 "$1" | awk '{print $1}'; }

restore() {
    [ -n "$MUTATED_FILE" ] || return 0

    local backup="$BACKUP_DIR/$(basename "$MUTATED_FILE")"
    if [ -f "$backup" ]; then
        cp "$backup" "$MUTATED_FILE"
    fi

    # Verified, not assumed. This edits his working tree; leaving a mutation behind would be
    # a far worse bug than anything the script is looking for.
    if [ "$(digest "$MUTATED_FILE")" != "$MUTATED_SUM" ]; then
        echo "    ✗ FAILED TO RESTORE $MUTATED_FILE — the original is at $backup"
        RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
    fi

    MUTATED_FILE=""
    MUTATED_SUM=""
}
trap 'restore; echo; echo "interrupted — sources restored"; exit 130' INT TERM

mutate() {
    # mutate <file> <literal old> <literal new>
    MUTATED_FILE="$1"
    MUTATED_SUM="$(digest "$1")"
    cp "$1" "$BACKUP_DIR/$(basename "$1")"
    python3 - "$1" "$2" "$3" <<'PY'
import io, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(path, encoding="utf-8").read()
if s.count(old) != 1:
    sys.exit("  mutation target appears %d times in %s — the code has moved on, update this script" % (s.count(old), path))
io.open(path, "w", encoding="utf-8").write(s.replace(old, new))
PY
}

TOTAL=0
UNCAUGHT=0

check() {
    # check <name> <file> <old> <new>
    local name="$1" file="$2" old="$3" new="$4"
    TOTAL=$((TOTAL + 1))

    printf '▸ %s\n' "$name"
    if ! mutate "$file" "$old" "$new"; then
        UNCAUGHT=$((UNCAUGHT + 1))
        restore
        return
    fi

    xcodebuild test -scheme PorTalistic -destination 'platform=macOS' > "$LOG" 2>&1
    local status=$?
    restore

    local caught
    caught=$(grep -o "Test case '[^']*' failed" "$LOG" | sed "s/Test case '//;s/' failed//" | sort -u)

    if [ -n "$caught" ]; then
        echo "$caught" | sed 's/^/    caught by /'
    elif grep -q 'error:' "$LOG"; then
        # A mutation that won't compile is also a kind of catch, but a weaker one: say so
        # rather than counting it as a passing test.
        echo "    did not build — caught by the compiler, not by a test"
    elif [ "$status" -ne 0 ]; then
        echo "    the run failed without naming a test (exit $status) — check the log"
        UNCAUGHT=$((UNCAUGHT + 1))
    else
        echo "    ✗ NOT CAUGHT — the fault went back in and every test still passed"
        UNCAUGHT=$((UNCAUGHT + 1))
    fi
}

echo "▸ Reintroducing each fault to check the suite notices"
echo

check "the DPI stops following Retina Mode (the small window)" \
    PorTalistic/Utilities/Wine/WineInterface+Container.swift \
    'retinaMode ? 192 : 96' \
    '192'

check "Retina Mode goes back to defaulting on" \
    PorTalistic/Utilities/Wine/WineInterface+Container.swift \
    'retinaMode: Bool = false,' \
    'retinaMode: Bool = true,'

check "existing containers keep the old Retina-on default (the small window)" \
    PorTalistic/Utilities/Migrator.swift \
    'migrated.retinaMode = false' \
    'migrated.retinaMode = settings.retinaMode'

check "Wine is allowed to ask for wine-mono again (the boot that never returns)" \
    PorTalistic/Utilities/Wine/WineInterface.swift \
    'static let baseDLLOverrides: String = "mscoree=d;mshtml=d"' \
    'static let baseDLLOverrides: String = ""'

check "hidden storefronts are offered as filters again (the Steam dead end)" \
    PorTalistic/Utilities/Game/Game+Extensions.swift \
    'static var available: [Self] { allCases.filter(\.isAvailable) }' \
    'static var available: [Self] { allCases }'

check "a refresh overwrites a hand-made settings choice" \
    PorTalistic/Utilities/Game/Game.swift \
    'forCodingKey: .isSettingsAutomatic, strategy: { $0 && $1 }' \
    'forCodingKey: .isSettingsAutomatic, strategy: { $1 }'

check "/Volumes itself counts as an external volume" \
    PorTalistic/Utilities/Extensions/Built-in/URL+Extensions.swift \
    'return components.count > 2 && components[1] == "Volumes"' \
    'return components.count > 1 && components[1] == "Volumes"'

check "a Windows program keeps the launcher's name (BioshockHD.exe (Mythic) in Force Quit)" \
    PorTalistic/Utilities/Wine/WineInterface+ApplicationName.swift \
    'let preferred = "\(program) (\(brand))"' \
    'let preferred = name'

check "a folder that only starts like the engine's counts as the engine's" \
    PorTalistic/Utilities/Wine/WineInterface+ApplicationName.swift \
    'return executable.hasPrefix(root.hasSuffix("/") ? root : root + "/")' \
    'return executable.hasPrefix(root)'

check "the rebrand overrides an install folder somebody chose" \
    PorTalistic/Utilities/Migrator.swift \
    'guard !hasChosenInstallFolder, let upstreamFolderContents else { return false }' \
    'guard let upstreamFolderContents else { return false }'

check "a launch counts as work on a game's files again (the library reshuffles around a game being played, and quitting force-quits it)" \
    PorTalistic/Utilities/GameOperation/GameOperation.swift \
    'case .launch:  false' \
    'case .launch:  true'

check "the game appearing no longer ends the Play spinner" \
    PorTalistic/Utilities/GameOperation/GameOperation.swift \
    'launchPhase = .running' \
    'launchPhase = .starting'

check "an install that finished while the app was closed is downloaded all over again" \
    PorTalistic/Utilities/GameOperation/PendingInstalls.swift \
    'guard gameIsInLibrary, !gameIsInstalled else { return .forget }' \
    'guard gameIsInLibrary else { return .forget }'

check "a download that is already running is started a second time on top of itself" \
    PorTalistic/Utilities/GameOperation/PendingInstalls.swift \
    'guard !gameHasAnOperation else { return .wait }' \
    'guard !gameHasAnOperation else { return .resume }'

check "legendary's installed-games lock is read as an ordinary failure again (a modal instead of a wait)" \
    PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift \
    'if errorReason.localizedCaseInsensitiveContains("installed data lock") {' \
    'if errorReason.isEmpty {'

check "legendary's housekeeping stops caring what is downloading" \
    PorTalistic/Utilities/GameManager/Legendary/LegendaryInterface.swift \
    'pendingEpicInstalls == 0 && fileOperationsInFlight == 0' \
    'true'

check "housekeeping counts installs but not updates or repairs" \
    PorTalistic/Utilities/GameOperation/GameOperation.swift \
    "            case .launch:  false
            default:        true" \
    "            case .launch, .update, .repair:  false
            default:        true"

# The other half of this fault — that stopping an unlaunched process must not *raise* — is not
# mutated here on purpose. Putting `terminate()` back would abort the whole test run with an
# uncaught NSException rather than failing a named test, which this script would report as "the
# run failed without naming a test". That half is held by `check-invariants.sh` instead, which
# refuses the call outright. This mutation covers the way the fix fails quietly: a guard so
# eager that nothing is ever stopped.
check "stopping a running process quietly does nothing" \
    PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift \
    '        kill(pid, signal)' \
    '        _ = signal'

check "a stopped download keeps the Dock icon's badge up" \
    PorTalistic/Utilities/GameOperation/GameOperationManager.swift \
    '$0.type.modifiesFiles && !$0.isCancelled && !$0.isFinished' \
    '$0.type.modifiesFiles && !$0.isFinished'

check "the Dock icon's badge follows whichever download was queued first, not the one running" \
    PorTalistic/Utilities/GameOperation/GameOperationManager.swift \
    'downloads.first(where: { $0.isExecuting }) ?? downloads.first ?? counted.first' \
    'counted.first'

check "an uninstall running ahead of a download hides the download's ring on the Dock icon" \
    PorTalistic/Utilities/GameOperation/GameOperationManager.swift \
    'let downloads = counted.filter { [.install, .update, .repair].contains($0.type) }' \
    'let downloads = counted'

check "Z to A is ignored and the library stays A to Z" \
    PorTalistic/Views/Unified/Models/GameListViewModel.swift \
    'return (comparison == .orderedAscending) == (titleOrder == .ascending)' \
    'return comparison == .orderedAscending'

check "Installed Games First can no longer be switched off" \
    PorTalistic/Views/Unified/Models/GameListViewModel.swift \
    '            if installedFirst {' \
    '            if true {'

check "names are compared by code point again (lowercase after capitals, Game 10 before Game 2)" \
    PorTalistic/Utilities/Game/Game+Extensions.swift \
    'lhs.title.localizedStandardCompare(rhs.title)' \
    'lhs.title.compare(rhs.title)'

check "clearing a hover that is already clear redraws every card again" \
    PorTalistic/Views/Unified/Components/GameCard/GameCard.swift \
    '        if gameID != nil { gameID = nil }' \
    '        gameID = nil'

check "a provisioning pass asked for during a pass is dropped, the way every request after launch used to be" \
    PorTalistic/Utilities/Compatibility/Provisioner.swift \
    '            askedAgain = true
            return' \
    '            return'

check "a launch starts a second download of a build the pass is already fetching" \
    PorTalistic/Utilities/Compatibility/Provisioner.swift \
    '        if let inFlight = running[key] {
            return try await inFlight.value
        }' \
    ''

check "a failed download leaves its build marked as downloading for good" \
    PorTalistic/Utilities/Compatibility/Provisioner.swift \
    '        defer { running[key] = nil }' \
    ''

check "the wineboot that creates a container can ask for wine-mono again" \
    PorTalistic/Utilities/Wine/WineInterface.swift \
    '        capturedEnvironment["WINEDLLOVERRIDES"] = withBaseDLLOverrides(capturedEnvironment["WINEDLLOVERRIDES"])' \
    ''

check "a Wine that can't be started is reported as a boot that ran out of time again" \
    PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift \
    '            return .couldNotStart(error.localizedDescription)' \
    '            return .killed'

check "creating a container waits for Wine to announce it again (every Wine 11 container failed)" \
    PorTalistic/Utilities/Wine/WineInterface.swift \
    '        guard exitStatus == 0 else {' \
    '        guard exitStatus == 0, standardError?.contains("has been updated") == true else {'

check "a prefix Windows was never installed into is taken for a container" \
    PorTalistic/Utilities/Wine/WineInterface.swift \
    '        guard FileManager.default.fileExists(atPath: kernel32.path) else {' \
    '        guard true else {'

check "the Windows version is read from one stream again (every Wine 11 container re-set it before each launch)" \
    PorTalistic/Utilities/Wine/WineInterface.swift \
    '        let lines = [output.standardOutput, output.standardError]' \
    '        let lines = [output.standardOutput]'

check "one byte that isn't UTF-8 throws a whole transcript away again" \
    PorTalistic/Utilities/Extensions/Built-in/Process+Extensions.swift \
    '            (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }' \
    '            try? String(contentsOf: url, encoding: .utf8)'

check "BioShock's d3dcompiler goes back to native-only (a verb that failed to install is a game that won't start)" \
    PorTalistic/Utilities/Compatibility/CompatibilityDatabase.swift \
    '"d3dcompiler_43": "n,b",' \
    '"d3dcompiler_43": "n",'

check "legendary's install path runs on past the end of its line" \
    PorTalistic/Utilities/GameOperation/GameOperation.swift \
    '        let line = chunk.output[marker.upperBound...].prefix(while: { !$0.isNewline })' \
    '        let line = chunk.output[marker.upperBound...]'

check "a container the bundled engine already has is offered again (nil is how a container names the engine)" \
    PorTalistic/Utilities/Compatibility/Provisioner.swift \
    '        return runtimes.filter { !served.contains($0.origin == .bundledEngine ? nil : $0.id) }' \
    '        return runtimes.filter { !served.contains($0.id) }'

check "builds PorTalistic installed are no longer expected to have containers (Wine 11.16 installed, container deleted, nothing asked)" \
    PorTalistic/Utilities/Compatibility/Provisioner.swift \
    '        let managed = candidates.filter { $0.origin == .managed }' \
    '        let managed: [Runtime] = []'

check "the bundled engine goes back to being the default runtime" \
    PorTalistic/Utilities/Compatibility/RuntimeSelection.swift \
    '        byCatalogueOrder(viable.filter { $0.origin != .bundledEngine })
            + viable.filter { $0.origin == .bundledEngine }' \
    '        viable.filter { $0.origin == .bundledEngine }
            + byCatalogueOrder(viable.filter { $0.origin != .bundledEngine })'

# ── Nothing may be left changed ────────────────────────────────────────────
echo
if git diff --quiet -- PorTalistic 2>/dev/null; then
    echo "note: no sources differ from HEAD"
elif [ -n "$(git status --porcelain -- PorTalistic)" ]; then
    echo "note: PorTalistic/ still has the working-tree changes it had before this ran"
fi

echo
if [ "$RESTORE_FAILURES" -gt 0 ]; then
    echo "✗ $RESTORE_FAILURES file(s) could not be restored — originals kept in $BACKUP_DIR"
    exit 2
fi

rm -rf "$BACKUP_DIR" "$LOG"

if [ "$UNCAUGHT" -eq 0 ]; then
    echo "✓ all $TOTAL faults were caught"
    exit 0
fi

echo "✗ $UNCAUGHT of $TOTAL faults went unnoticed — those tests are decoration"
exit 1
