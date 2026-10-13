#!/usr/bin/env bash
# Build Portalistic's ready-made Linux image, the one the app downloads on its first launch
# (bottle setup) instead of building a VM on each Mac:
#
#   1. a Fedora VM (Lima's fedora template, user "deck") set up by the kit's guest scripts, with
#      the kit's ready-made builds of the VM's programs (bottle prebuild), so it needs no compilers;
#   2. slimmed and sealed by guest/image-seal.sh (no build tools, no second copy of the x86
#      system, no docs or caches, no user, Steam not yet installed), which powers it off;
#   3. its disk packed as a compressed qcow2 (Lima turns that into the VM's disk on the user's Mac).
#
#   host/build-image.sh [--keep]   on the development Mac; 20-40 minutes, mostly downloads
#     --keep  keep the image VM (portalistic-image) afterwards, to look inside
#
# Output: build/image/portalistic-linux-<version>.qcow2, its .sha256, parts under 2 GB for
# GitHub Releases (.part-aa, -ab…), its packages list (.packages.txt, for LICENSES.md), and
# host/image.env: what bottle setup downloads and checks.
# Needs Homebrew's lima and krunkit with KosmicKrisp (setup-host.sh), and the bottle's own VM
# running: it packs the image with qemu-img, which macOS doesn't have.
#
# Written for macOS's bash 3.2.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME=portalistic-image
BOTTLE_VM="${VM_NAME:-steamos-bottle}"
OUTDIR="$KIT/build/image"
KEEP=0
PACK_ONLY=0
for a in "$@"; do
  case "$a" in
    --keep) KEEP=1 ;;
    --pack) PACK_ONLY=1 ;;   # only pack an image VM that's already sealed (after a stop midway)
    *) echo "usage: host/build-image.sh [--keep] [--pack]" >&2; exit 2 ;;
  esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
SECONDS=0

command -v limactl >/dev/null || die "Needs Lima (host/setup-host.sh)."
[[ "$(limactl list --format '{{.Status}}' "$BOTTLE_VM" 2>/dev/null)" == Running ]] \
  || die "Start the bottle's VM first (bottle start): it packs the image."
[[ -f "$KIT/guest/prebuilt/aarch64/MANIFEST" ]] || die "No ready-made builds of the VM's programs: run bottle prebuild first."
VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' "$KIT/host/xcode/Bottle.xcconfig")"
IMG="portalistic-linux-$VERSION"
ICD="$(cat "$HOME/.config/steamos-bottle/kosmickrisp_icd" 2>/dev/null || true)"
[[ -f "$ICD" ]] || die "No KosmicKrisp (host/kosmickrisp.sh enable): the setup needs the VM's GPU."
mkdir -p "$OUTDIR"

vi() { limactl shell --workdir / "$NAME" "$@"; }
if (( ! PACK_ONLY )); then
if limactl list -q 2>/dev/null | grep -qx "$NAME"; then
  info "Removing the previous image VM…"
  limactl delete --force "$NAME" >/dev/null
fi

info "Creating the image VM (Fedora, 12 GB disk; it grows on each Mac)…"
limactl create --name="$NAME" --vm-type=krunkit --cpus=6 --memory=8 --disk=12 \
  --set '.user.name = "deck" | .user.home = "/home/deck" | .mounts = [] | .ssh.loadDotSSHPubKeys = false' \
  --tty=false template:fedora >/dev/null
info "Starting it…"
VK_DRIVER_FILES="$ICD" VK_ICD_FILENAMES="$ICD" limactl start "$NAME" >/dev/null 2>&1 \
  || die "The image VM didn't start (limactl start $NAME shows why)."

info "Setting it up with the kit's guest scripts (most of the time goes here)…"
COPYFILE_DISABLE=1 tar -C "$KIT" --exclude __pycache__ --exclude .DS_Store --exclude guest/tests \
    --exclude guest/prebuilt/aarch64.new -czf - guest \
  | vi bash -c 'rm -rf /tmp/kit && mkdir -p /tmp/kit && tar -xzf - -C /tmp/kit'
if ! vi sudo BOTTLE_SKIP_PROBE=1 BOTTLE_SKIP_TESTS=1 bash /tmp/kit/guest/setup-guest.sh > "$OUTDIR/setup.log" 2>&1; then
  tail -n 15 "$OUTDIR/setup.log"
  die "The setup finished with problems (build/image/setup.log)."
fi
grep -E "ready-made|built here" "$OUTDIR/setup.log" | sed 's/^/ /'
if grep -q "built here" "$OUTDIR/setup.log"; then
  die "Something was compiled in the image (its ready-made build is older than its sources): bottle prebuild, then again."
fi

# what's in it (for LICENSES.md's source pointers; a little more than the image keeps)
vi rpm -qa --qf '%{NAME} %{EPOCH}:%{VERSION}-%{RELEASE} %{ARCH} %{LICENSE}\n' | sed 's/ (none):/ /' | sort > "$OUTDIR/$IMG.packages.txt"
info "Slimming and sealing it (it powers off)…"
# (the seal ends this ssh session when it removes the build user: not a failure)
vi sudo bash /tmp/kit/guest/image-seal.sh 2>&1 | sed 's/^/  /' || true
fi
for _ in $(seq 1 60); do
  pgrep -f "krunkit.*\.lima/$NAME/" >/dev/null || break
  sleep 5
done
pgrep -f "krunkit.*\.lima/$NAME/" >/dev/null && die "The image VM didn't power off."
limactl stop --force "$NAME" >/dev/null 2>&1 || true

DISK="$HOME/.lima/$NAME/disk"
info "Packing the disk ($(( $(stat -f %b "$DISK") / 2048 )) MB in use) as a compressed qcow2, in the bottle's VM…"
limactl shell --workdir / "$BOTTLE_VM" bash -c 'command -v qemu-img >/dev/null || sudo -n dnf install -y -q qemu-img >/dev/null'
# (the bottle's VM sees the Mac's home folder read-only, at the same path)
limactl shell --workdir / "$BOTTLE_VM" bash -c \
  'qemu-img convert -c -O qcow2 -o compression_type=zlib,cluster_size=65536 "$1" /var/tmp/portalistic-image.qcow2' _ "$DISK" \
  || die "qemu-img couldn't pack the disk."
rm -f "$OUTDIR/$IMG.qcow2" "$OUTDIR/$IMG.qcow2".part-*
limactl shell --workdir / "$BOTTLE_VM" bash -c 'cat /var/tmp/portalistic-image.qcow2 && rm -f /var/tmp/portalistic-image.qcow2' > "$OUTDIR/$IMG.qcow2"

SIZE="$(stat -f %z "$OUTDIR/$IMG.qcow2")"
SHA="$(shasum -a 256 "$OUTDIR/$IMG.qcow2" | cut -d' ' -f1)"
echo "$SHA  $IMG.qcow2" > "$OUTDIR/$IMG.qcow2.sha256"
# GitHub Releases takes files up to 2 GiB: parts of 1900 MB (bottle setup joins them again)
PARTS=""
if (( SIZE > 1900 * 1024 * 1024 )); then
  ( cd "$OUTDIR" && split -b 1900m "$IMG.qcow2" "$IMG.qcow2.part-" )
  PARTS="$(cd "$OUTDIR" && ls "$IMG.qcow2".part-* | tr '\n' ' ' | sed 's/ $//')"
fi
cat > "$KIT/host/image.env" <<EOF
# Portalistic's ready-made Linux image (host/build-image.sh wrote this; bottle setup reads it).
# PORTALISTIC_IMAGE_URL: where its files are (a GitHub release), set when it's published.
PORTALISTIC_IMAGE_VERSION=$VERSION
PORTALISTIC_IMAGE_FILE=$IMG.qcow2
PORTALISTIC_IMAGE_SIZE=$SIZE
PORTALISTIC_IMAGE_SHA256=$SHA
PORTALISTIC_IMAGE_PARTS="$PARTS"
PORTALISTIC_IMAGE_URL=${PORTALISTIC_IMAGE_URL:-}
EOF

(( KEEP )) || limactl delete --force "$NAME" >/dev/null
info "Done in $(( SECONDS / 60 )) min: $OUTDIR/$IMG.qcow2 ($(( SIZE / 1048576 )) MB)${PARTS:+, in parts: $PARTS}"
