#!/usr/bin/env bash
# Install the x86_64 build of VK_LAYER_BOTTLE_cpu_present into the x86 graphics rootfs
# that Steam's FEX (and so x86 Proton/Wine) uses, then probe the x86 Vulkan stack.
# Run as root (sudo) from the normal user: sudo bash install-x86.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="${GUEST_ROOTFS:-/usr/share/guestos/fex-mesa}"
USER_NAME="${SUDO_USER:-$(id -un)}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -d "$R/usr/lib64" ]] || die "No x86 rootfs at $R (see setup-guest.sh, 'guestos/fex-mesa')."

info "x86 graphics stack in $R:"
rpm --root "$R" -q mesa-vulkan-drivers mesa-dri-drivers vulkan-loader libxcb 2>&1 | sed 's/^/  /' || true
for f in "$R"/usr/share/vulkan/icd.d/*.json; do [[ -e "$f" ]] && echo "  icd: ${f##*/}"; done

info "Installing the x86_64 layer…"
install -m 0755 "$HERE/x86_64/libVkLayer_bottle_present.so" "$R/usr/lib64/libVkLayer_bottle_present.so"
# The manifest must live under the rootfs's /etc: FEX overlays the host's /etc/vulkan, so a
# manifest anywhere else is shadowed by the arm64 one (which points at an arm64 library).
install -d "$R/etc/vulkan/implicit_layer.d"
sed "s#@LIBRARY_PATH@#/usr/lib64/libVkLayer_bottle_present.so#" "$HERE/VkLayer_bottle_present.json.in" \
  > "$R/etc/vulkan/implicit_layer.d/VkLayer_bottle_present.json"
rm -f "$R/usr/share/vulkan/implicit_layer.d/VkLayer_bottle_present.json"
install -m 0755 "$HERE/x86_64/vk-probe" /usr/local/bin/vk-probe-x86
for so in libxcb.so.1 libxcb-shm.so.0 libvulkan.so.1; do
  if compgen -G "$R/usr/lib64/$so*" >/dev/null; then echo "  rootfs has $so"; else echo "  rootfs is MISSING $so"; fi
done

info "Probing the x86 Vulkan stack through FEX (thunks off, feature spoofing forced on)…"
nothunks="$(mktemp)"; echo '{"ThunksDB": {"Vulkan": 0, "GL": 0}}' > "$nothunks"; chmod 644 "$nothunks"
sudo -u "$USER_NAME" env DISPLAY=:1 FEX_ROOTFS="$R" FEX_THUNKCONFIG="$nothunks" BOTTLE_FAKE_FEATURES=1 \
  timeout 120 /usr/local/bin/vk-probe-x86 2>&1 | grep -vE 'card0|Asahi native|could not connect vdrm' || true
rm -f "$nothunks"
echo "(DXVK gets the spoofed features automatically; other apps see the real ones.)"
