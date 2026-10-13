#!/usr/bin/env bash
# (selftest: may run during a game)
# crash-dump: a game's newest Unreal crash report (minidump and crash context) from its Proton
# prefix, gzipped as base64 between markers, to read where it crashed. Default Stellar Blade
# Demo (3564860); BOTTLE_TEST_APPID overrides.
set -u
APPID="${BOTTLE_TEST_APPID:-3564860}"
P=~/.local/share/Steam/steamapps/compatdata/$APPID/pfx/drive_c/users/steamuser
c=$(find "$P/AppData/Local" -maxdepth 4 -type d -path "*Saved/Crashes/*" 2>/dev/null | xargs -r ls -td 2>/dev/null | head -1)
[ -n "$c" ] || { echo "no crash folder"; exit 0; }
echo "== $c"; ls -la "$c"
for f in "$c"/*.dmp "$c"/*.runtime-xml; do
  [ -f "$f" ] || continue
  echo "==B64-BEGIN== $(basename "$f").gz"; gzip -c "$f" | base64 -w0; echo; echo "==B64-END=="
done
