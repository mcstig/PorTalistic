#!/usr/bin/env bash
# SteamOS bottle — proof of concept, host side (macOS on Apple Silicon).
#
# Installs Lima + krunkit, creates a GPU-enabled Fedora VM (the "bottle"),
# copies the guest scripts in and provisions it.
#
# Usage:  ./host/setup-host.sh
# Optional env: VM_NAME (default steamos-bottle), CPUS, MEMORY (GiB), DISK (GiB)

set -euo pipefail

VM_NAME="${VM_NAME:-steamos-bottle}"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# brew refuses to run if the shell's current folder is gone or unreadable.
cd "$KIT_DIR" 2>/dev/null || cd "$HOME"
RESULTS_DIR="/tmp/lima/steamos-bottle-results"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Preflight -----------------------------------------------------------
[[ "$(uname -s)" == Darwin ]] || die "Run this on macOS."
[[ "$(uname -m)" == arm64 ]]  || die "This needs an Apple Silicon Mac (arm64)."

macos_ver="$(sw_vers -productVersion)"
(( ${macos_ver%%.*} >= 14 )) || die "macOS 14 (Sonoma) or newer is required; found $macos_ver."
command -v brew >/dev/null || die "Homebrew not found. Install it from https://brew.sh first."

pcores="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu)"
mem_gib="$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))"
CPUS="${CPUS:-$(( pcores < 4 ? 4 : pcores ))}"
MEMORY="${MEMORY:-$(( mem_gib / 2 ))}"
DISK="${DISK:-100}"
(( MEMORY >= 8 )) || warn "Only ${MEMORY} GiB RAM for the VM. Steam + a game wants 8+ (set MEMORY=8 if you can spare it)."

# --- 2. Host tools ----------------------------------------------------------
info "Installing Lima, jq and krunkit with Homebrew…"
brew install lima jq
# The krunkit tap moved from slp/krun to libkrun/krun. Having both tapped makes
# every dependency ambiguous ("Formulae found in multiple taps"), so drop the old one.
KRUN_TAP=libkrun/krun
if brew tap | grep -qx slp/krun; then
  info "Removing the old slp/krun tap (it moved to $KRUN_TAP)…"
  brew untap slp/krun || die "Couldn't untap slp/krun. Run: brew untap slp/krun"
fi
brew tap "$KRUN_TAP"

# Newer Homebrew refuses formulae from third-party taps until you trust them.
# Ask instead of trusting silently; scope the trust to the formulae krunkit needs.
KRUN_FORMULAE=(krunkit gvproxy libkrun libkrunfw virglrenderer-krun)
if ! brew list --versions krunkit >/dev/null 2>&1 && brew trust --help >/dev/null 2>&1; then
  echo
  echo "krunkit comes from a third-party Homebrew tap ($KRUN_TAP, run by the libkrun"
  echo "project). Homebrew needs you to trust it before installing. krunkit pulls in"
  echo "4 more formulae from the same tap: gvproxy, libkrun, libkrunfw, virglrenderer-krun."
  read -r -p "Trust these 5 $KRUN_TAP formulae and continue? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "Stopped. Re-run this script when you're ready to trust them."
  for f in "${KRUN_FORMULAE[@]}"; do
    brew trust --formula "$KRUN_TAP/$f"
  done
fi
brew install "$KRUN_TAP/krunkit"

lima_ver="$(limactl --version | awk '{print $NF}')"
(( ${lima_ver%%.*} >= 2 )) || die "Lima 2.0+ is needed for the krunkit driver; found $lima_ver. Run: brew upgrade lima"

if ! limactl info | jq -e '.vmTypesEx.krunkit // (.vmTypes | index("krunkit"))' >/dev/null; then
  die "Lima's krunkit driver isn't installed. See docs/DEVELOPMENT.md → Troubleshooting → 'krunkit driver missing'."
fi

# --- 3. Create / start the bottle VM ---------------------------------------
mkdir -p "$RESULTS_DIR"
host_log="$RESULTS_DIR/host-$(date +%Y%m%d-%H%M%S).txt"
{
  echo "# Host report"
  echo "date:      $(date)"
  echo "mac:       $(sysctl -n machdep.cpu.brand_string), ${mem_gib} GiB"
  echo "macOS:     $macos_ver"
  echo "lima:      $lima_ver"
  echo "krunkit:   $(krunkit --version 2>/dev/null || brew list --versions krunkit)"
  echo "vm:        $VM_NAME  cpus=$CPUS memory=${MEMORY}GiB disk=${DISK}GiB"
} > "$host_log"

if limactl list -q | grep -qx "$VM_NAME"; then
  info "VM '$VM_NAME' already exists, reusing it."
else
  info "Creating VM '$VM_NAME' (krunkit, Fedora, $CPUS CPUs, ${MEMORY} GiB RAM, ${DISK} GiB disk)…"
  SECONDS=0
  # Short user + home like SteamOS ("deck"): Steam builds FEX socket paths under
  # the home folder, and Unix sockets max out at 107 characters. Lima's default
  # home (/home/<mac-user>.guest) pushes them over the limit and games won't start.
  limactl create --name="$VM_NAME" --vm-type=krunkit \
    --cpus="$CPUS" --memory="$MEMORY" --disk="$DISK" \
    --set '.user.name = "deck" | .user.home = "/home/deck"' \
    --tty=false template:fedora
  echo "create:    ${SECONDS}s" >> "$host_log"
fi

# Games go to a folder on the Mac by default (bottle library add): normal files there, which
# take Mac space only while installed. The VM shares it from its start.
if [[ ! -f "$HOME/.config/steamos-bottle/libraries" ]]; then
  "$KIT_DIR/host/bottle" library add "$HOME/Games/Portalistic" --default || warn "No game folder on the Mac; games go on the VM's disk."
fi

if [[ "$(limactl list --format '{{.Status}}' "$VM_NAME")" != Running ]]; then
  info "Starting '$VM_NAME'…"
  SECONDS=0
  "$KIT_DIR/host/bottle" _lib-mounts || true
  limactl start "$VM_NAME"
  echo "boot:      ${SECONDS}s (limactl start, includes first-boot setup if new)" >> "$host_log"
fi

# --- 4. Provision the guest -------------------------------------------------
info "Copying guest scripts into the VM…"
limactl shell "$VM_NAME" rm -rf /tmp/steamos-bottle-guest
limactl copy -r "$KIT_DIR/guest" "$VM_NAME:/tmp/steamos-bottle-guest"

info "Provisioning the guest (Venus Mesa, FEX, desktop, ARM64 Steam launcher). This takes a while…"
SECONDS=0
limactl shell "$VM_NAME" sudo bash /tmp/steamos-bottle-guest/setup-guest.sh
echo "provision: ${SECONDS}s" >> "$host_log"

# --- 5. The bottle command + KosmicKrisp ------------------------------------
"$KIT_DIR/host/bottle" install

if (( ${macos_ver%%.*} >= 26 )); then
  echo
  echo "KosmicKrisp is LunarG's Vulkan driver for Metal. Windows (Direct3D) games need it:"
  echo "MoltenVK lacks features DXVK requires. It comes with the LunarG Vulkan SDK, which"
  echo "this installs into ~/VulkanSDK (asks for your Mac password)."
  read -r -p "Set up KosmicKrisp now? [Y/n] " answer
  if [[ ! "$answer" =~ ^[Nn]$ ]]; then
    "$KIT_DIR/host/kosmickrisp.sh" enable || warn "KosmicKrisp setup failed; retry later with: bottle kosmickrisp enable"
  fi
else
  warn "macOS $macos_ver: KosmicKrisp needs macOS 26+, so Windows games will lack GPU features (MoltenVK)."
fi

cat <<EOF

Done. Host report: $host_log

Play:
  bottle start      VM + desktop + Steam, opens Screen Sharing (password on the clipboard)
  bottle status     what's running
  bottle stop       quit Steam, shut the VM down
  bottle help       everything else
In Steam: a Windows game's Properties > Compatibility > force Proton Experimental.
EOF
