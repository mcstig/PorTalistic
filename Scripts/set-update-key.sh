#!/bin/bash
#
#  set-update-key.sh
#  PorTalistic
#
#  Once, on the Mac that cuts releases: make PorTalistic's Sparkle signing key if this Mac has
#  none, and put its public half in Info.plist as SUPublicEDKey.
#
#  Every update is checked against that public key before Sparkle installs it, so it is what
#  stops anybody but you shipping an update to people who installed PorTalistic. The private
#  half stays in your login keychain; nothing here reads or prints it. Back it up yourself —
#  lose it and no installed copy will ever accept another update:
#
#      "$SPARKLE_BIN/generate_keys" -x ~/Desktop/portalistic-sparkle.key
#
#  then keep that file somewhere safe, and not in this repository (*.private-key is ignored,
#  but the safest copy of a key is one that was never inside a git working tree).

set -euo pipefail

cd "$(dirname "$0")/.."

die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
ok() { printf '\033[1;32m✓ %s\033[0m\n' "$1"; }

SPARKLE_BIN="${PORTALISTIC_SPARKLE_BIN:-}"
if [ -z "$SPARKLE_BIN" ]; then
    SPARKLE_BIN=$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d -path '*/artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -1)
fi

[ -n "$SPARKLE_BIN" ] && [ -x "$SPARKLE_BIN/generate_keys" ] \
    || die "Can't find Sparkle's tools. Build PorTalistic in Xcode once — that downloads them — or set PORTALISTIC_SPARKLE_BIN to Sparkle's bin folder."

# Makes the pair if the keychain has none; otherwise only reports the one it has. macOS may ask
# whether generate_keys can use your login keychain — allow it.
"$SPARKLE_BIN/generate_keys" > /dev/null || die "generate_keys failed."

PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" -p) || die "generate_keys couldn't print the public key."

# Written as text rather than through PlistBuddy, which would drop the comments explaining the
# other keys in Info.plist.
python3 - "$PUBLIC_KEY" <<'PYTHON'
import pathlib
import re
import sys

key = sys.argv[1].strip()
if not re.fullmatch(r"[A-Za-z0-9+/]{43}=", key):
    sys.exit("That doesn't look like an EdDSA public key: %r" % key)

plist = pathlib.Path("PorTalistic/Info.plist")
text = plist.read_text(encoding="utf-8")

current = re.search(r"<key>SUPublicEDKey</key>\s*<string>([^<]*)</string>", text)
if current:
    if current.group(1) == key:
        print("Info.plist already has this key.")
        sys.exit(0)
    sys.exit("Info.plist already has a different SUPublicEDKey. Every installed copy trusts that "
             "one, and replacing it means none of them will accept an update signed with the old "
             "key again. Change it by hand if that is really what you want.")

entry = "\t<key>SUPublicEDKey</key>\n\t<string>%s</string>\n" % key
if text.count("</dict>\n</plist>") != 1:
    sys.exit("Info.plist doesn't end the way this script expects; add the key by hand.")

plist.write_text(text.replace("</dict>\n</plist>", entry + "</dict>\n</plist>"), encoding="utf-8")
print("Added SUPublicEDKey to Info.plist.")
PYTHON

ok "Public key: $PUBLIC_KEY"
printf '\n  Back up the private key now — lose it and no installed copy accepts another update:\n'
printf '      "%s/generate_keys" -x ~/Desktop/portalistic-sparkle.key\n' "$SPARKLE_BIN"
printf '  Then move that file somewhere safe, outside this repository.\n\n'
