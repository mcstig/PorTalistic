#!/usr/bin/env bash
# fex-info: how x86 games are run here: Steam's FEX (the FEX-Emu compat tool) and the VM's own,
# their settings, and what the emulated x86 CPU looks like to a game (/proc/cpuinfo through FEX).
set -u
S=~/.local/share/Steam
T="$S/steamapps/common/FEX-Emu"
echo "== $(date)"
echo "== Steam's FEX compat tool: $T"
for f in VERSIONS.txt toolmanifest.vdf emulator.json ConfigTemplate.json; do
  [[ -f "$T/$f" ]] && { echo "-- $f"; head -c 3000 "$T/$f"; echo; }
done
ls -la "$T/usr/bin" 2>/dev/null | head -30
echo "== the VM's FEX"
command -v FEXInterpreter FEXBash FEXGetConfig FEXConfig 2>&1
FEXInterpreter --version 2>&1 | head -3
echo "== FEX settings files"
for f in ~/.fex-emu/Config.json ~/.fex-emu/AppConfig/*.json /usr/share/fex-emu/Config.json /usr/share/fex-emu/AppConfig/*.json; do
  [[ -f "$f" ]] && { echo "-- $f"; head -c 2000 "$f"; echo; }
done
echo "== FEX's option list (FEXInterpreter --help)"
FEXInterpreter --help 2>&1 | head -120
echo "== the x86 CPU a game sees (FEX's /proc/cpuinfo, first CPU)"
for fexi in "$T/usr/bin/FEXInterpreter" "$(command -v FEXInterpreter)"; do
  [[ -x "$fexi" ]] || continue
  echo "-- through $fexi"
  timeout 30 "$fexi" /usr/bin/cat /proc/cpuinfo 2>&1 | awk '/^$/{exit} {print}' | cut -c1-600
done
