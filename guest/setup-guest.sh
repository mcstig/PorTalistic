#!/usr/bin/env bash
# SteamOS bottle — proof of concept, guest side (Fedora aarch64 under krunkit).
# Run as root via sudo from the normal Lima user; setup-host.sh does this for you.

set -euo pipefail

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo."
TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || die "Run via sudo from the normal (non-root) user."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Preflight: is this really a krunkit guest we can use? ------------------
[[ "$(uname -m)" == aarch64 ]] || die "Expected an aarch64 guest, got $(uname -m)."
pagesize="$(getconf PAGESIZE)"
[[ "$pagesize" == 4096 ]] || die "Guest kernel uses ${pagesize}-byte pages; FEX needs 4K pages."
compgen -G '/dev/dri/renderD*' >/dev/null \
  || die "No /dev/dri render node. The VM isn't running under krunkit with a GPU (check vmType)."

# Don't let one package missing from this Fedora release abort the whole install.
if dnf --version 2>/dev/null | grep -qi dnf5; then
  SKIP=(--skip-unavailable)
else
  SKIP=(--setopt=strict=0)
fi

# --- dnf plugins (copr + versionlock), dnf5 or dnf4 --------------------------
info "Installing dnf plugins…"
dnf install -y dnf5-plugins 2>/dev/null || true
dnf install -y dnf-plugins-core 2>/dev/null || true
dnf install -y dnf-plugin-versionlock 2>/dev/null \
  || dnf install -y python3-dnf-plugin-versionlock 2>/dev/null || true
dnf copr --help >/dev/null 2>&1 || die "'dnf copr' is unavailable; can't add the Venus Mesa repo."

# --- Packages -----------------------------------------------------------------
info "Installing Vulkan, desktop, Steam dependencies and FEX…"
dnf install -y "${SKIP[@]}" \
  mesa-vulkan-drivers mesa-dri-drivers vulkan-loader vulkan-tools \
  xorg-x11-server-Xvfb openbox x11vnc xterm dbus-x11 xdg-user-dirs \
  wget curl unzip tar xz binutils zenity procps-ng lsof \
  libvpx libnsl libatomic nss fontconfig libXtst libXinerama libXext libICE \
  libva libvdpau mesa-libGL libglvnd-glx openal-soft SDL3 \
  pipewire-libs pulseaudio-libs NetworkManager-libnm xdg-desktop-portal \
  gtk2 ibus-libs

# Optional extras: don't fail the whole run if one is missing from this Fedora release.
for pkg in glx-utils mesa-demos vkmark llvm18-libs \
           tigervnc-server-minimal xkbcomp setxkbmap xkeyboard-config xprop xmodmap; do
  dnf install -y "$pkg" >/dev/null 2>&1 && info "  optional: $pkg installed" || warn "  optional: $pkg not available"
done

# FEX: only needed for x86 *Linux* games; Proton ARM64 ships its own FEX for Windows code.
if dnf install -y fex-emu fex-emu-rootfs-fedora erofs-fuse; then
  FEX_OK=1
else
  FEX_OK=0
  warn "FEX packages failed to install; x86 Linux games won't run (Proton ARM64 may still work)."
fi
# Keep QEMU's binfmt handlers from grabbing x86 binaries before FEX does.
dnf remove -y 'qemu-user-static*' >/dev/null 2>&1 || true

# --- Venus-enabled Mesa (same recipe as Lima's krunkit docs) ----------------
info "Switching to the Venus-patched Mesa from COPR (slp/mesa-libkrun-vulkan)…"
dnf copr enable -y slp/mesa-libkrun-vulkan
REPOID="copr:copr.fedorainfracloud.org:slp:mesa-libkrun-vulkan"
MESA_VERSION="$(dnf repoquery -q --available --repoid="$REPOID" --latest-limit=1 \
                 --qf '%{evr}' mesa-vulkan-drivers 2>/dev/null | head -n1)"
[[ -n "$MESA_VERSION" ]] || die "The COPR has no mesa-vulkan-drivers build for Fedora $(rpm -E %fedora). See README → Troubleshooting."

current="$(rpm -q --qf '%{evr}' mesa-vulkan-drivers)"
if [[ "$current" != "$MESA_VERSION" ]]; then
  dnf downgrade -y "mesa-vulkan-drivers-${MESA_VERSION}" \
    || dnf install -y --allowerasing "mesa-vulkan-drivers-${MESA_VERSION}" \
    || die "Couldn't switch to mesa-vulkan-drivers-${MESA_VERSION}. See README → Troubleshooting."
fi
dnf versionlock add "mesa-vulkan-drivers-${MESA_VERSION}" \
  || warn "versionlock failed: don't run 'dnf upgrade' or Mesa may lose Venus support."

# Package installs restart systemd-binfmt many times in a row, which trips
# systemd's start limit and leaves FEX's binfmt handlers unregistered.
systemctl reset-failed systemd-binfmt 2>/dev/null || true
systemctl restart systemd-binfmt || warn "systemd-binfmt didn't start; x86 programs won't launch via FEX automatically."
if (( FEX_OK )) && ! compgen -G '/proc/sys/fs/binfmt_misc/FEX*' >/dev/null; then
  warn "FEX isn't registered in binfmt_misc; x86 Linux games won't start automatically."
fi

# Steam's arm64 client looks for Debian's CA bundle path ("unable to load trusted
# SSL root certificates" otherwise). Point it at Fedora's bundle.
dnf install -y ca-certificates >/dev/null 2>&1 || true
update-ca-trust extract || true
CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
CA_DIR=/etc/pki/ca-trust/extracted/pem/directory-hash
if [[ -f "$CA_BUNDLE" ]]; then
  ln -sfn "$CA_BUNDLE" /etc/ssl/certs/ca-certificates.crt   # Debian/SteamOS bundle path
  install -d -m 0755 /usr/lib/ssl                           # Debian OpenSSL default dir
  ln -sfn "$CA_BUNDLE" /usr/lib/ssl/cert.pem
  [[ -d "$CA_DIR" ]] && ln -sfn "$CA_DIR" /usr/lib/ssl/certs
else
  warn "No CA bundle at $CA_BUNDLE; Steam won't be able to download anything."
fi

# The desktop outlives the `limactl shell` session that starts it. Without
# lingering, logind deletes /run/user/<uid> when that session ends, and FEX's
# per-game FEXServer (and other sockets) have nowhere to live.
loginctl enable-linger "$TARGET_USER" || warn "enable-linger failed; FEX games may fail to start."

# --- Per-user FEX config ------------------------------------------------------
if (( FEX_OK )); then
  rootfs="$(rpm -ql fex-emu-rootfs-fedora 2>/dev/null | grep -m1 '\.erofs$' || true)"
  cfg_dir="$TARGET_HOME/.fex-emu"
  if [[ -n "$rootfs" && ! -f "$cfg_dir/Config.json" ]]; then
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$cfg_dir"
    # Thunks (GL/Vulkan forwarding to the native arm64 Mesa) are left OFF on purpose:
    # the first test measures what x86 games get from the rootfs Mesa alone.
    cat > "$cfg_dir/Config.json" <<EOF
{
  "Config": {
    "RootFS": "$rootfs",
    "X87ReducedPrecision": "1"
  }
}
EOF
    chown "$TARGET_USER:$TARGET_USER" "$cfg_dir/Config.json"
    info "FEX rootfs: $rootfs"
  elif [[ -z "$rootfs" ]]; then
    warn "No FEX rootfs image found; run FEXRootFSFetcher as $TARGET_USER."
  fi

  # Steam's own FEX (the one it downloads for games) expects SteamOS's x86 rootfs
  # at /usr/share/guestos/fex-mesa. Stand in Fedora's x86 rootfs, unpacked.
  GUEST_ROOTFS=/usr/share/guestos/fex-mesa
  if [[ -n "$rootfs" ]] && [[ -z "$(ls -A "$GUEST_ROOTFS" 2>/dev/null)" ]]; then
    info "Unpacking the x86 rootfs to $GUEST_ROOTFS for Steam's FEX…"
    dnf install -y erofs-utils >/dev/null 2>&1 || true
    install -d -m 0755 "$GUEST_ROOTFS"
    ( umask 022; fsck.erofs --extract="$GUEST_ROOTFS" "$rootfs" ) \
      || warn "Couldn't unpack $rootfs; x86 games launched by Steam will fail."
  fi
fi

# --- Everything that update-guest.sh keeps current ----------------------------
# Tools, TigerVNC desktop, present layer (arm64 + x86), Mac-patched x86 Venus driver,
# DXVK 2.6.2 for Windows games. Needs the x86 rootfs unpacked above.
bash "$HERE/update-guest.sh" || warn "Some update steps failed (see above); fix and re-run: bottle update"

# --- Summary --------------------------------------------------------------------
cat <<EOF

Guest ready.
  Mesa (Venus):  mesa-vulkan-drivers-$(rpm -q --qf '%{evr}' mesa-vulkan-drivers)
  FEX:           $( (( FEX_OK )) && rpm -q fex-emu || echo "not installed")
  Page size:     $pagesize
  GPU node:      $(ls /dev/dri/renderD* | tr '\n' ' ')

On the Mac, use the bottle command:  bottle start   (desktop + Steam + Screen Sharing)
Inside the VM:
  bottle-desktop   start the virtual desktop + VNC server
  steam-arm64      download/launch Valve's ARM64 Steam client
  bottle-dxvk      DXVK 2.6.2 drop-in for Windows games (status/apply/remove)
  bottle-bench     baseline report (Vulkan features, FEX, vkmark)
EOF
