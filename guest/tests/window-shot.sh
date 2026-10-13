#!/usr/bin/env bash
# (selftest: may run during a game)
# window-shot: a picture of one window's own contents (default: the game launcher's OpenGL
# window, REDlauncher), even while another window covers it, when X keeps its contents.
set -u
cd "$(dirname "$0")" || exit 1
name="${SHOT_NAME:-REDlauncher}"
tree="$(bash ./xwindows.sh 2>/dev/null)"
top="$(echo "$tree" | grep -m1 "'$name'" | awk '{print $1}')"
child="$(echo "$tree" | grep -A1 -m1 "'$name'" | tail -1 | awk '{print $1}')"
echo "== $name: window $top, child $child"
for w in $child $top; do
  [[ -n "$w" ]] || continue
  SHOT_WINDOW="$w" bash ./screenshot.sh
done
