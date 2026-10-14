#!/usr/bin/env bash
# Rebuild present-layer/i386/libVkLayer_bottle_present.so (and i386/vk-probe): the 32-bit x86 build of the layer, for 32-bit
# Windows games (Wine's 32-bit side loads 32-bit Vulkan layers; the x86_64 build can't). Same source as the other builds.
# Needs gcc -m32 and the 32-bit xcb libraries; on Ubuntu:
#   sudo dpkg --add-architecture i386 && sudo apt-get update
#   sudo apt-get install gcc-multilib libxcb1-dev:i386 libxcb-shm0-dev:i386 libvulkan-dev
# Run:  bash build-i386.sh      (rewrites i386/libVkLayer_bottle_present.so, i386/vk-probe and i386/BUILT)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="$HERE/i386"
mkdir -p "$O"
gcc -m32 -O2 -fPIC -shared -fvisibility=hidden -Wall -o "$O/libVkLayer_bottle_present.so" "$HERE/bottle_present.c" -lxcb -lxcb-shm -lpthread
gcc -m32 -O2 -Wall -o "$O/vk-probe" "$HERE/../tests/vk32-probe.c" -ldl
chmod 755 "$O/libVkLayer_bottle_present.so" "$O/vk-probe"
cat > "$O/BUILT" <<EOT
libVkLayer_bottle_present.so: built $(date -u +%Y-%m-%d) from ../bottle_present.c (sha1 first 16: $(sha1sum "$HERE/bottle_present.c" | cut -c1-16)) with build-i386.sh ($(gcc -dumpfullversion) -m32, $(. /etc/os-release; echo "$PRETTY_NAME")).
vk-probe: guest/tests/vk32-probe.c.
install-x86.sh warns when ../bottle_present.c no longer hashes to the line above.
EOT
sha256sum "$O"/libVkLayer_bottle_present.so "$O"/vk-probe
