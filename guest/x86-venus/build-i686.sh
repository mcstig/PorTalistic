#!/usr/bin/env bash
# Rebuild libvulkan_virtio.i686.so: Mesa's Venus driver as a 32-bit x86 library, with the same three
# Mac patches the slp/mesa-libkrun-vulkan COPR puts on its x86_64 and aarch64 builds (patches/).
#
# Why: 32-bit Windows games (Blades of Time, ...) run on 32-bit Wine, which loads the *32-bit* Vulkan
# driver from the x86 system (/usr/share/guestos/fex-mesa/usr/lib). The COPR has no 32-bit build and
# Fedora's stock 32-bit Mesa fails on a Mac host ("mmap failed ... Invalid argument", then the game
# aborts), because buffers must be 16K-aligned there.
#
# Run on any x86_64 Linux with multilib (Ubuntu 24.04 was used; the package list is approximate):
#   sudo dpkg --add-architecture i386 && sudo apt-get update
#   sudo apt-get install gcc-multilib g++-multilib ninja-build pkg-config bison flex python3-mako python3-pip \
#        python3-yaml python3-packaging libz-dev:i386 libzstd-dev:i386 libdrm-dev:i386 libexpat1-dev:i386 \
#        libxcb1-dev:i386 libx11-xcb-dev:i386 libxcb-dri3-dev:i386 libxcb-present-dev:i386 libxcb-xfixes0-dev:i386 \
#        libxcb-sync-dev:i386 libxcb-randr0-dev:i386 libxcb-shm0-dev:i386 libxshmfence-dev:i386 \
#        libxcb-glx0-dev:i386 libx11-dev:i386 libvulkan-dev
#   pip install 'meson>=1.4'            # Mesa 25.3 needs meson 1.4 or newer
#   bash build-i686.sh [OUTFILE]        # default: ./libvulkan_virtio.i686.so
# Afterwards: update MANIFEST (sha256) and BUILT.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(realpath -m "${1:-libvulkan_virtio.i686.so}")"
VER=25.3.6
SHA256=59217efeac3b64e7ced958324b9db7494f1e0741aeb22d780276514cc1b8f206   # mesa-25.3.6.tar.xz
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

cd "$W"
curl -fsSL -o mesa.tar.xz "https://archive.mesa3d.org/mesa-$VER.tar.xz"
echo "$SHA256  mesa.tar.xz" | sha256sum -c -
tar -xf mesa.tar.xz
cd "mesa-$VER"
# the COPR's order (its spec: Patch20, Patch21, Patch22)
for p in 0001-virtio-vulkan-force-16k-alignment-for-allocations-HA 0002-virtio-vulkan-silence-stuck-in-wait-message-HACK \
         0001-Revert-venus-filter-out-venus-incapable-physical-dev; do
  patch -p1 < "$HERE/patches/$p.patch"
done

cat > "$W/native32.ini" <<'EONATIVE'
[binaries]
c = ['gcc', '-m32']
cpp = ['g++', '-m32']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
EONATIVE
export PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig:/usr/share/pkgconfig
meson setup build32 --native-file "$W/native32.ini" \
  -Dbuildtype=release -Dvulkan-drivers=virtio -Dgallium-drivers= -Dplatforms=x11 \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dgles1=disabled -Dgles2=disabled -Dopengl=false \
  -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
  -Dvulkan-layers= -Dbuild-tests=false -Dwerror=false -Dtools=
ninja -C build32 src/virtio/vulkan/libvulkan_virtio.so
cp build32/src/virtio/vulkan/libvulkan_virtio.so "$OUT"
strip -s "$OUT"
file "$OUT"
sha256sum "$OUT"
