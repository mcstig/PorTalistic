#!/usr/bin/env bash
# (selftest: may run during a game)
# gl-trace-on: turn on BOTTLE_OVERLAY_GL_TRACE=1 in steam.env (what Steam's overlay draws in
# OpenGL programs goes to the game's log, from Steam's next start); gl-trace-off undoes it.
# Also: where Steam's overlay UI reads the CPU's clock from (it shows 0.00 MHz here).
set -u
E=~/.config/steamos-bottle/steam.env
mkdir -p "${E%/*}"; touch "$E"
if [[ "$(basename "$0" .sh)" == gl-trace-off ]]; then
  sed -i '/^BOTTLE_OVERLAY_GL_TRACE=/d' "$E"; echo "off"
else
  grep -q '^BOTTLE_OVERLAY_GL_TRACE=1' "$E" || echo 'BOTTLE_OVERLAY_GL_TRACE=1   # (Claude, Oct 11: overlay in the Witcher launcher; remove when done)' >> "$E"
  echo "on (from Steam's next start)"
fi
grep -n "BOTTLE_OVERLAY_GL_TRACE" "$E" || true
S=~/.local/share/Steam/steamrtarm64
echo "== the CPU clock in gameoverlayui.so / steamclient.so"
for f in "$S/gameoverlayui.so" "$S/steamclient.so"; do
  echo "-- ${f##*/}"; grep -a -o -E "[[:print:]]{0,50}(cpufreq|scaling_cur_freq|cpuinfo_max_freq|cpuinfo_cur_freq|cpu MHz|BogoMIPS|MHz)[[:print:]]{0,50}" "$f" | sort -u | head -20
done
echo "== the VM"
ls /sys/devices/system/cpu/cpu0/ 2>&1 | tr '\n' ' '; echo; grep -m3 -i "mhz\|bogo" /proc/cpuinfo || echo "(no MHz in /proc/cpuinfo)"
echo "== the screen server (screen.log), the screen size, the Mac's GPU numbers"
tail -n 40 ~/.config/steamos-bottle/screen.log 2>/dev/null | cut -c1-200
echo "-- size kept: $(cat ~/.config/steamos-bottle/screen-size 2>/dev/null || echo none); now: $(DISPLAY=:1 bottle-resolution 2>&1)"
cat /dev/shm/steamos-bottle-host-stats 2>/dev/null; ls ~/.cache/steamos-bottle/notices 2>/dev/null
ls -la ~/.local/share/Steam/lib/aarch64-linux-gnu/libnvidia-ml.so.1 2>&1
