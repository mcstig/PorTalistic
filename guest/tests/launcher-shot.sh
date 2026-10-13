#!/usr/bin/env bash
# (selftest: may run during a game)
# launcher-shot: waits up to 35 minutes for a game launcher's window (REDprelauncher: The
# Witcher 3's), then records the window tree and a screenshot of the VM's screen 6 s later
# (what Steam's overlay draws over it), and 20 s after that the OpenGL trace lines from the
# game's log (gl-trace-on).
set -u
cd "$(dirname "$0")" || exit 1
for _ in $(seq 1 420); do
  if bash ./xwindows.sh 2>/dev/null | grep -qi "redprelaunch\|REDlauncher"; then
    sleep 6
    bash ./xwindows.sh 2>/dev/null | grep -i -B1 -A3 "redprelaunch\|REDlauncher\|Witcher"
    bash ./screenshot.sh
    sleep 20
    log=$(ls -t ~/steam-*.log 2>/dev/null | head -1)
    echo "== OpenGL trace lines in ${log:-(no game log)}"
    [ -n "$log" ] && grep -a "bottle-gltrace" "$log" | head -400
    exit 0
  fi
  sleep 5
done
echo "no launcher window within 35 minutes"
