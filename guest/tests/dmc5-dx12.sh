#!/usr/bin/env bash
# dmc5-dx12: switch Devil May Cry 5 to DirectX 12 (TargetPlatform=DirectX12 in dmc5config.ini),
# to try the bottle's DirectX 12 path with a real game. The file before the change is kept as
# dmc5config.ini.bottle-dx11; the dmc5-dx11 test switches back.
set -u
g="$(ls -d ~/.local/share/Steam/steamapps/common/Devil\ May\ Cry\ 5 2>/dev/null)"
[[ -n "$g" ]] || { echo "Devil May Cry 5 isn't installed"; exit 1; }
f="$g/dmc5config.ini"
[[ -f "$f" ]] || { echo "no dmc5config.ini yet (start the game once)"; exit 1; }
echo "== before: $(grep -i '^TargetPlatform' "$f" | tr -d '\r')"
[[ -f "$f.bottle-dx11" ]] || cp -p "$f" "$f.bottle-dx11"
sed -i "s/^\(TargetPlatform=\)[A-Za-z0-9]*/\1DirectX12/I" "$f"
echo "== after:  $(grep -i '^TargetPlatform' "$f" | tr -d '\r')"
