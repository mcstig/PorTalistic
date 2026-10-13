#!/usr/bin/env bash
# (selftest: may run during a game)
# perfmon-layout: the files that lay out Steam's in-game performance monitor (VGUI layouts
# ingamefpsbanner/ingamegamefps/ingamepresentationfps, and the scheme values FPSGraph.*,
# CPUCoreGraph.*, PerfText*), as the ARM64 client has them.
set -u
S=~/.local/share/Steam
echo "== layout files"
for f in "$S"/resource/layout/ingame*.layout; do
  [[ -f "$f" ]] || continue
  echo "-- ${f#"$S"/} ($(stat -c %s "$f") bytes)"; cat "$f"; echo
done
echo "== gameoverlay.styles"
cat "$S"/resource/styles/gameoverlay.styles 2>/dev/null | head -300
echo "== scheme values"
grep -r -a -n -E "FPSGraph|CPUCoreGraph|PerfText|IngameFPS|GameFPS|PerfHighContrast|PerfLabel" "$S/resource" "$S/public" 2>/dev/null | grep -v "\.layout:" | cut -c1-220 | head -80
echo "== which resource folders exist"
ls -d "$S"/resource "$S"/resource/layout "$S"/resource/styles "$S"/public 2>&1
ls "$S"/resource/layout 2>/dev/null | head -50 | tr '\n' ' '; echo
ls "$S"/resource/styles 2>/dev/null | head -50 | tr '\n' ' '; echo
