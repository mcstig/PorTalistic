#!/usr/bin/env bash
# (selftest: may run during a game)
# overlayui-dump: the ARM64 Steam overlay UI library (steamrtarm64/gameoverlayui.so: it lays out
# and draws the performance monitor) gzipped as base64 between markers, plus Steam's overlay and
# performance-monitor settings, to study how the monitor is laid out.
set -u
S=~/.local/share/Steam
f="$S/steamrtarm64/gameoverlayui.so"
ls -l "$f"; md5sum "$f"
echo "==B64-BEGIN== gameoverlayui.so.gz"; gzip -c "$f" | base64 -w0; echo; echo "==B64-END=="
echo "== perf overlay settings (registry.vdf, localconfig.vdf, config.vdf)"
for c in ~/.steam/registry.vdf "$S"/config/config.vdf "$S"/userdata/*/config/localconfig.vdf; do
  [[ -f "$c" ]] && { echo "-- $c"; grep -a -i -E "perf|fps|overlay" "$c" | head -40; }
done
