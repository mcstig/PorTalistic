#!/usr/bin/env bash
# (selftest: may run during a game)
# perf-settings: Steam's performance monitor settings as saved in each user's localconfig.vdf,
# with the blocks they sit in (to change them while Steam is stopped).
set -u
for c in ~/.local/share/Steam/userdata/*/config/localconfig.vdf; do
  [[ -f "$c" ]] || continue
  echo "== $c"
  python3 - "$c" <<'PY'
import sys
stack = []
prev = ""
for n, line in enumerate(open(sys.argv[1], encoding="utf-8", errors="replace"), 1):
    s = line.strip()
    if s == "{":
        stack.append(prev.strip('"'))
    elif s == "}":
        stack and stack.pop()
    elif "InGameOverlay" in s:
        print(f"{n}: {' > '.join(stack)}: {s}")
    prev = s
PY
done
