#!/bin/bash
#
#  release.sh
#  PorTalistic
#
#  Created by Claude Opus 5 on 24/9/2026.
#
#  Archive, sign with a Developer ID, notarise, staple, and produce something people can open.
#
#  Why this is a script and not a checklist: every step here fails in a way that still leaves a
#  .app behind. An unsigned build, a signed-but-unnotarised build and a notarised-but-unstapled
#  build all open fine on the Mac that made them, and all three are refused on somebody else's —
#  "PorTalistic is damaged and can't be opened", which reads as a corrupt download rather than
#  as a signing mistake. So each step is verified here rather than assumed.
#
#  Usage:
#      Scripts/release.sh
#
#  The signing team comes from the Xcode project. Set PORTALISTIC_TEAM_ID only to override it.
#
#  Requirements, none of which this script can create for you:
#      - An Apple Developer membership (the free tier cannot notarise).
#      - A "Developer ID Application" certificate in the login keychain.
#      - A notarytool keychain profile. Create it once, interactively, with your own credentials:
#            xcrun notarytool store-credentials PorTalistic-Notary \
#                --apple-id <your-apple-id> --team-id <your-team-id>
#        It will ask for an app-specific password from appleid.apple.com. That password is
#        yours: it goes into your keychain and never into this repository or this script.

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="PorTalistic"
CONFIGURATION="Release"
NOTARY_PROFILE="${PORTALISTIC_NOTARY_PROFILE:-PorTalistic-Notary}"
BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/PorTalistic.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/PorTalistic.app"

die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1;34m▸ %s\033[0m\n' "$1"; }
ok() { printf '\033[1;32m✓ %s\033[0m\n' "$1"; }

# ── Preconditions ──────────────────────────────────────────────────────────

# The project normally carries the team, because picking it in Xcode is the obvious way to set
# it. The environment variable is an override, for CI or a second account — not a requirement.
if [ -z "${PORTALISTIC_TEAM_ID:-}" ]; then
    PORTALISTIC_TEAM_ID=$(sed -n 's/.*DEVELOPMENT_TEAM = "\{0,1\}\([A-Z0-9]\{10\}\)"\{0,1\};.*/\1/p' \
        PorTalistic.xcodeproj/project.pbxproj | head -1)
fi

[ -n "$PORTALISTIC_TEAM_ID" ] || die "No signing team. Pick one in Xcode under Signing & Capabilities, or set PORTALISTIC_TEAM_ID."

IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)

case "$IDENTITIES" in
    *"Developer ID Application"*) ;;
    *) die "No \"Developer ID Application\" certificate in the keychain. An Apple Development certificate cannot be notarised, and a release signed with one is refused on every Mac but this one." ;;
esac

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "No notarytool profile called \"$NOTARY_PROFILE\". Create it once: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your-apple-id> --team-id $PORTALISTIC_TEAM_ID"

step "Checking source invariants"
bash Scripts/check-invariants.sh || die "Invariants are violated. Fix them before cutting a release — several of them are things that fail silently for users."

# ── Build ──────────────────────────────────────────────────────────────────

step "Archiving"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

ARCHIVE_LOG="$BUILD_DIR/archive.log"

if ! xcodebuild archive \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$PORTALISTIC_TEAM_ID" \
    > "$ARCHIVE_LOG" 2>&1
then
    printf '\n'
    grep -E "error:|fatal error:|The following build commands failed" "$ARCHIVE_LOG" | head -20
    die "Archiving failed. The whole log is at $ARCHIVE_LOG."
fi

[ -d "$ARCHIVE" ] || die "xcodebuild reported success but produced no archive. Log: $ARCHIVE_LOG"
ok "Archived"

step "Exporting with a Developer ID"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$PORTALISTIC_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

EXPORT_LOG="$BUILD_DIR/export.log"

if ! xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    > "$EXPORT_LOG" 2>&1
then
    printf '\n'
    grep -E "error:|Error Domain|reason" "$EXPORT_LOG" | head -20
    die "Exporting failed. The whole log is at $EXPORT_LOG. A Developer ID export needs the certificate *and* its private key — an imported .cer without the key exports nothing."
fi

[ -d "$APP" ] || die "xcodebuild reported success but exported no app. Log: $EXPORT_LOG"
ok "Exported"

# ── Sign what Xcode doesn't ────────────────────────────────────────────────

step "Signing the bundled command-line helpers"

# Xcode hardens what it builds. It does not touch a folder reference copied into
# `Contents/Resources`, so `legendary` and `gogdl` — and the hundred-odd `.so` files inside
# their PyInstaller `_internal` directories — arrive unsigned and unhardened, and Apple refuses
# the whole archive for it:
#
#     The executable does not have the hardened runtime enabled.
#         .../Contents/Resources/legendary/cli
#
# Signed here rather than in a build phase because this is the only path that makes a release,
# and a build phase that signs with a Developer ID would ask for the key on every ordinary
# build.
SIGNING_IDENTITY=$(printf '%s\n' "$IDENTITIES" \
    | grep "Developer ID Application" \
    | grep "$PORTALISTIC_TEAM_ID" \
    | head -1 \
    | sed 's/.*"\(.*\)".*/\1/')

[ -n "$SIGNING_IDENTITY" ] || die "Found a Developer ID certificate but couldn't read its name for team $PORTALISTIC_TEAM_ID."

# Inside out: nested code first, the bundle last. Signing the outer app first and the inner
# files afterwards invalidates the outer signature, and `codesign --verify --deep` then fails
# with a sealed-resource mismatch that says nothing about why.
# Via files rather than a pipeline into `$( )`, and that is not a style choice: macOS ships
# bash 3.2, whose parser mishandles a `case` statement inside a command substitution. It is a
# syntax error there and valid everywhere else — including the Linux box these scripts get
# checked on — so `bash -n` passes and the release fails on the only machine that matters.
#
# Piping into the signing loop would be wrong for a second reason: `die` inside a `while` on
# the right of a pipe runs in a subshell, so a failed signature would print and carry on.
CANDIDATES="$BUILD_DIR/resource-binaries.txt"
HELPER_LIST="$BUILD_DIR/helpers-to-sign.txt"

find "$APP/Contents/Resources" -type f -perm -u+x -print > "$CANDIDATES" 2>/dev/null || true
: > "$HELPER_LIST"

while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    DESCRIPTION=$(file -b "$candidate" 2>/dev/null || true)

    case "$DESCRIPTION" in
        *Mach-O*) printf '%s\n' "$candidate" >> "$HELPER_LIST" ;;
    esac
done < "$CANDIDATES"

COUNT=$(wc -l < "$HELPER_LIST" | tr -d ' ')

if [ "$COUNT" -gt 0 ]; then
    printf '  %s Mach-O file(s) under Resources\n' "$COUNT"

    while IFS= read -r binary; do
        [ -n "$binary" ] || continue
        codesign --force --options runtime --timestamp \
            --entitlements Scripts/helper-entitlements.plist \
            --sign "$SIGNING_IDENTITY" "$binary" >/dev/null 2>&1 \
            || die "Couldn't sign $binary"
    done < "$HELPER_LIST"

    ok "Helpers signed and hardened"
else
    printf '  Nothing to sign under Resources.\n'
fi

# Re-seal the bundle: its signature covers those files, and they have all just changed.
step "Re-signing the app"

codesign --force --options runtime --timestamp \
    --entitlements PorTalistic/PorTalistic.entitlements \
    --sign "$SIGNING_IDENTITY" "$APP" >/dev/null 2>&1 \
    || die "Couldn't re-sign the app bundle after signing its helpers."

ok "Re-signed"

# ── Verify the signature before spending a notarisation on it ──────────────

step "Verifying the signature"

VERIFY_LOG="$BUILD_DIR/codesign-verify.log"

codesign --verify --deep --strict --verbose=2 "$APP" > "$VERIFY_LOG" 2>&1 \
    || { tail -20 "$VERIFY_LOG"; die "The signature does not verify. Notarising this would fail anyway. Full output: $VERIFY_LOG"; }

# Hardened runtime is not optional: notarisation refuses a build without it. Checked here
# because the setting lives in the project and is easy to turn off while chasing something else.
SIGNATURE=$(codesign --display --verbose=2 "$APP" 2>&1 || true)

case "$SIGNATURE" in
    *"flags="*"runtime"*) ;;
    *) printf '%s\n' "$SIGNATURE" | grep -i flags || true
       die "The app is not built with the hardened runtime, which notarisation requires." ;;
esac

# App Sandbox would break every game launch: Wine runs as a child process that reads and writes
# the user's game folders and spawns its own children, none of which a sandboxed parent permits.
ENTITLEMENTS=$(codesign --display --entitlements - "$APP" 2>/dev/null || true)

case "$ENTITLEMENTS" in
    *"app-sandbox"*)
        die "The app has the App Sandbox entitlement. Wine runs as a child process outside the bundle — sandboxed, no game will launch." ;;
esac

ok "Signature and entitlements look right"

# ── Notarise ───────────────────────────────────────────────────────────────

step "Notarising (this waits on Apple, usually a few minutes)"

ZIP="$BUILD_DIR/PorTalistic-notarisation.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# `notarytool submit --wait` exits 0 whatever Apple decides. It waits for the verdict and
# reports it in the output, and a rejected submission looks exactly like an accepted one to
# `$?` — so the status has to be read, not inferred. Getting this wrong meant the script
# announced a successful notarisation of a build Apple had refused, and the first sign of
# trouble was stapling failing with "Record not found", which reads like an Apple outage.
SUBMIT_LOG="$BUILD_DIR/notarisation.log"

xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait > "$SUBMIT_LOG" 2>&1 || true

cat "$SUBMIT_LOG"

SUBMISSION_ID=$(sed -n 's/^ *id: \(.*\)$/\1/p' "$SUBMIT_LOG" | head -1)
STATUS=$(sed -n 's/^ *status: \(.*\)$/\1/p' "$SUBMIT_LOG" | tail -1)

if [ "$STATUS" != "Accepted" ]; then
    printf '\n\033[1;33mApple'"'"'s reasons:\033[0m\n'

    if [ -n "$SUBMISSION_ID" ]; then
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" \
            "$BUILD_DIR/notarisation-issues.json" 2>/dev/null || true

        if [ -f "$BUILD_DIR/notarisation-issues.json" ]; then
            python3 - "$BUILD_DIR/notarisation-issues.json" <<'PYTHON' || cat "$BUILD_DIR/notarisation-issues.json"
import json, sys
report = json.load(open(sys.argv[1]))
for issue in (report.get("issues") or [])[:20]:
    print(f"  • {issue.get('message')}")
    print(f"      {issue.get('path')}")
PYTHON
        fi
    fi

    die "Apple refused this build (status: ${STATUS:-unknown}). Full report: $BUILD_DIR/notarisation-issues.json"
fi

ok "Notarised (accepted by Apple)"

step "Stapling"
xcrun stapler staple "$APP" || die "Stapling failed. Without the staple the app needs a network round-trip to open, and is refused offline."

spctl --assess --type execute --verbose=2 "$APP" \
    || die "Gatekeeper still refuses the app. Something above reported success that wasn't."

ok "Stapled and accepted by Gatekeeper"

# ── Ship ───────────────────────────────────────────────────────────────────

step "Packaging"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
RELEASE_ZIP="$BUILD_DIR/PorTalistic-$VERSION.zip"

ditto -c -k --keepParent "$APP" "$RELEASE_ZIP"

printf '\n'
ok "Ready: $RELEASE_ZIP"
printf '  sha256: %s\n' "$(shasum -a 256 "$RELEASE_ZIP" | cut -d' ' -f1)"
printf '\n  Sparkle needs this file signed with the EdDSA key as well — see blocker 6 in\n  claude/ship-readiness.md. Until the appcast exists, this zip is the only way a user\n  gets an update.\n\n'
