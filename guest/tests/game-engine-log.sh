#!/usr/bin/env bash
# (selftest: may run during a game)
# game-engine-log: a game's own (Unreal Engine) log and newest crash report from its Proton
# prefix: errors, the fatal message and the log's end. APPID from the file logs/.selftest-arg
# isn't supported, so the default is Stellar Blade Demo (3564860); BOTTLE_TEST_APPID overrides.
set -u
APPID="${BOTTLE_TEST_APPID:-3564860}"
S=~/.local/share/Steam
P="$S/steamapps/compatdata/$APPID/pfx/drive_c/users/steamuser"
echo "== prefix: $P"
logs=$(find "$P/AppData/Local" "$P/Documents" "$P/Saved Games" -path "*Saved/Logs/*.log" -newermt "-2 hours" 2>/dev/null | xargs -r ls -t 2>/dev/null | head -3)
echo "== engine logs (newest first):"; echo "${logs:-(none in the last 2 hours)}"
for f in $logs; do
  echo; echo "=== $f ($(stat -c %s "$f") bytes)"
  echo "-- errors, fatal, RHI/D3D12 lines"
  grep -a -n -i -E "error|fatal|critical|LogD3D12|LogRHI|D3D12|DX12|shader model|feature level|LogWindows|crash|assert" "$f" | grep -v -i "errorcount=0" | head -80 | cut -c1-300
  echo "-- end"
  tail -n 40 "$f" | cut -c1-300
  break
done
echo; echo "== newest crash folder"
c=$(find "$P/AppData/Local" -maxdepth 4 -type d -path "*Saved/Crashes/*" -newermt "-2 hours" 2>/dev/null | xargs -r ls -td 2>/dev/null | head -1)
if [ -n "$c" ]; then
  ls -la "$c"
  for x in "$c"/*.runtime-xml "$c"/CrashContext*; do
    [ -f "$x" ] && grep -a -o -E "<(ErrorMessage|CrashType|CrashGUID|EngineVersion|GameName|Misc.CPUBrand|Misc.PrimaryGPUBrand|CallStack)>[^<]{0,600}" "$x" | head -12
  done
  [ -f "$c"/*.log ] 2>/dev/null; tail -n 30 "$c"/*.log 2>/dev/null | cut -c1-300
else
  echo "(none)"
fi
echo; echo "== Saved folders in the game's install dir (some games log there)"
find "$S/steamapps/common" -maxdepth 4 -type d -name Saved -newermt "-2 hours" 2>/dev/null | head
