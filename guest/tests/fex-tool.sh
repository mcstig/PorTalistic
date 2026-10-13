#!/usr/bin/env bash
# fex-tool: Steam's FEX compat tool scripts and where it keeps its settings (for per-game FEX
# settings such as x87 precision).
set -u
T=~/.local/share/Steam/steamapps/common/FEX-Emu
for f in fex-compat-tool FEXCompatTool unshare.py; do
  echo "== $f ($(file -b "$T/$f" 2>/dev/null | cut -c1-60))"
  file -b "$T/$f" 2>/dev/null | grep -q text && cat "$T/$f" | head -250
done
echo "== config folders a running game's FEX may use"
ls -la "$T"/fex-emu "$T"/usr/share/fex-emu 2>&1 | head -30
find "$T" -maxdepth 4 -iname "*.json" 2>/dev/null | head -30
find ~/.fex-emu /tmp /run/user/$(id -u) -maxdepth 3 -iname "*fex*" 2>/dev/null | head -20
echo "== FEXGetConfig"
"$T/usr/bin/FEXGetConfig" --help 2>&1 | head -40
FEX_PORTABLE=1 "$T/usr/bin/FEXGetConfig" --current-rootfs 2>&1 | head -3
