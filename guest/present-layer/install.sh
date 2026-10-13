#!/usr/bin/env bash
# Build + install VK_LAYER_BOTTLE_cpu_present into the bottle VM, then test it.
# Run as root (sudo) from the normal user: sudo bash install.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB=/usr/local/lib64/libVkLayer_bottle_present.so
MANIFEST=/etc/vulkan/implicit_layer.d/VkLayer_bottle_present.json
USER_NAME="${SUDO_USER:-$(id -un)}"
DISP="${DISPLAY_NUM:-1}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
# The kit's ready-made builds, or built here (../build-recipes.sh)
PB_SRC="$(cd "$HERE/.." && pwd)"
# shellcheck source=../build-recipes.sh
. "$PB_SRC/build-recipes.sh"

info "The layer…"
install -d /usr/local/lib64 /etc/vulkan/implicit_layer.d
# Made aside, then swapped in: overwriting a loaded .so in place can crash apps using it.
tmp_lib="$(mktemp)"
pb_get libVkLayer_bottle_present.so "$tmp_lib"
install -m 0755 "$tmp_lib" "$LIB"
rm -f "$tmp_lib"
sed "s#@LIBRARY_PATH@#$LIB#" "$HERE/VkLayer_bottle_present.json.in" > "$MANIFEST"
chmod 0644 "$MANIFEST"; chmod 0755 "$LIB"
info "Installed $LIB and $MANIFEST"

# Steam's interface on the Mac's GPU (bottle steam-gpu on) needs zink's own presenting kept on
# for Steam's web views: the kopper shim (bottle_kopper.c; steam-arm64 preloads and links it then).
SHIM=/usr/local/lib64/libbottle_kopper.so
tmp_lib="$(mktemp)"
pb_get libbottle_kopper.so "$tmp_lib"
install -m 0755 "$tmp_lib" "$SHIM"
rm -f "$tmp_lib"
info "Installed $SHIM"

# bottle-gltest: an OpenGL window like Steam's interface makes (bottle steam-gpu on checks with
# it). Optional: without it that check skips this part.
tmp_bin="$(mktemp)"
if pb_get bottle-gltest "$tmp_bin"; then
  install -m 0755 "$tmp_bin" /usr/local/bin/bottle-gltest
  info "Installed /usr/local/bin/bottle-gltest"
else
  echo "warning: couldn't build bottle-gltest (OpenGL headers missing?); bottle steam-gpu on checks without it" >&2
fi
rm -f "$tmp_bin"
[[ -n "${BOTTLE_SKIP_TESTS:-}" ]] && exit 0

run_as_user() { sudo -u "$USER_NAME" env DISPLAY=":$DISP" XDG_RUNTIME_DIR="/run/user/$(id -u "$USER_NAME")" "$@"; }
dnf install -y -q mesa-demos glx-utils vulkan-tools >/dev/null 2>&1 || true   # (vkcube, glxinfo, glxgears)

if [[ ! -S /tmp/.X11-unix/X$DISP ]]; then
  echo "Desktop :$DISP isn't running (run bottle-desktop), skipping the tests."
  exit 0
fi

echo
info "TEST 1: vkcube on the GPU for 15 s (watch the Screen Sharing window)"
# Log to a file first: piping into `head` would kill vkcube (SIGPIPE) after a few lines.
run_as_user env BOTTLE_PRESENT_DEBUG=1 timeout 15 vkcube > /tmp/bottle-vkcube.log 2>&1 || true
grep -E 'bottle-present|Selected GPU|rror' /tmp/bottle-vkcube.log | tail -12 || true

echo
info "TEST 2: OpenGL through zink (GL on top of Venus)"
echo "--- a) MESA_LOADER_DRIVER_OVERRIDE=zink"
run_as_user env MESA_LOADER_DRIVER_OVERRIDE=zink timeout 30 glxinfo -B 2>&1 \
  | grep -E 'OpenGL renderer|OpenGL version|rror|ZINK' | head -6 || true
echo "--- b) zink through kopper (works without DRI3, needs nullDescriptor on the GPU)"
run_as_user env LIBGL_KOPPER_DRI2=1 MESA_LOADER_DRIVER_OVERRIDE=zink \
  timeout 30 glxinfo -B 2>&1 | grep -E 'OpenGL renderer|OpenGL version|rror|ZINK' | head -6 || true

echo
info "TEST 3: glxgears through zink for 10 s (only meaningful if b) shows zink)"
run_as_user env LIBGL_KOPPER_DRI2=1 MESA_LOADER_DRIVER_OVERRIDE=zink BOTTLE_PRESENT_DEBUG=1 \
  timeout 10 glxgears > /tmp/bottle-gears.log 2>&1 || true
grep -E 'bottle-present|FPS|rror' /tmp/bottle-gears.log | tail -10 || true

echo
echo "Done. To turn the layer off for one app: DISABLE_BOTTLE_PRESENT=1 <app>"
echo "To remove it: sudo rm $MANIFEST $LIB"
