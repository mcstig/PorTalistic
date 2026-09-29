#!/bin/bash
#
#  verify-appcast.sh
#  PorTalistic
#
#  Before pushing appcast.xml: is the newest download it lists live, and is it the file the
#  appcast describes? Run it after the zip is attached to the GitHub release. Pushing an appcast
#  whose download 404s — or whose length is wrong, which Sparkle treats as a failed download —
#  offers every copy of the app an update it can't get.

set -euo pipefail

cd "$(dirname "$0")/.."

die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
ok() { printf '\033[1;32m✓ %s\033[0m\n' "$1"; }

ENTRY=$(python3 -c 'import sys, xml.etree.ElementTree as ET
item = ET.parse("appcast.xml").getroot().find("channel/item")
if item is None:
    sys.exit("appcast.xml lists no releases yet")
enclosure = item.find("enclosure")
print(enclosure.get("url"), enclosure.get("length"))') || die "Couldn't read appcast.xml."

URL=${ENTRY% *}
LENGTH=${ENTRY##* }

printf 'Checking %s\n' "$URL"

# -L follows GitHub's redirect to wherever it keeps release files; the last status and length
# are the file's own.
HEADERS=$(curl -sSIL --max-time 30 "$URL") || die "Couldn't reach $URL"
STATUS=$(printf '%s\n' "$HEADERS" | tr -d '\r' | awk 'toupper($1) ~ /^HTTP\// { code = $2 } END { print code }')
SIZE=$(printf '%s\n' "$HEADERS" | tr -d '\r' | awk 'tolower($1) == "content-length:" { size = $2 } END { print size }')

[ "$STATUS" = "200" ] || die "The download answers HTTP ${STATUS:-nothing}. Attach the zip to the release (and publish it) before pushing appcast.xml."
[ "$SIZE" = "$LENGTH" ] || die "The download is $SIZE bytes and appcast.xml says $LENGTH. That is a different file from the one release.sh signed."

ok "Live, and the size matches ($SIZE bytes). Safe to push appcast.xml."
