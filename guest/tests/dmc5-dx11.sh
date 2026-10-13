#!/usr/bin/env bash
# dmc5-dx11: switch Devil May Cry 5 back to DirectX 11 (TargetPlatform=DirectX11).
set -u
g="$(ls -d ~/.local/share/Steam/steamapps/common/Devil\ May\ Cry\ 5 2>/dev/null)"
[[ -n "$g" ]] || { echo "Devil May Cry 5 isn't installed"; exit 1; }
f="$g/dmc5config.ini"
[[ -f "$f" ]] || { echo "no dmc5config.ini"; exit 1; }
echo "== before: $(grep -i '^TargetPlatform' "$f" | tr -d '\r')"
sed -i "s/^\(TargetPlatform=\)[A-Za-z0-9]*/\1DirectX11/I" "$f"
echo "== after:  $(grep -i '^TargetPlatform' "$f" | tr -d '\r')"
