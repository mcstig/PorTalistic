#!/usr/bin/env bash
# (selftest: may run during a game)
# gl-trace-tail: the newest OpenGL trace lines (gl-trace-on) from the newest game log, to see
# what Steam's overlay draws now.
set -u
log=$(ls -t ~/steam-*.log 2>/dev/null | head -1)
echo "== ${log:-(no game log)}"
[ -n "$log" ] && grep -a "bottle-gltrace" "$log" | tail -n 3000
