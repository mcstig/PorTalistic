#!/usr/bin/env bash
# Bring the bottle's guest side up to date. Idempotent: safe to run again any time.
# setup-guest.sh runs it at the end of a fresh install; `bottle update` on the Mac runs it
# on an existing VM. Run as root via sudo from the normal user.
#
#   desktop     TigerVNC Xvnc + full keyboard map (bottle-desktop)
#   screen      bottle-screen: frames to the Portalistic app on the Mac, input back (4720)
#   controllers uinput for bottle-screen's virtual Xbox 360 pads (the Mac's controllers)
#   sound       PipeWire output for games (the VM has no sound card; games whose audio finds
#               no device crash or hang at start), streamed to the Mac on port 4711
#   tools       steam-arm64, bottle-desktop, bottle-bench, bottle-dxvk, bottle-steamplay,
#               bottle-busy, bottle-maximize-steam, bottle-library, bottle-log(keep),
#               bottle-resolution (the screen's size), bottle-whyquit (why a game closed at
#               launch), bottle-libraries (the Mac's game folders as Steam libraries),
#               bottle-stores (GOG and Epic games as non-Steam games in Steam), bottle-session
#               (Game Mode / Desktop Mode) -> /usr/local/bin
#   GOG         gogdl (Heroic's GOG downloader, guest/stores) and its patch module, for
#               bottle-stores -> /usr/local/share/steamos-bottle/gogdl
#   Epic        Legendary (the Epic Games Store downloader, guest/stores/legendary) and the
#               Python modules it needs, for bottle-stores
#               -> /usr/local/share/steamos-bottle/legendary
#   Comet       the open-source stand-in for the GOG Galaxy client's background service
#               (guest/comet, a ready-made arm64 build): GOG games that use the Galaxy SDK
#               sign in through it; bottle-stores starts it for them
#               -> /usr/local/share/steamos-bottle/comet
#   GPU numbers libnvidia-ml.so.1 stand-in with the Mac's GPU load/memory/temperature, for
#               Steam's performance monitor (guest/nvml)
#   arm64 layer swapchain + DXVK feature stand-ins for native Vulkan apps
#   x86 driver  Mac-patched Venus for Proton/Wine under FEX, 64- and 32-bit (x86-venus.sh)
#   x86 layer   same layer for the x86 side, x86_64 and i386 builds (install-x86.sh)
#   DXVK 2.6.2  DLL cache for bottle-dxvk: Ph42oN's dxvk-gplasync 2.6.2-1 (asynchronous
#               pipeline compiling) and plain 2.6.2 (the fallback)
#   x86 order   bottle-tso, and its module rebuilt for a new kernel while it's on
#   memory      bottle-memtrim.service off again (tried Oct 9, games crashed with it; the VM's
#               memory size caps its use of the Mac's instead: bottle memory on the Mac)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DXVK_VER=2.6.2
DXVK_SHA256=17761876556afd55736cb895d184f5a1c55d43350f1b1e3b129f8d28706d7992
DXVK_URL="https://github.com/doitsujin/dxvk/releases/download/v${DXVK_VER}/dxvk-${DXVK_VER}.tar.gz"
DXVK_DIR="/usr/local/share/steamos-bottle/dxvk-${DXVK_VER}"
# dxvk-gplasync: GitLab keeps the release tarballs in the repository; the checksum is the one
# Bottles (bottlesdevs/components, dxvk-gplasync-v2.6.2-1.yml) publishes for this file.
ASYNC_NAME=dxvk-gplasync-v2.6.2-1
ASYNC_URL="https://gitlab.com/Ph42oN/dxvk-gplasync/-/raw/main/releases/${ASYNC_NAME}.tar.gz?ref_type=heads"
ASYNC_MD5=26a85174bddadedac58244d98644988f
ASYNC_DIR=/usr/local/share/steamos-bottle/dxvk-gplasync-2.6.2-1
# vkd3d-proton 3.0.1 (DirectX 12): Proton's 3.1 requires maintenance5/6, which the Mac's GPU
# doesn't have; 3.0.1 runs on it (its own test suite, Oct 10). bottle-dxvk puts it in place.
VKD3D_VER=3.0.1
VKD3D_SHA256=3cf2315522af5e43605ef6d3c41dad91387040bf97199934f3f7ab76caaa2f0c
VKD3D_URL="https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v${VKD3D_VER}/vkd3d-proton-${VKD3D_VER}.tar.zst"
VKD3D_DIR="/usr/local/share/steamos-bottle/vkd3d-proton-${VKD3D_VER}"
GUEST_ROOTFS=/usr/share/guestos/fex-mesa
# The VM's own programs: the kit's ready-made builds, or built here (build-recipes.sh)
PB_SRC="$HERE"
# shellcheck source=build-recipes.sh
. "$HERE/build-recipes.sh"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo."
TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || die "Run via sudo from the normal (non-root) user."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
STATE="$TARGET_HOME/.config/steamos-bottle"
FAILED=()

SPLASH_ON="$TARGET_HOME/.cache/steamos-bottle/splash.pid"   # bottle-splash's card is up (the Mac's _up showed it)
STEP_N=0
step() {  # step "description" command... : run, record failure, keep going (each step's time in the log)
  local what="$1" t0=$SECONDS; shift
  STEP_N=$(( STEP_N + 1 ))
  info "$what"
  if [[ -f "$SPLASH_ON" && -x /usr/local/bin/bottle-splash ]]; then
    sudo -u "$TARGET_USER" HOME="$TARGET_HOME" /usr/local/bin/bottle-splash text "Updating Portalistic's Linux system (step $STEP_N of about 25): $what" >/dev/null 2>&1 || true
  fi
  if ! "$@"; then
    warn "$what: failed (see above)"
    FAILED+=("$what")
  fi
  echo "  ($(( SECONDS - t0 )) s)"
}

# --- Desktop packages --------------------------------------------------------
desktop_packages() {
  local p missing=0
  for p in tigervnc-server-minimal xkbcomp setxkbmap xkeyboard-config xprop xmodmap xset wmctrl xfwm4 python3; do
    rpm -q "$p" >/dev/null 2>&1 && continue
    dnf install -y -q "$p" >/dev/null 2>&1 || { warn "  couldn't install $p"; missing=1; }
  done
  command -v Xvnc >/dev/null || warn "  no Xvnc: the desktop falls back to Xvfb + x11vnc (tears, slower input)"
  # glxinfo / glxgears / xwd: bottle steam-gpu checks OpenGL on the Mac GPU (zink) and that
  # Big Picture really shows with it
  for p in glx-utils xwd; do
    rpm -q "$p" >/dev/null 2>&1 || dnf install -y -q "$p" >/dev/null 2>&1 \
      || warn "  couldn't install $p (only bottle steam-gpu needs it)"
  done
  # xrandr: the screen follows the Mac window's size (bottle-resolution)
  rpm -q xrandr >/dev/null 2>&1 || dnf install -y -q xrandr >/dev/null 2>&1 \
    || warn "  couldn't install xrandr (the screen then stays 1920x1080)"
  return $missing
}

# --- Sound: a silent output for games ------------------------------------------
# krunkit gives the VM no sound card. Wine then finds no audio device, and games crash
# or hang while starting their audio (seen in DMC5: null pointer in FAudio's client
# thread, an assertion, or a deadlock right after XAudio2 loads). PipeWire with a null
# sink is a real (silent) audio device for them, and the base for sound on the Mac later.
sound() {
  local p missing=0 uid run d
  for p in pipewire pipewire-pulseaudio wireplumber pulseaudio-utils; do
    rpm -q "$p" >/dev/null 2>&1 && continue
    dnf install -y -q "$p" >/dev/null 2>&1 || { warn "  couldn't install $p"; missing=1; }
  done
  (( missing )) && return 1
  uid="$(id -u "$TARGET_USER")"
  run="/run/user/$uid"
  # The user's services keep running without a login (Steam is started over ssh).
  loginctl enable-linger "$TARGET_USER" || return 1
  d="$TARGET_HOME/.config/pipewire/pipewire.conf.d"
  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.config" "$TARGET_HOME/.config/pipewire" "$d"
  cat > "$d/50-bottle-sink.conf" <<'EOF'
# SteamOS bottle: the VM has no sound card, so games get this silent output instead.
context.objects = [
  { factory = adapter
    args = {
      factory.name     = support.null-audio-sink
      node.name        = "bottle-sink"
      node.description = "SteamOS bottle (silent)"
      media.class      = Audio/Sink
      audio.position   = [ FL FR ]
      monitor.channel-volumes = true
      monitor.passthrough = true
      adapter.auto-port-config = { mode = dsp monitor = true position = preserve }
    }
  }
]
EOF
  # Whatever plays there goes out as raw 48 kHz stereo 16-bit PCM on localhost:4711; Lima
  # forwards the port to the Mac, where `bottle` plays it (host/bottle-audio.swift).
  cat > "$d/60-bottle-to-mac.conf" <<'EOF'
# SteamOS bottle: send the silent output's sound to the Mac (bottle-audio connects here).
context.modules = [
  { name = libpipewire-module-protocol-simple
    args = {
      capture = true
      playback = false
      capture.node = "bottle-sink"
      capture.props = {
        stream.capture.sink = true
        node.name = "bottle-to-mac"
        node.description = "Sound to the Mac"
      }
      audio.rate = 48000
      audio.format = S16LE
      audio.channels = 2
      audio.position = [ FL FR ]
      server.address = [ "tcp:127.0.0.1:4711" ]
    }
  }
]
EOF
  chown "$TARGET_USER:$TARGET_USER" "$d/50-bottle-sink.conf" "$d/60-bottle-to-mac.conf"
  systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$run/bus" ]] && break; sleep 1; done
  local -a as_user=(sudo -u "$TARGET_USER" env XDG_RUNTIME_DIR="$run" DBUS_SESSION_BUS_ADDRESS="unix:path=$run/bus")
  "${as_user[@]}" systemctl --user enable pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1 || true
  # restart so a changed sink config is read
  "${as_user[@]}" systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service || return 1
  for _ in 1 2 3 4 5; do
    "${as_user[@]}" pactl info 2>/dev/null | grep -q '^Default Sink: bottle-sink' && break
    sleep 1
  done
  if "${as_user[@]}" pactl info 2>/dev/null | grep -q '^Default Sink: bottle-sink'; then
    echo "  sound output ready (bottle-sink)"
    if ss -ltn 2>/dev/null | grep -q '127.0.0.1:4711 '; then
      echo "  sending it to the Mac on port 4711"
    else
      warn "  the stream to the Mac (port 4711) isn't listening"
    fi
  else
    "${as_user[@]}" pactl info 2>&1 | sed 's/^/  /' | head -12
    warn "  the silent output isn't the default sink"
    return 1
  fi
}

# --- Game controllers from the Mac ----------------------------------------------
# bottle-screen turns the Mac's controllers into virtual Xbox 360 pads through uinput: it needs
# /dev/uinput (the module, loaded at every boot, and access for the user), and Steam and the
# games need to open the pads it creates. An ACL rather than a group: processes started over
# Lima's shared ssh connection wouldn't see a new group until the VM restarts.
controllers() {
  local rules=/etc/udev/rules.d/70-steamos-bottle.rules
  if [[ ! -e /dev/uinput ]] && ! modprobe uinput 2>/dev/null; then
    dnf install -y -q "kernel-modules-$(uname -r)" >/dev/null 2>&1 && modprobe uinput 2>/dev/null
  fi
  if [[ ! -e /dev/uinput ]]; then
    warn "  this kernel ($(uname -r)) has no uinput module; update the VM's kernel (bottle shell, then: sudo dnf upgrade kernel), restart the VM (bottle restart) and run bottle update again"
    return 1
  fi
  echo uinput > /etc/modules-load.d/steamos-bottle.conf
  rpm -q acl >/dev/null 2>&1 || dnf install -y -q acl >/dev/null 2>&1
  cat > "$rules" <<EOF
# SteamOS Bottle (update-guest.sh): bottle-screen creates virtual game controllers through
# uinput for the Mac's controllers; Steam and the games may read them and make them rumble.
KERNEL=="uinput", SUBSYSTEM=="misc", RUN+="/usr/bin/setfacl -m u:$TARGET_USER:rw /dev/uinput"
SUBSYSTEM=="input", ATTRS{phys}=="steamos-bottle/*", MODE="0666"
EOF
  udevadm control --reload-rules 2>/dev/null || true
  setfacl -m "u:$TARGET_USER:rw" /dev/uinput || return 1
  echo "  ready: the Mac's controllers appear in games as Xbox 360 pads"
}

# --- Libraries the bottle's own programs run with --------------------------------
# (the build tools' -devel packages used to bring them in; VMs without build tools need them
# by name)
runtime_libs() {
  local p missing=0
  for p in $PB_RUNTIME; do
    rpm -q "$p" >/dev/null 2>&1 && continue
    dnf install -y -q "$p" >/dev/null 2>&1 || { warn "  couldn't install $p"; missing=1; }
  done
  return $missing
}

# --- Screen server for the Portalistic app on the Mac ----------------------------
screen_server() {
  local tmp
  tmp="$(mktemp)"
  pb_get bottle-screen "$tmp" || { rm -f "$tmp"; return 1; }
  install -m 0755 "$tmp" /usr/local/bin/bottle-screen
  rm -f "$tmp"
  # Restart a running one on the new build (the desktop starts it otherwise: bottle-desktop).
  if pgrep -x bottle-screen >/dev/null; then
    pkill -x bottle-screen || true
    sleep 0.5
  fi
  if [[ -S /tmp/.X11-unix/X1 ]]; then
    # shellcheck disable=SC2016  # expands as the user
    sudo -u "$TARGET_USER" env DISPLAY=:1 LOGF="$STATE/screen.log" \
      bash -c 'setsid -f /usr/local/bin/bottle-screen -d :1 -p 4720 </dev/null >>"$LOGF" 2>&1' || true
    sleep 0.5
    pgrep -x bottle-screen >/dev/null && echo "  running on port 4720"
  fi
}

# --- The Mac's GPU numbers for Steam's performance monitor ------------------------
# guest/nvml: an NVML (libnvidia-ml.so.1) that answers with what the Mac app measures; Steam's
# overlay UI loads it from Steam's own library folder, where steam-arm64 links it.
nvml_build() {
  local tmp
  tmp="$(mktemp)"
  pb_get libnvidia-ml.so.1 "$tmp" || { rm -f "$tmp"; return 1; }
  install -d -m 0755 /usr/local/lib/steamos-bottle || { rm -f "$tmp"; return 1; }
  install -m 0755 "$tmp" /usr/local/lib/steamos-bottle/libnvidia-ml.so.1
  rm -f "$tmp"
  echo "  in place (Steam links it at its next start)"
}

# --- The desktop as the Mac app shows it -----------------------------------------
desktop_look() {  # bottle-desktop applies it (Steam's main window maximized, no terminal); only if X is up
  [[ -S /tmp/.X11-unix/X1 ]] || { echo "  applies when the desktop starts"; return 0; }
  # the window keeper on its new version (bottle-desktop starts it again for a running Steam)
  pkill -u "$TARGET_USER" -f "[b]ottle-maximize-steam --keep" 2>/dev/null || true
  # (wait until the old one has let go of its lock: a new one started meanwhile quits at once, and then
  # none is left; a restart that came back without a keeper, Oct 14)
  for _ in $(seq 1 20); do
    pgrep -u "$TARGET_USER" -f "[b]ottle-maximize-steam --keep" >/dev/null 2>&1 || break
    sleep 0.3
  done
  sudo -u "$TARGET_USER" -H /usr/local/bin/bottle-desktop >/dev/null
}

# --- Tools -------------------------------------------------------------------
tools() {
  install -m 0755 "$HERE/steam-arm64"   /usr/local/bin/steam-arm64    || return 1
  install -m 0755 "$HERE/start-desktop" /usr/local/bin/bottle-desktop || return 1
  install -m 0755 "$HERE/bench"         /usr/local/bin/bottle-bench   || return 1
  install -m 0755 "$HERE/bottle-dxvk"   /usr/local/bin/bottle-dxvk    || return 1
  install -m 0755 "$HERE/bottle-log"     /usr/local/bin/bottle-log     || return 1
  install -m 0755 "$HERE/bottle-logkeep" /usr/local/bin/bottle-logkeep || return 1
  install -m 0755 "$HERE/bottle-steamplay" /usr/local/bin/bottle-steamplay || return 1
  install -m 0755 "$HERE/bottle-busy"      /usr/local/bin/bottle-busy      || return 1
  install -m 0755 "$HERE/bottle-maximize-steam" /usr/local/bin/bottle-maximize-steam || return 1
  install -m 0755 "$HERE/bottle-library"   /usr/local/bin/bottle-library   || return 1
  install -m 0755 "$HERE/bottle-resolution" /usr/local/bin/bottle-resolution || return 1
  install -m 0755 "$HERE/bottle-whyquit"   /usr/local/bin/bottle-whyquit   || return 1
  install -m 0755 "$HERE/bottle-session"   /usr/local/bin/bottle-session   || return 1
  install -m 0755 "$HERE/bottle-libraries" /usr/local/bin/bottle-libraries || return 1
  install -m 0755 "$HERE/bottle-splash"    /usr/local/bin/bottle-splash    || return 1
  install -m 0755 "$HERE/bottle-stores"    /usr/local/bin/bottle-stores    || return 1
  install -m 0755 "$HERE/tso/bottle-tso"   /usr/local/bin/bottle-tso       || return 1
  install -d -m 0755 /usr/local/share/steamos-bottle/tso || return 1
  install -m 0644 "$HERE/tso/bottle_tso.c" /usr/local/share/steamos-bottle/tso/ || return 1
  install -m 0755 "$HERE/tso/bottle-tso-check.x86_64" /usr/local/share/steamos-bottle/tso/ || return 1
  # Steam lives in /s when the home folder is long (FEX socket paths, see steam-arm64).
  if [[ ! -d /s ]]; then
    install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" /s || return 1
  fi
  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$STATE" || return 1
  if [[ ! -f "$STATE/steam.env" ]]; then
    cat > "$STATE/steam.env" <<'EOF'
# Extra environment for Steam and the games it starts (read by steam-arm64).
# Uncomment what you need, then restart Steam (on the Mac: bottle steam).
#PROTON_LOG=1              # per-game log in ~/steam-<appid>.log
#DXVK_HUD=fps              # FPS counter in Direct3D games
#BOTTLE_PRESENT_DEBUG=1    # frame-rate lines from the present layer in the Proton log
#BOTTLE_DXVK=0             # don't drop DXVK 2.6.2 into Windows games
#BOTTLE_PRESENT_SYNC=1     # old presentation path (if the new one misbehaves)
#BOTTLE_PRESENT_SWAP_RB=1  # swap red and blue on screen (if a game's colours are off)
#BOTTLE_VN_ABORT=1        # let the GPU driver stop a game when the Mac side seems stuck (Venus default)
EOF
    chown "$TARGET_USER:$TARGET_USER" "$STATE/steam.env"
  fi
}

# --- GOG: gogdl, for bottle-stores ---------------------------------------------------------
# Heroic's GOG downloader (Python, guest/stores/gogdl) plus its patch module, a C extension that
# is built like the VM's other programs (build-recipes.sh). Without the module a fresh install
# works; only an update that GOG ships as patches doesn't.
GOGDL_DIR=/usr/local/share/steamos-bottle/gogdl
gogdl_install() {
  local tmp
  command -v python3 >/dev/null || { warn "  no python3: GOG downloads won't work"; return 1; }
  python3 -c 'import requests' 2>/dev/null || dnf install -y -q python3-requests >/dev/null 2>&1 \
    || warn "  python3-requests isn't there and wouldn't install: GOG downloads need it"
  install -d -m 0755 "$GOGDL_DIR" || return 1
  rm -rf "${GOGDL_DIR:?}/gogdl"
  cp -r "$HERE/stores/gogdl" "$GOGDL_DIR/gogdl" || return 1
  install -m 0644 "$HERE/stores/LICENSE-gogdl" "$HERE/stores/MODIFICATIONS.txt" "$GOGDL_DIR/" || return 1
  tmp="$(mktemp)"
  if pb_get gogdl_xdelta3.abi3.so "$tmp"; then
    install -m 0644 "$tmp" "$GOGDL_DIR/gogdl_xdelta3.abi3.so"
  else
    warn "  gogdl's patch module isn't available: GOG updates that come as patches won't apply"
  fi
  rm -f "$tmp"
  chmod -R a+rX "$GOGDL_DIR"
  if python3 -I -c "import sys; sys.path.insert(0, '$GOGDL_DIR'); import gogdl.cli" 2>"$tmp.err"; then
    echo "  gogdl in place"
  else
    tail -3 "$tmp.err" >&2; rm -f "$tmp.err"
    warn "  gogdl doesn't load; GOG downloads won't work"
    return 1
  fi
  rm -f "$tmp.err"
}

# --- Epic Games: Legendary, for bottle-stores ----------------------------------------------
# The Epic Games Store downloader (Python, guest/stores/legendary) with the three Python modules it
# needs; Fedora has them all (requests is there already for gogdl).
LEGENDARY_DIR=/usr/local/share/steamos-bottle/legendary
legendary_install() {
  local tmp need=()
  command -v python3 >/dev/null || { warn "  no python3: Epic downloads won't work"; return 1; }
  python3 -c 'import requests' 2>/dev/null || need+=(python3-requests)
  python3 -c 'import filelock' 2>/dev/null || need+=(python3-filelock)
  python3 -c 'import Cryptodome' 2>/dev/null || need+=(python3-pycryptodomex)
  if (( ${#need[@]} )); then
    dnf install -y -q "${need[@]}" >/dev/null 2>&1 \
      || warn "  ${need[*]} wouldn't install: Epic downloads need them"
  fi
  install -d -m 0755 "$LEGENDARY_DIR" || return 1
  rm -rf "${LEGENDARY_DIR:?}/legendary"
  cp -r "$HERE/stores/legendary" "$LEGENDARY_DIR/legendary" || return 1
  find "$LEGENDARY_DIR/legendary" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
  install -m 0644 "$HERE/stores/LICENSE-legendary" "$HERE/stores/MODIFICATIONS.txt" "$LEGENDARY_DIR/" || return 1
  chmod -R a+rX "$LEGENDARY_DIR"
  tmp="$(mktemp)"
  # (importing it as root also leaves the compiled files behind, which the players can't write themselves)
  if python3 -I -c "import sys; sys.path.insert(0, '$LEGENDARY_DIR'); import legendary.cli" 2>"$tmp"; then
    chmod -R a+rX "$LEGENDARY_DIR"
    echo "  Legendary in place"
  else
    tail -3 "$tmp" >&2; rm -f "$tmp"
    warn "  Legendary doesn't load; Epic downloads won't work"
    return 1
  fi
  rm -f "$tmp"
}

# --- Comet: the Galaxy client's service, for GOG games that use the Galaxy SDK ------------------
# A ready-made arm64 build (guest/comet, built from the pinned source by guest/comet/build-aarch64.sh;
# the VMs Portalistic ships have no compilers). bottle-stores starts it beside such a game.
COMET_DIR=/usr/local/share/steamos-bottle/comet
comet_install() {
  local src="$HERE/comet" want got
  if [[ ! -f "$src/comet-aarch64" || ! -f "$src/MANIFEST" ]]; then
    warn "  Comet isn't in this kit: GOG games that ask for the Galaxy client's sign-in won't get it"
    return 0
  fi
  want="$(awk '$1 == "comet-aarch64" {print $2}' "$src/MANIFEST")"
  got="$(sha256sum "$src/comet-aarch64" | cut -d' ' -f1)"
  if [[ -z "$want" || "$want" != "$got" ]]; then
    warn "  Comet's checksum doesn't match guest/comet/MANIFEST; not installed"
    return 1
  fi
  install -d -m 0755 "$COMET_DIR" || return 1
  # (a running Comet keeps its old file: replace by rename)
  install -m 0755 "$src/comet-aarch64" "$COMET_DIR/comet.new" && mv -f "$COMET_DIR/comet.new" "$COMET_DIR/comet" || return 1
  install -m 0644 "$src/BUILT" "$src/CRATES.tsv" "$src/LICENSE-comet" "$src/LICENSE-proto-cc0" \
    "$src/THIRD-PARTY-LICENSES.txt" "$COMET_DIR/" || return 1
  if "$COMET_DIR/comet" --version >/dev/null 2>&1; then
    echo "  Comet $("$COMET_DIR/comet" --version | awk '{print $2}') in place"
  else
    warn "  Comet doesn't start here; GOG games that ask for the Galaxy client's sign-in won't get it"
    return 1
  fi
}

# --- Desktop Mode: Plasma's settings, if it's installed ---------------------------------------------
# Desktop Mode (KDE Plasma, bottle-session) is installed by the user's first switch to it, not with
# the image (about 300 MB). When it's there, its settings follow the kit.
desktop_mode_settings() {
  if ! command -v startplasma-x11 >/dev/null; then
    echo "  Desktop Mode isn't installed (Steam > Switch to Desktop Mode installs it)"
    return 0
  fi
  sudo -u "$TARGET_USER" -H /usr/local/bin/bottle-session configure && echo "  Plasma's settings in place"
}

# --- FEX's own settings for the user ------------------------------------------------
# (x86 programs run outside Steam: the bottle's GPU checks. Steam's FEX brings its own settings
# and runs games on /usr/share/guestos/fex-mesa.) The x86 system it runs on: the package's
# compressed copy if there is one, else the unpacked one (Portalistic's image keeps only that).
fex_config() {
  local d="$TARGET_HOME/.fex-emu" rootfs
  command -v FEXInterpreter >/dev/null 2>&1 || return 0
  [[ -f "$d/Config.json" ]] && return 0
  rootfs="$(rpm -ql fex-emu-rootfs-fedora 2>/dev/null | grep -m1 '\.erofs$' || true)"
  [[ -n "$rootfs" && -f "$rootfs" ]] || rootfs="$GUEST_ROOTFS"
  [[ -e "$rootfs" ]] || { echo "  no x86 system for FEX"; return 0; }
  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$d" || return 1
  cat > "$d/Config.json" <<EOF
{
  "Config": {
    "RootFS": "$rootfs",
    "X87ReducedPrecision": "1"
  }
}
EOF
  chown "$TARGET_USER:$TARGET_USER" "$d/Config.json"
  echo "  FEX runs x86 programs on $rootfs"
}

# --- DXVK 2.6.2 cache ----------------------------------------------------------
dxvk_cache() {
  if [[ -f "$DXVK_DIR/x64/d3d11.dll" && -f "$DXVK_DIR/x32/d3d11.dll" ]]; then
    echo "  already in $DXVK_DIR"
    return 0
  fi
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/dxvk.tgz" "$DXVK_URL" || { rm -rf "$tmp"; return 1; }
  if ! echo "$DXVK_SHA256  $tmp/dxvk.tgz" | sha256sum -c --quiet -; then
    rm -rf "$tmp"; warn "  checksum mismatch for $DXVK_URL"; return 1
  fi
  if ! { tar -xzf "$tmp/dxvk.tgz" -C "$tmp" && install -d -m 0755 "$DXVK_DIR" \
         && rm -rf "${DXVK_DIR:?}/x64" "${DXVK_DIR:?}/x32" \
         && cp -r "$tmp/dxvk-$DXVK_VER/x64" "$tmp/dxvk-$DXVK_VER/x32" "$DXVK_DIR/" \
         && chmod -R a+rX "$DXVK_DIR"; }; then
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  echo "  installed to $DXVK_DIR"
}

# --- dxvk-gplasync 2.6.2-1 (bottle-dxvk prefers it; plain 2.6.2 stays as the fallback) -----
dxvk_async_cache() {
  if [[ -f "$ASYNC_DIR/x64/d3d11.dll" && -f "$ASYNC_DIR/x32/d3d11.dll" ]]; then
    echo "  already in $ASYNC_DIR"
    return 0
  fi
  local tmp x64 x32; tmp="$(mktemp -d)"
  if ! curl -fsSL -o "$tmp/a.tgz" "$ASYNC_URL"; then
    rm -rf "$tmp"; warn "  couldn't download $ASYNC_URL: games keep plain DXVK 2.6.2"; return 0
  fi
  if ! echo "$ASYNC_MD5  $tmp/a.tgz" | md5sum -c --quiet -; then
    rm -rf "$tmp"; warn "  checksum mismatch for $ASYNC_NAME: games keep plain DXVK 2.6.2"; return 0
  fi
  tar -xzf "$tmp/a.tgz" -C "$tmp" || { rm -rf "$tmp"; warn "  couldn't unpack $ASYNC_NAME: games keep plain DXVK 2.6.2"; return 0; }
  x64="$(dirname "$(find "$tmp" -path '*/x64/d3d11.dll' | head -n 1)")"
  x32="$(dirname "$(find "$tmp" -path '*/x32/d3d11.dll' | head -n 1)")"
  if [[ ! -f "$x64/d3d11.dll" || ! -f "$x32/d3d11.dll" ]]; then
    rm -rf "$tmp"; warn "  $ASYNC_NAME has no x64/x32 DLLs: games keep plain DXVK 2.6.2"; return 0
  fi
  install -d -m 0755 "$ASYNC_DIR" && rm -rf "${ASYNC_DIR:?}/x64" "${ASYNC_DIR:?}/x32" \
    && cp -r "$x64" "$ASYNC_DIR/x64" && cp -r "$x32" "$ASYNC_DIR/x32" && chmod -R a+rX "$ASYNC_DIR" \
    || { rm -rf "$tmp" "$ASYNC_DIR"; warn "  couldn't install $ASYNC_NAME: games keep plain DXVK 2.6.2"; return 0; }
  rm -rf "$tmp"
  echo "  installed to $ASYNC_DIR"
}

# --- bottle-memtrim off (Oct 9) ------------------------------------------------------
# It kept the VM's file cache near 3 GB (memory.reclaim) and handed freed memory back to the Mac
# in 128 KB pieces (free page reporting order 5 instead of the kernel's 9). Within minutes of
# it starting, The Witcher 3 crashed on every launch, each time as the Mac side refused a GPU
# submission (virtio-gpu SUBMIT_3D, response 0x1200), where it had played for minutes before.
# Until that's understood it stays off, and the reporting order goes back to the default.
# Apple's M4 shows Linux its matrix extension (SME), and .NET programs then die at random with SIGILL
# (Oct 23: Ryujinx, a Flatpak, crashed on 1 launch in 3 on the dev Mac; 0 in 10 with SME off). Nothing
# in the bottle uses SME, so the kernel boots without it: arm64.nosme (takes effect at the next VM start).
sme_off() {
  command -v grubby >/dev/null || { echo "  no grubby here"; return 0; }
  if grubby --info=DEFAULT 2>/dev/null | grep -q "arm64.nosme"; then echo "  already off"; return 0; fi
  grubby --update-kernel=ALL --args="arm64.nosme" && echo "  SME off from the next VM start"
}

memtrim_off() {
  if [[ -f /etc/systemd/system/bottle-memtrim.service ]]; then
    systemctl disable --now bottle-memtrim.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/bottle-memtrim.service
    systemctl daemon-reload || true
    echo "  stopped"
  fi
  rm -f /usr/local/bin/bottle-memtrim
  local o=/sys/module/page_reporting/parameters/page_reporting_order
  if [[ -w "$o" && "$(cat "$o")" == 5 ]]; then
    echo 9 > "$o" && echo "  free page reporting back to order 9"
  fi
  return 0
}

# --- vkd3d-proton 3.0.1 cache (DirectX 12; bottle-dxvk puts it in place of Proton's) -------
vkd3d_cache() {
  if [[ -f "$VKD3D_DIR/x64/d3d12core.dll" && -f "$VKD3D_DIR/x86/d3d12core.dll" ]]; then
    echo "  already in $VKD3D_DIR"
    return 0
  fi
  command -v zstd >/dev/null || dnf install -y -q zstd >/dev/null 2>&1 || true
  local tmp; tmp="$(mktemp -d)"
  if ! curl -fsSL -o "$tmp/v.tar.zst" "$VKD3D_URL"; then
    rm -rf "$tmp"; warn "  couldn't download $VKD3D_URL: DirectX 12 games keep Proton's vkd3d-proton"; return 0
  fi
  if ! echo "$VKD3D_SHA256  $tmp/v.tar.zst" | sha256sum -c --quiet -; then
    rm -rf "$tmp"; warn "  checksum mismatch for $VKD3D_URL"; return 0
  fi
  if ! { zstd -dcq "$tmp/v.tar.zst" | tar -xf - -C "$tmp"; } \
     || [[ ! -f "$tmp/vkd3d-proton-$VKD3D_VER/x64/d3d12core.dll" ]]; then
    rm -rf "$tmp"; warn "  couldn't unpack vkd3d-proton $VKD3D_VER"; return 0
  fi
  install -d -m 0755 "$VKD3D_DIR" && rm -rf "${VKD3D_DIR:?}/x64" "${VKD3D_DIR:?}/x86" \
    && cp -r "$tmp/vkd3d-proton-$VKD3D_VER/x64" "$tmp/vkd3d-proton-$VKD3D_VER/x86" "$VKD3D_DIR/" \
    && chmod -R a+rX "$VKD3D_DIR" \
    || { rm -rf "$tmp" "$VKD3D_DIR"; warn "  couldn't install vkd3d-proton $VKD3D_VER"; return 0; }
  rm -rf "$tmp"
  echo "  installed to $VKD3D_DIR"
}

# --- Run everything ------------------------------------------------------------
step "Desktop packages (TigerVNC, keyboard tools)" desktop_packages
step "Bottle tools" tools
step "GOG downloader (gogdl) for bottle-stores" gogdl_install
step "Epic downloader (Legendary) for bottle-stores" legendary_install
step "Comet, the Galaxy sign-in for GOG games" comet_install
step "Desktop Mode settings (only if it is installed)" desktop_mode_settings
step "FEX's settings" fex_config
step "Sound server (silent output for games)" sound
step "Game controllers from the Mac" controllers
step "Libraries for the bottle's programs" runtime_libs
step "Screen server for the Mac app" screen_server
step "The Mac's GPU numbers for Steam's performance monitor" nvml_build
step "Desktop for the Mac app (Steam fills the window)" desktop_look
step "DXVK $DXVK_VER for Windows games" dxvk_cache
step "DXVK $DXVK_VER with asynchronous shader compiling (gplasync)" dxvk_async_cache
step "vkd3d-proton $VKD3D_VER for DirectX 12 games" vkd3d_cache
# (never fails the update: without the module, games just keep FEX's own ordering)
tso_build() { /usr/local/bin/bottle-tso build || warn "  the x86 ordering module couldn't be rebuilt; games keep FEX's own ordering"; return 0; }
step "x86 memory ordering in hardware (only while bottle tso is on)" tso_build
step "The file cache trimmer off (it came with crashes)" memtrim_off
step "Apple's SME off for the Linux kernel (.NET programs crashed with it)" sme_off
step "Present layer, arm64 build" env BOTTLE_SKIP_TESTS=1 bash "$HERE/present-layer/install.sh"
if [[ -d "$GUEST_ROOTFS/usr/lib64" ]]; then
  step "Mac-patched Venus driver for the x86 side (64- and 32-bit)" env BOTTLE_SKIP_PROBE=1 bash "$HERE/x86-venus.sh"
  step "Present layer, x86_64 and i386 builds (+ GPU probes)" bash "$HERE/present-layer/install-x86.sh"
else
  warn "No x86 rootfs at $GUEST_ROOTFS yet: skipping the x86 GPU driver and layer (run setup-guest.sh)."
  FAILED+=("x86 rootfs missing")
fi

# Onto the disk now: a VM stopped soon after an update lost what it hadn't written out yet.
sync

echo
if (( ${#FAILED[@]} )); then
  warn "Finished with problems in: ${FAILED[*]}"
  exit 1
fi
info "Guest is up to date."
