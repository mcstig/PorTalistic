#!/usr/bin/env bash
# Build the VM's own programs once, for the kit's guest/prebuilt/aarch64 (see build-recipes.sh):
# update-guest.sh then installs these instead of compiling, so VMs need no build tools. Run on a
# development VM as root:  sudo bash prebuild.sh OUTDIR [NAME...]   (bottle prebuild on the Mac does
# it; with names, only those programs).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PB_SRC="$HERE"
# shellcheck source=build-recipes.sh
. "$HERE/build-recipes.sh"
OUT="${1:?usage: prebuild.sh OUTDIR [NAME...]}"
shift
NAMES="${*:-$PB_NAMES}"

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
[[ "$(uname -m)" == aarch64 ]] || { echo "build on the (aarch64) VM" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
: > "$OUT/MANIFEST"
for n in $NAMES; do
  for p in $(pb_devel "$n"); do
    rpm -q "$p" >/dev/null 2>&1 || dnf install -y -q "$p" >/dev/null
  done
  pb_build "$n" "$OUT/$n"
  strip --strip-unneeded "$OUT/$n" 2>/dev/null || true
  echo "$n $(pb_hash "$n")" >> "$OUT/MANIFEST"
  printf '  %-30s %s\n' "$n" "$(stat -c %s "$OUT/$n") bytes"
done
# shellcheck disable=SC1091
echo "built on $(. /etc/os-release; echo "$PRETTY_NAME"), kernel $(uname -r), gcc $(gcc -dumpversion), $(date -u +%Y-%m-%dT%H:%MZ)" > "$OUT/BUILT"
chmod 0644 "$OUT"/*
for n in bottle-screen bottle-gltest; do [[ -f "$OUT/$n" ]] && chmod 0755 "$OUT/$n"; done
cat "$OUT/BUILT"
