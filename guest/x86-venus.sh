#!/usr/bin/env bash
# Give the x86 side (Proton/Wine under FEX) a GPU Vulkan driver that works on a Mac host.
#
# Stock Fedora Mesa's Venus driver doesn't work under krunkit: buffers must be 16K-aligned
# for the macOS host, and newer Mesa hides Venus devices that lack dma-buf. That's why the
# arm64 side uses the slp/mesa-libkrun-vulkan COPR. The x86 rootfs Steam's FEX uses
# (/usr/share/guestos/fex-mesa) still has stock Mesa, so x86 vkCreateInstance fails (-1).
#
# 64-bit: copies the COPR's x86_64 Venus driver into that rootfs (stock copy kept as .stock).
# 32-bit (Oct 14): 32-bit Windows games load the 32-bit driver (usr/lib), the COPR has no i686
# build and the stock one dies with "mmap failed ... Invalid argument" on the first buffer.
# x86-venus/ in this kit has the same Mesa 25.3.6 + the same Mac patches built for 32-bit
# (x86-venus/build-i686.sh rebuilds it); installed the same way (stock copy kept as .stock).
#
# Run from the normal user:  sudo bash x86-venus.sh
# Env: X86_VENUS_FORCE=1 reinstall even if done; BOTTLE_SKIP_PROBE=1 skip the GPU probe.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="${GUEST_ROOTFS:-/usr/share/guestos/fex-mesa}"
USER_NAME="${SUDO_USER:-$(id -un)}"
RPM_URL="${RPM_URL:-https://download.copr.fedorainfracloud.org/results/slp/mesa-libkrun-vulkan/fedora-44-x86_64/10236391-mesa/mesa-vulkan-drivers-25.3.6-102.fc44.x86_64.rpm}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
TMPS=()
cleanup() { local d; for d in "${TMPS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -d "$R/usr/lib64" ]] || die "No x86 rootfs at $R (see setup-guest.sh)."

install64() {
  local lib="$R/usr/lib64/libvulkan_virtio.so"
  local icd="$R/usr/share/vulkan/icd.d/virtio_icd.x86_64.json"
  if [[ -f "$lib.stock" && -f "$lib" && -z "${X86_VENUS_FORCE:-}" ]] && ! cmp -s "$lib" "$lib.stock"; then
    info "The Mac-patched x86_64 Venus driver is already installed (X86_VENUS_FORCE=1 to redo)."
    return 0
  fi

  local tmp rpm repo
  tmp="$(mktemp -d)"; TMPS+=("$tmp")
  command -v cpio >/dev/null || dnf install -y -q cpio

  info "Downloading the COPR's x86_64 Mesa Vulkan drivers…"
  repo="$(dnf repolist --all 2>/dev/null | awk '/mesa-libkrun-vulkan/ {print $1; exit}' || true)"
  if [[ -n "$repo" ]] && dnf -q --forcearch=x86_64 --repo="$repo" download --destdir="$tmp" mesa-vulkan-drivers >/dev/null 2>&1 \
     && compgen -G "$tmp/mesa-vulkan-drivers-*.rpm" >/dev/null; then
    :
  else
    curl -fsSL -o "$tmp/mesa-vulkan-drivers.x86_64.rpm" "$RPM_URL" || die "Download failed: $RPM_URL"
  fi
  rpm="$(ls "$tmp"/mesa-vulkan-drivers*.rpm | head -1)"
  echo "  $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$rpm" 2>/dev/null)"
  ( cd "$tmp" && rpm2cpio "$rpm" | cpio -idm --quiet '*libvulkan_virtio.so' '*virtio_icd.x86_64.json' )
  [[ -f "$tmp/usr/lib64/libvulkan_virtio.so" ]] || die "The package has no libvulkan_virtio.so"

  info "Installing it into ${R}…"
  [[ -f "$lib" && ! -f "$lib.stock" ]] && cp -p "$lib" "$lib.stock"
  [[ -f "$icd" && ! -f "$icd.stock" ]] && cp -p "$icd" "$icd.stock"
  install -D -m 0755 "$tmp/usr/lib64/libvulkan_virtio.so" "$lib.new" && mv -f "$lib.new" "$lib"
  install -D -m 0644 "$tmp/usr/share/vulkan/icd.d/virtio_icd.x86_64.json" "$icd"
  for so in $(readelf -d "$lib" | awk '/NEEDED/ {gsub(/[][]/, "", $NF); print $NF}'); do
    compgen -G "$R/usr/lib64/$so" >/dev/null || echo "  MISSING in rootfs: $so"
  done
}

# 32-bit games: the same driver for the rootfs's 32-bit side, from the kit (x86-venus/).
install32() {
  local src="$HERE/x86-venus/libvulkan_virtio.i686.so"
  local lib="$R/usr/lib/libvulkan_virtio.so"
  local icd="$R/usr/share/vulkan/icd.d/virtio_icd.i686.json"
  local want have
  if [[ ! -d "$R/usr/lib" || ! -f "$icd" ]]; then
    echo "  no 32-bit side in the x86 rootfs: 32-bit games won't have a GPU driver"; return 0
  fi
  [[ -f "$src" ]] || { warn "x86-venus/libvulkan_virtio.i686.so is missing from this kit: 32-bit games won't work"; return 0; }
  want="$(awk '$1 == "libvulkan_virtio.i686.so" {print $2}' "$HERE/x86-venus/MANIFEST" 2>/dev/null)"
  have="$(sha256sum "$src" | cut -d' ' -f1)"
  [[ -n "$want" && "$want" == "$have" ]] || { warn "x86-venus/libvulkan_virtio.i686.so doesn't match its MANIFEST: not installing it"; return 0; }

  if [[ -f "$lib" && "$(sha256sum "$lib" | cut -d' ' -f1)" == "$have" && -z "${X86_VENUS_FORCE:-}" ]]; then
    info "The Mac-patched 32-bit Venus driver is already installed."
  else
    info "Installing the Mac-patched 32-bit Venus driver into ${R}…"
    [[ -f "$lib" && ! -f "$lib.stock" ]] && cp -p "$lib" "$lib.stock"
    install -D -m 0755 "$src" "$lib.new" && mv -f "$lib.new" "$lib"
  fi
  # The driver is Mesa 25.3.6 (Vulkan 1.4.328): the manifest must not promise more than that.
  [[ -f "$icd.stock" ]] || cp -p "$icd" "$icd.stock"
  sed -i 's/"api_version": *"[0-9.]*"/"api_version": "1.4.328"/' "$icd"
  for so in $(readelf -d "$lib" | awk '/NEEDED/ {gsub(/[][]/, "", $NF); print $NF}'); do
    compgen -G "$R/usr/lib/$so" >/dev/null || echo "  MISSING in the rootfs (32-bit): $so"
  done
}

install64
install32

[[ -n "${BOTTLE_SKIP_PROBE:-}" ]] && exit 0
info "Probing x86 Vulkan through FEX (thunks off)…"
tmp="$(mktemp -d)"; TMPS+=("$tmp")
nothunks="$tmp/nothunks.json"
echo '{"ThunksDB": {"Vulkan": 0, "GL": 0}}' > "$nothunks"; chmod 644 "$nothunks"; chmod 755 "$tmp"
sudo -u "$USER_NAME" env DISPLAY=:1 FEX_ROOTFS="$R" FEX_THUNKCONFIG="$nothunks" \
  timeout 120 /usr/local/bin/vk-probe-x86 2>&1 | grep -vE 'card0|Asahi native' | tail -8 || true

echo
echo "Undo: sudo mv $R/usr/lib64/libvulkan_virtio.so.stock $R/usr/lib64/libvulkan_virtio.so  (and the same for usr/lib, and the .json.stock files)"
