#!/usr/bin/env bash
# Swap the bottle's Mac-side Vulkan driver from MoltenVK to KosmicKrisp (and back).
#
# krunkit's virglrenderer is linked straight to libMoltenVK.dylib. "enable" relinks it
# to the standard Vulkan loader (Homebrew vulkan-loader), so the driver can be chosen
# with VK_DRIVER_FILES, and starts the VM with KosmicKrisp selected.
#
# Usage:  ./host/kosmickrisp.sh status | enable | disable | restart
# Env:    VM_NAME (default steamos-bottle)
set -euo pipefail

VM_NAME="${VM_NAME:-steamos-bottle}"
STATE_DIR="$HOME/.config/steamos-bottle"
ICD_FILE="$STATE_DIR/kosmickrisp_icd"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd "$HOME"
command -v brew >/dev/null || die "Homebrew not found."
VR="$(brew --prefix virglrenderer-krun)/lib/libvirglrenderer.1.dylib"
[[ -f "$VR" ]] || die "Can't find $VR (is krunkit installed?)"
VR_REAL="$(cd "$(dirname "$VR")" && pwd -P)/$(basename "$VR")"
BACKUP="$VR_REAL.moltenvk-backup"

linked_vulkan() { otool -L "$VR_REAL" | awk 'NR>1 && /MoltenVK|libvulkan/ {print $1}'; }

find_icd() {
  local c
  for c in "$HOME"/VulkanSDK/*/macOS/share/vulkan/icd.d/*kosmickrisp*.json \
           /usr/local/share/vulkan/icd.d/libkosmickrisp_icd.json \
           /opt/homebrew/share/vulkan/icd.d/*kosmickrisp*.json \
           "$HOME"/mesa-native/share/vulkan/icd.d/kosmickrisp*.json; do
    [[ -f "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

install_sdk() {
  # The LunarG Vulkan SDK ships KosmicKrisp as an optional component (com.lunarg.vulkan.kosmic).
  local zip app bin ver tmp
  zip="$(ls -t "$HOME"/Downloads/vulkansdk-macos-*.zip 2>/dev/null | head -1 || true)"
  if [[ -z "$zip" ]]; then
    info "Downloading the latest LunarG Vulkan SDK for macOS…"
    zip="$HOME/Downloads/vulkansdk-macos-latest.zip"
    curl -fL --progress-bar -o "$zip" "https://sdk.lunarg.com/sdk/download/latest/mac/vulkan_sdk.zip" \
      && unzip -tq "$zip" >/dev/null 2>&1 \
      || { rm -f "$zip"; die "Automatic download failed. Download the macOS SDK (.zip) from https://vulkan.lunarg.com/sdk/home into Downloads, then run this again."; }
  fi
  tmp="$(mktemp -d)"
  info "Unpacking $(basename "$zip")…"
  unzip -q "$zip" -d "$tmp"
  app="$(find "$tmp" -maxdepth 2 -name 'vulkansdk-macOS-*.app' -type d | head -1)"
  [[ -n "$app" ]] || die "No installer app found inside $zip"
  bin="$app/Contents/MacOS/$(basename "$app" .app)"
  ver="$(basename "$app" .app | sed 's/^vulkansdk-macOS-//')"
  # Component IDs change between SDK releases: ask the installer which exist.
  info "Asking the installer which components SDK $ver offers (asks for your Mac password)…"
  local listing ids kos
  listing="$(sudo "$bin" search 2>&1 || true)"
  ids="$(printf '%s\n' "$listing" | grep -o 'name="[^"]*"' | cut -d'"' -f2 | sort -u)"
  echo "  available: $(echo "$ids" | tr '\n' ' ')"
  kos="$(printf '%s\n' "$ids" | grep -iE 'kosmic|krisp' | tr '\n' ' ' || true)"
  [[ -n "$kos" ]] && info "KosmicKrisp component(s): $kos" \
                  || warn "No separate KosmicKrisp component listed; installing the core SDK and checking whether it's included."

  # A failed earlier attempt can leave an empty target folder the installer refuses.
  if [[ -d "$HOME/VulkanSDK/$ver" && ! -e "$HOME/VulkanSDK/$ver/maintenancetool.app" ]]; then
    sudo rm -rf "$HOME/VulkanSDK/$ver"
  fi
  info "Installing Vulkan SDK $ver to ~/VulkanSDK/${ver}…"
  # shellcheck disable=SC2086 # $kos is a space-separated list of component IDs
  if ! sudo "$bin" --root "$HOME/VulkanSDK/$ver" --accept-licenses --default-answer \
       --confirm-command install com.lunarg.vulkan.core $kos; then
    warn "The SDK installer reported an error (output above)."
  fi
  sudo chown -R "$(id -un)" "$HOME/VulkanSDK/$ver" 2>/dev/null || true
  rm -rf "$tmp"
}

krunkit_env_has() {
  local pid
  pid="$(pgrep -n krunkit || true)"
  [[ -n "$pid" ]] && ps -Eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -q "^$1="
}

restart_vm() {
  local icd="${1:-}"
  info "Restarting ${VM_NAME}…"
  limactl stop "$VM_NAME" >/dev/null 2>&1 || true
  if [[ -n "$icd" ]]; then
    VK_DRIVER_FILES="$icd" VK_ICD_FILENAMES="$icd" limactl start "$VM_NAME"
    if krunkit_env_has VK_DRIVER_FILES; then
      info "krunkit is running with VK_DRIVER_FILES=$icd"
    else
      warn "Couldn't confirm that krunkit received VK_DRIVER_FILES (Lima may not pass it through)."
    fi
  else
    limactl start "$VM_NAME"
  fi
}

guest_report() {
  info "What the VM sees now:"
  limactl shell "$VM_NAME" sh -c '
    icd=$(ls /usr/share/vulkan/icd.d/virtio_icd*.json | head -1)
    VK_DRIVER_FILES=$icd vulkaninfo --summary 2>/dev/null | grep -E "apiVersion|deviceName|driverName" | head -4
    VK_DRIVER_FILES=$icd vulkaninfo 2>/dev/null | grep -E "^\s+(geometryShader|nullDescriptor|robustBufferAccess2|transformFeedback|shaderFloat64|synchronization2)\s+=" | sort -u
    VK_DRIVER_FILES=$icd vulkaninfo 2>/dev/null | grep -qw VK_KHR_synchronization2 && echo "ext VK_KHR_synchronization2: yes" || echo "ext VK_KHR_synchronization2: no"'
}

case "${1:-status}" in
  status)
    info "virglrenderer: $VR_REAL"
    echo "  linked against: $(linked_vulkan | tr '\n' ' ')"
    [[ -f "$BACKUP" ]] && echo "  MoltenVK backup: $BACKUP"
    echo "  MoltenVK-specific imports: $(nm -u "$VR_REAL" 2>/dev/null | grep -cE '_vk[A-Za-z0-9]*MVK|MoltenVK' || true)"
    echo "  KosmicKrisp ICD: $(find_icd || echo 'not installed')"
    echo "  vulkan-loader: $(brew list --versions vulkan-loader 2>/dev/null || echo 'not installed')"
    echo "  krunkit has VK_DRIVER_FILES: $(krunkit_env_has VK_DRIVER_FILES && echo yes || echo no)"
    ;;

  enable)
    [[ "$(uname -m)" == arm64 ]] || die "KosmicKrisp needs Apple Silicon."
    (( $(sw_vers -productVersion | cut -d. -f1) >= 26 )) || die "KosmicKrisp needs macOS 26 or newer."

    mvk_syms="$(nm -u "$VR_REAL" 2>/dev/null | grep -E '_vk[A-Za-z0-9]*MVK|MoltenVK' || true)"
    if [[ -n "$mvk_syms" ]]; then
      echo "$mvk_syms" | head
      die "virglrenderer calls MoltenVK-only functions, so it can't be pointed at the loader. It needs a rebuild instead; send this output to Claude."
    fi

    icd="$(find_icd || true)"
    if [[ -z "$icd" ]]; then install_sdk; icd="$(find_icd || true)"; fi
    [[ -n "$icd" ]] || die "KosmicKrisp didn't install. Run the SDK installer by hand and tick 'KosmicKrisp', then run this again."
    info "KosmicKrisp ICD: $icd"

    info "Installing the Vulkan loader…"
    brew list vulkan-loader >/dev/null 2>&1 || brew install vulkan-loader
    loader="$(brew --prefix vulkan-loader)/lib/libvulkan.1.dylib"
    [[ -f "$loader" ]] || die "Missing $loader"

    current="$(linked_vulkan | head -1)"
    if [[ "$current" == *MoltenVK* ]]; then
      [[ -f "$BACKUP" ]] || cp -p "$VR_REAL" "$BACKUP"
      info "Relinking virglrenderer: $current -> $loader"
      chmod u+w "$VR_REAL"
      install_name_tool -change "$current" "$loader" "$VR_REAL"
      codesign --force --sign - "$VR_REAL"
    else
      info "virglrenderer already uses the loader ($current)."
    fi

    mkdir -p "$STATE_DIR"
    echo "$icd" > "$ICD_FILE"
    restart_vm "$icd"
    guest_report
    echo
    echo "To go back to MoltenVK: ./host/kosmickrisp.sh disable"
    ;;

  restart)
    [[ -f "$ICD_FILE" ]] || die "Not enabled yet. Run: ./host/kosmickrisp.sh enable"
    restart_vm "$(cat "$ICD_FILE")"
    guest_report
    ;;

  disable)
    if [[ -f "$BACKUP" ]]; then
      info "Restoring the MoltenVK-linked virglrenderer…"
      cp -p "$BACKUP" "$VR_REAL"
      codesign --force --sign - "$VR_REAL"
    fi
    rm -f "$ICD_FILE"
    restart_vm ""
    guest_report
    ;;

  *) die "usage: $0 status | enable | disable | restart" ;;
esac
