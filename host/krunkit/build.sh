#!/bin/bash
# krunkit 1.3.2 with one patch (krunkit-datadisk-id.patch): a block id of its own for each Lima disk
# (Lima names every additional disk's file "datadisk"; libkrun keeps one device per id, so only one
# game drive reached the VM). Builds host/krunkit/krunkit on the development Mac: Homebrew's rust
# (installed if missing) and libkrun. package-app.sh takes this build when it's here and newer
# than the patch, else Homebrew's krunkit.
set -euo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v cargo >/dev/null || brew install rust
BREW="$(brew --prefix)"
W="$HOME/Library/Caches/Portalistic/krunkit-build"
rm -rf "$W"; mkdir -p "$W"
curl -fsSL -o "$W/src.tar.gz" https://github.com/containers/krunkit/archive/refs/tags/v1.3.2.tar.gz
tar -xzf "$W/src.tar.gz" -C "$W"
cd "$W/krunkit-1.3.2"
patch -p1 < "$HERE/krunkit-datadisk-id.patch"
PREFIX="$BREW" cargo build --release
install_name_tool -change libkrun.1.dylib "$BREW/lib/libkrun.1.dylib" -add_rpath "$BREW/lib" target/release/krunkit 2>/dev/null || true
codesign --entitlements krunkit.entitlements --force -s - target/release/krunkit
cp target/release/krunkit "$HERE/krunkit.new" && mv -f "$HERE/krunkit.new" "$HERE/krunkit"
# krunkit looks for its EFI firmware at ../share/krunkit from its own folder: Homebrew's, linked
mkdir -p "$HERE/../share" && ln -sfn "$BREW/share/krunkit" "$HERE/../share/krunkit"
echo "krunkit 1.3.2 + datadisk-id patch, $(date -Iseconds), libkrun $(brew list --versions libkrun)" > "$HERE/BUILT"
otool -L "$HERE/krunkit" | grep -i krun
echo "built: $HERE/krunkit"
