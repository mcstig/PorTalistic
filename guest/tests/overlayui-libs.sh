#!/usr/bin/env bash
# (selftest: may run during a game)
# overlayui-libs: which libraries the running Steam overlay UI (gameoverlayui) has loaded, and
# which ARM64 Steam libraries provide the VGUI surface (VGUI_Surface040) it draws through.
set -u
S=~/.local/share/Steam
for p in $(pgrep -f "steamrtarm64/gameoverlayui" | head -3); do
  echo "== pid $p: $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-200)"
  awk '{print $6}' /proc/$p/maps | grep "\.so" | sort -u
done
echo "== VGUI_Surface040 in"
grep -l -a "VGUI_Surface040" "$S"/steamrtarm64/*.so 2>/dev/null
