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
#      Scripts/release.sh            the next version: 0.6.20 becomes 0.6.21, build 71 becomes 72
#      Scripts/release.sh 0.7.0      a version of your choosing, and a new build number
#
#  The version is only raised when the project's build number has already been released (it is
#  in the committed appcast.xml). Running this again after a failed attempt keeps the number it
#  chose the first time. Asking for a different version always takes a new build number, even
#  over one that was never published — that build may already be on a test Mac. Release notes, if you want them in the update prompt, go in
#  ReleaseNotes/<version>.md — they are read at the very end, so writing them while Apple
#  notarises is fine.
#
#  The signing team comes from the Xcode project. Set PORTALISTIC_TEAM_ID only to override it.
#
#  Requirements, none of which this script can create for you:
#      - Sparkle's signing key in the login keychain, with its public half in Info.plist. Once:
#            Scripts/set-update-key.sh
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

# ── Version ────────────────────────────────────────────────────────────────

step "Setting the version"

# An entry an earlier run added to appcast.xml, never published, belongs to this run to write
# again — and would otherwise be refused as a build that is already there.
if ! git diff --quiet -- appcast.xml 2>/dev/null; then
    git checkout -- appcast.xml
    printf '  appcast.xml had an entry that was never published; put back to the last commit.\n'
fi

VERSIONING=$(python3 Scripts/bump-version.py "${1:-}") || die "Couldn't settle the version (see above)."
read -r NEXT_VERSION NEXT_BUILD BUMPED <<< "$VERSIONING"

if [ "$BUMPED" = "bumped" ]; then
    ok "Releasing $NEXT_VERSION (build $NEXT_BUILD), raised from the last release"
else
    ok "Releasing $NEXT_VERSION (build $NEXT_BUILD), which hasn't been released yet"
fi

if [ ! -f "ReleaseNotes/$NEXT_VERSION.md" ]; then
    printf '  No ReleaseNotes/%s.md, so the update prompt will show no notes. Write it now if you\n  want some: it is read at the end, after notarising.\n' "$NEXT_VERSION"
fi

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

# ── Sparkle ────────────────────────────────────────────────────────────────

step "Signing the update and adding it to appcast.xml"

# What Sparkle compares is the build number, not the version people read. A release whose
# CFBundleVersion isn't higher than the last one's is offered to nobody — update-appcast.py
# refuses it rather than let that happen quietly.
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
MINIMUM_SYSTEM=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "14.0")

# Without the public key in the app, every copy of this release would refuse every update
# after it. Better to find that out now than from the next release.
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" > /dev/null 2>&1 \
    || die "This build has no SUPublicEDKey, so it could never accept an update. Run Scripts/set-update-key.sh, then release again."

SPARKLE_BIN="${PORTALISTIC_SPARKLE_BIN:-}"
if [ -z "$SPARKLE_BIN" ]; then
    SPARKLE_BIN=$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d -path '*/artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -1)
fi

[ -n "$SPARKLE_BIN" ] && [ -x "$SPARKLE_BIN/sign_update" ] \
    || die "Can't find Sparkle's sign_update. Build the project in Xcode once, or set PORTALISTIC_SPARKLE_BIN to Sparkle's bin folder."

# Signed with the private key in the login keychain, the one set-update-key.sh made. It never
# leaves the keychain; this only reads back the signature and the length.
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$RELEASE_ZIP") \
    || die "sign_update failed. Is PorTalistic's Sparkle key in this Mac's login keychain?"

# The tag and the asset name are what the URL is built from — publish with exactly these.
TAG="v$VERSION"
DOWNLOAD_URL="https://github.com/mcstig/PorTalistic/releases/download/$TAG/$(basename "$RELEASE_ZIP")"

python3 Scripts/update-appcast.py \
    --appcast appcast.xml \
    --version "$VERSION" \
    --build "$BUILD_NUMBER" \
    --minimum-system "$MINIMUM_SYSTEM" \
    --url "$DOWNLOAD_URL" \
    --signature "$SIGNATURE" \
    --notes "ReleaseNotes/$VERSION.md" \
    || die "Couldn't add this release to appcast.xml (see above)."

ok "appcast.xml offers $VERSION (build $BUILD_NUMBER)"

printf '\n'
ok "Ready: $RELEASE_ZIP"
printf '  sha256: %s\n' "$(shasum -a 256 "$RELEASE_ZIP" | cut -d' ' -f1)"
printf '\nPublish it in this order — the other way round, every copy of the app is offered a download\nthat 404s:\n\n'

STEP=1

# The version change first, so the tag GitHub makes points at the code that was built.
if ! git diff --quiet -- PorTalistic.xcodeproj/project.pbxproj || [ -n "$(git status --porcelain -- ReleaseNotes)" ]; then
    printf '  %d. git add PorTalistic.xcodeproj/project.pbxproj ReleaseNotes && git commit -m "Version %s" && git push origin HEAD\n' "$STEP" "$VERSION"
    STEP=$((STEP + 1))
fi

printf '  %d. On GitHub, draft a new release with the tag %s, attach %s,\n' "$STEP" "$TAG" "$RELEASE_ZIP"
printf '     and publish it as a normal release (not a pre-release).\n'
printf '  %d. Scripts/verify-appcast.sh\n' "$((STEP + 1))"
printf '  %d. git add appcast.xml && git commit -m "Offer %s" && git push origin HEAD\n\n' "$((STEP + 2))" "$VERSION"
