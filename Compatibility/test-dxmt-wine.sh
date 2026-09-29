#!/bin/bash
#
#  test-dxmt-wine.sh
#  PorTalistic
#
#  Created by Claude Opus 5 on 18/9/2026.
#  Copyright © 2026 Michael Stoian
#
#  Checks the Wine that build-dxmt-wine.sh built, in the ways its own sanity stage can't:
#  these open windows, so they need a logged-in Mac, and the last one needs a person.
#
#      bash Compatibility/test-dxmt-wine.sh           the automatic checks, a few seconds
#      bash Compatibility/test-dxmt-wine.sh --look    then one of each kind of message box
#
#  ── What it checks ────────────────────────────────────────────────────────────────────
#
#  Message boxes. This Wine shows them as native macOS alerts
#  (patches/native-message-boxes.patch), and tests/msgbox-test.c answers a run of them
#  the way programs and automation do (a WM_COMMAND, Return, EndDialog), checking what
#  each returns, that Wine's own dialog stayed hidden behind the alert, and that owners
#  and the thread's other windows were disabled and then given back. It runs as a 64-bit
#  and as a 32-bit program, and once more with UseNativeMessageBoxes=n, which has to bring
#  Wine's own dialog back rather than leave nothing on screen.
#
#  Nothing needs clicking. Each alert is on screen for under a second.
#
#  The same checks fail on a Wine without the patch, one line each saying Wine's dialog
#  was on screen: that is how they were checked before this Wine was ever built.

set -euo pipefail

WINE_VERSION="11.16"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO/Compatibility/tests/msgbox-test.c"

WORK="$HOME/Games/wine-dxmt-build"
PREFIX="$WORK/out/wine-dxmt-$WINE_VERSION"
TESTS="$WORK/tests"

say()  { printf '\n\033[1;35m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

LOOK=0
[[ "${1:-}" == "--look" ]] && LOOK=1

# ── Preflight ────────────────────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || die "This has to run on macOS, logged in: it opens windows."
[[ -x "$PREFIX/bin/wine" ]] || die "No build at $PREFIX. Run: bash Compatibility/build-dxmt-wine.sh"
[[ -f "$SOURCE" ]] || die "$SOURCE is missing"

# build-dxmt-wine.sh installed mingw-w64 for Wine's own PE side; the test program uses it too.
if command -v brew >/dev/null 2>&1; then
    export PATH="$(brew --prefix)/bin:$PATH"
fi
command -v x86_64-w64-mingw32-gcc >/dev/null && command -v i686-w64-mingw32-gcc >/dev/null \
    || die "mingw-w64 is missing: brew install mingw-w64"

say "Building the test program"
mkdir -p "$TESTS"
x86_64-w64-mingw32-gcc -O2 -Wall -o "$TESTS/msgbox-test64.exe" "$SOURCE" -luser32 \
    || die "the 64-bit test program didn't build"
i686-w64-mingw32-gcc -O2 -Wall -o "$TESTS/msgbox-test32.exe" "$SOURCE" -luser32 \
    || die "the 32-bit test program didn't build"
ok "64-bit and 32-bit"

# A prefix of its own, so nothing here touches a game's. Kept between runs, because making
# one is most of a minute.
export WINEPREFIX="$TESTS/prefix"
export WINEDEBUG="-all"
# No Mono or Gecko: the prompts to install them are exactly the kind of dialog this tests,
# and nothing here needs .NET or a browser engine.
export WINEDLLOVERRIDES="mscoree,mshtml="
WINE="$PREFIX/bin/wine"
KEY='HKCU\Software\Wine\Mac Driver'

if [[ ! -f "$WINEPREFIX/system.reg" ]]; then
    say "Making a scratch prefix (once)"
    "$WINE" wineboot -i >/dev/null 2>&1 || die "wineboot failed in $WINEPREFIX"
fi
# The default, whatever an interrupted run left behind.
"$WINE" reg delete "$KEY" /v UseNativeMessageBoxes /f >/dev/null 2>&1 || true
ok "prefix at $WINEPREFIX"

# ── Checks ───────────────────────────────────────────────────────────────────────────────
# The test program exits with the number of checks that failed, and wine passes that on.
failures=0
run() {
    local title="$1" status=0
    shift
    say "$title"
    "$WINE" "$@" || status=$?
    failures=$((failures + status))
}

run "Native alerts, 64-bit program" "$TESTS/msgbox-test64.exe"
run "Native alerts, 32-bit program" "$TESTS/msgbox-test32.exe"

"$WINE" reg add "$KEY" /v UseNativeMessageBoxes /t REG_SZ /d n /f >/dev/null 2>&1
run "UseNativeMessageBoxes=n, which has to bring Wine's own dialog back" "$TESTS/msgbox-test64.exe" dialog
"$WINE" reg delete "$KEY" /v UseNativeMessageBoxes /f >/dev/null 2>&1 || true

if (( LOOK )); then
    say "Your turn: one of each kind of message box, answered however you like"
    "$WINE" "$TESTS/msgbox-test64.exe" gallery || true
fi

"$PREFIX/bin/wineserver" -k >/dev/null 2>&1 || true

(( failures == 0 )) || die "$failures check(s) failed; the FAIL lines above say which, and why"

say "All message box checks passed"
(( LOOK )) || printf '  To see them for yourself: bash Compatibility/test-dxmt-wine.sh --look\n'
