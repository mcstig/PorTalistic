#!/usr/bin/env bash
# Install the x86_64 and i386 builds of VK_LAYER_BOTTLE_cpu_present into the x86 graphics rootfs
# that Steam's FEX (and so x86 Proton/Wine) uses, then probe the x86 Vulkan stack. 32-bit Windows
# games run on 32-bit Wine, which loads 32-bit layers only: without the i386 build they see the raw
# GPU (no stand-ins for the features DXVK insists on: vkCreateDevice fails; and no swapchain).
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

# The i386 build (32-bit games). Its own manifest and layer name: the loader keeps only one layer
# per name, and the x86_64 manifest (library under usr/lib64) can't load in a 32-bit process.
I386="$HERE/i386/libVkLayer_bottle_present.so"
if [[ -f "$I386" && -d "$R/usr/lib" ]]; then
  info "Installing the i386 layer (32-bit games)…"
  want="$(sed -n 's/.*(sha1 first 16: \([0-9a-f]*\)).*/\1/p' "$HERE/i386/BUILT" 2>/dev/null | head -1)"
  now="$(sha1sum "$HERE/bottle_present.c" 2>/dev/null | cut -c1-16)"
  [[ -z "$want" || "$want" == "$now" ]] \
    || echo "  warning: bottle_present.c has changed since the i386 build was made: run present-layer/build-i386.sh" >&2
  # Made aside, then swapped in: overwriting a loaded .so in place can crash apps using it.
  install -m 0755 "$I386" "$R/usr/lib/libVkLayer_bottle_present.so.new"
  mv -f "$R/usr/lib/libVkLayer_bottle_present.so.new" "$R/usr/lib/libVkLayer_bottle_present.so"
  sed -e "s#@LIBRARY_PATH@#/usr/lib/libVkLayer_bottle_present.so#" \
      -e 's#"name": "VK_LAYER_BOTTLE_cpu_present"#"name": "VK_LAYER_BOTTLE_cpu_present_i686"#' \
      "$HERE/VkLayer_bottle_present.json.in" > "$R/etc/vulkan/implicit_layer.d/VkLayer_bottle_present_i686.json"
  chmod 0644 "$R/etc/vulkan/implicit_layer.d/VkLayer_bottle_present_i686.json"
  [[ -f "$HERE/i386/vk-probe" ]] && install -m 0755 "$HERE/i386/vk-probe" /usr/local/bin/vk-probe-x86-32
  for so in libxcb.so.1 libxcb-shm.so.0 libvulkan.so.1; do
    compgen -G "$R/usr/lib/$so*" >/dev/null || echo "  rootfs (32-bit) is MISSING $so"
  done
else
  echo "  (no i386 build in this kit or no 32-bit side in the rootfs: 32-bit games won't work)"
fi

info "Probing the x86 Vulkan stack through FEX (thunks off, feature spoofing forced on)…"
nothunks="$(mktemp)"; echo '{"ThunksDB": {"Vulkan": 0, "GL": 0}}' > "$nothunks"; chmod 644 "$nothunks"
sudo -u "$USER_NAME" env DISPLAY=:1 FEX_ROOTFS="$R" FEX_THUNKCONFIG="$nothunks" BOTTLE_FAKE_FEATURES=1 \
  timeout 120 /usr/local/bin/vk-probe-x86 2>&1 | grep -vE 'card0|Asahi native|could not connect vdrm' || true
rm -f "$nothunks"
echo "(DXVK gets the spoofed features automatically; other apps see the real ones.)"
if [[ -x /usr/local/bin/vk-probe-x86-32 ]]; then
  info "Probing the 32-bit x86 Vulkan stack through FEX…"
  nothunks="$(mktemp)"; echo '{"ThunksDB": {"Vulkan": 0, "GL": 0}}' > "$nothunks"; chmod 644 "$nothunks"
  FEX_BIN="$(command -v FEXInterpreter || true)"
  sudo -u "$USER_NAME" env DISPLAY=:1 FEX_ROOTFS="$R" FEX_THUNKCONFIG="$nothunks" VK32_ENGINE=DXVK \
    timeout 120 ${FEX_BIN:+"$FEX_BIN"} /usr/local/bin/vk-probe-x86-32 2>&1 | grep -E 'PASS|FAIL|FAILED|Venus|reported core|managed' | cut -c1-200 || true
  rm -f "$nothunks"
fi
