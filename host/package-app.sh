#!/usr/bin/env bash
# Package Portalistic.app for other Macs: the app with everything it runs inside it, signed with
# your Developer ID, so a Mac needs no Homebrew, Xcode, Vulkan SDK or Terminal:
#
#   Contents/MacOS/Portalistic        the app
#   Contents/Resources/kit/           the bottle command and the VM's side (host/bottle, guest/)
#   Contents/Helpers/bin/             limactl, krunkit, bottle-audio (the sound player)
#   Contents/Helpers/libexec/lima/    Lima's krunkit driver
#   Contents/Resources/share/krunkit/ the EFI firmware krunkit boots the VM with
#   Contents/Resources/share/lima/    Lima's guest agent (Lima looks for it in ../share/lima from
#                                     limactl: Contents/Helpers/share links there, since code
#                                     folders may hold only signed programs)
#   Contents/Frameworks/              libkrun, libkrunfw (the VM's Linux kernel), virglrenderer,
#                                     libepoxy, the Vulkan loader, KosmicKrisp
#   Contents/Resources/vulkan/icd.d/  KosmicKrisp's driver file for the Vulkan loader
#
# The pieces come from this Mac (what setup-host.sh installed: Homebrew's lima and krunkit, the
# Vulkan SDK's KosmicKrisp). Their Homebrew paths are rewritten to point inside the app, and every
# piece is signed with the hardened runtime; krunkit gets the hypervisor entitlement.
#
#   host/package-app.sh [--identity NAME] [--notarize PROFILE] [--no-zip]
#     --identity   signing identity (default: the first "Developer ID Application" in the keychain)
#     --notarize   send the zip to Apple's notary service with the notarytool keychain profile
#                  PROFILE (xcrun notarytool store-credentials PROFILE …, once), then staple it
# Output: build/Portalistic.app and build/Portalistic-<version>.zip in the kit (put together in
# ~/Library/Caches/Portalistic/package).
#
# Written for macOS's bash 3.2.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The app is put together outside the kit: in a folder iCloud Drive syncs (Documents, Desktop),
# files keep getting extended attributes, which a code signature doesn't allow. The finished
# app and zip are copied to the kit's build/ folder.
WORK="$HOME/Library/Caches/Portalistic/package"
OUT="$KIT/build"
APP="$WORK/Portalistic.app"
IDENTITY=""
NOTARY=""
ZIP=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --notarize) NOTARY="$2"; shift 2 ;;
    --no-zip)   ZIP=0; shift ;;
    *) echo "usage: host/package-app.sh [--identity NAME] [--notarize PROFILE] [--no-zip]" >&2; exit 2 ;;
  esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
# install_name_tool, quiet about the signature it voids (everything is signed again at the end)
int() { local out; out="$(install_name_tool "$@" 2>&1)" || { echo "$out" >&2; return 1; }; }

[[ "$(uname -m)" == arm64 ]] || die "Package on an Apple Silicon Mac."
command -v brew >/dev/null || die "Needs Homebrew's lima and krunkit (host/setup-host.sh installs them)."
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
  [[ -n "$IDENTITY" ]] || die "No Developer ID Application certificate in the keychain (or pass --identity)."
fi

# ---- the pieces on this Mac ----
LIMA="$(brew --prefix lima)"
LIMACTL="$LIMA/bin/limactl"
DRIVER="$LIMA/libexec/lima/lima-driver-krunkit"
AGENT="$LIMA/share/lima/lima-guestagent.Linux-aarch64.gz"
KRUNKIT="$(cd "$(brew --prefix krunkit)/bin" && pwd -P)/krunkit"
KRUNFW="$(brew --prefix libkrunfw)/lib/libkrunfw.5.dylib"
KRUNKIT_FW="$(brew --prefix krunkit)/share/krunkit/KRUN_EFI.silent.fd"
ICD_SRC="$(cat "$HOME/.config/steamos-bottle/kosmickrisp_icd" 2>/dev/null || true)"
[[ -f "$ICD_SRC" ]] || ICD_SRC="$(ls "$HOME"/VulkanSDK/*/macOS/share/vulkan/icd.d/libkosmickrisp_icd.json 2>/dev/null | tail -1)"
[[ -f "$ICD_SRC" ]] || die "No KosmicKrisp (host/kosmickrisp.sh enable installs it)."
KK="$(cd "$(dirname "$ICD_SRC")" && cd "$(dirname "$(sed -n 's/.*"library_path": *"\(.*\)".*/\1/p' "$ICD_SRC")")" && pwd -P)/libvulkan_kosmickrisp.dylib"
for f in "$LIMACTL" "$DRIVER" "$AGENT" "$KRUNKIT" "$KRUNFW" "$KRUNKIT_FW" "$KK"; do [[ -f "$f" ]] || die "Missing: $f"; done
# The VM's own programs go out ready-made (VMs have no build tools): built from today's sources?
PRE="$KIT/guest/prebuilt/aarch64"
[[ -f "$PRE/MANIFEST" ]] || die "No ready-made builds of the VM's programs: run bottle prebuild first."
stale=""
while read -r name hash; do
  [[ -f "$PRE/$name" ]] || { stale="$stale $name"; continue; }
  # (the sources, as guest/build-recipes.sh lists them)
  srcs="$(PB_SRC="$KIT/guest" bash -c '. "$PB_SRC/build-recipes.sh"; pb_sources "$1"' _ "$name")"
  now="$(for f in $srcs; do cat "$KIT/guest/$f"; done | shasum -a 1 | cut -c1-16)"
  [[ "$now" == "$hash" ]] || stale="$stale $name"
done < "$PRE/MANIFEST"
[[ -z "$stale" ]] || die "The ready-made builds are older than their sources:$stale. Run: bottle prebuild"
# The x86 side's builds are made outside the VM. The 32-bit layer records which bottle_present.c it was built from.
b32="$KIT/guest/present-layer/i386/BUILT"
want32="$(sed -n 's/.*(sha1 first 16: \([0-9a-f]*\)).*/\1/p' "$b32" 2>/dev/null | head -1)"
[[ -f "$KIT/guest/present-layer/i386/libVkLayer_bottle_present.so" && -n "$want32" ]] \
  || die "No 32-bit build of the Vulkan layer (guest/present-layer/i386): 32-bit games would not work. Run guest/present-layer/build-i386.sh"
[[ "$want32" == "$(shasum -a 1 "$KIT/guest/present-layer/bottle_present.c" | cut -c1-16)" ]] \
  || die "The 32-bit Vulkan layer build (guest/present-layer/i386) is older than bottle_present.c. Run guest/present-layer/build-i386.sh"
[[ -f "$KIT/guest/x86-venus/libvulkan_virtio.i686.so" && -f "$KIT/guest/x86-venus/MANIFEST" ]] \
  || die "No 32-bit Venus driver (guest/x86-venus): 32-bit games would not work."
[[ "$(awk '$1 == "libvulkan_virtio.i686.so" {print $2}' "$KIT/guest/x86-venus/MANIFEST")" == "$(shasum -a 256 "$KIT/guest/x86-venus/libvulkan_virtio.i686.so" | cut -d' ' -f1)" ]] \
  || die "guest/x86-venus/MANIFEST doesn't match libvulkan_virtio.i686.so."
# Comet (the Galaxy sign-in for GOG games) is built outside the VM too: its notices must travel with it.
for f in comet-aarch64 MANIFEST BUILT CRATES.tsv LICENSE-comet LICENSE-proto-cc0 THIRD-PARTY-LICENSES.txt; do
  [[ -f "$KIT/guest/comet/$f" ]] || die "guest/comet/$f is missing: GOG games that ask for the Galaxy client's sign-in would not work. Run guest/comet/build-aarch64.sh"
done
[[ "$(awk '$1 == "comet-aarch64" {print $2}' "$KIT/guest/comet/MANIFEST")" == "$(shasum -a 256 "$KIT/guest/comet/comet-aarch64" | cut -d' ' -f1)" ]] \
  || die "guest/comet/MANIFEST doesn't match comet-aarch64."
VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' "$KIT/host/xcode/Bottle.xcconfig")"
info "Packaging Portalistic $VERSION, signed as: $IDENTITY"
echo "  Lima $("$LIMACTL" --version | awk '{print $3}'), $("$KRUNKIT" --version 2>/dev/null | head -1), KosmicKrisp from $(dirname "$KK")"

# ---- the app itself (unsigned here; everything is signed at the end) ----
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
info "Building the app…"
xcodebuild -project "$KIT/host/Portalistic.xcodeproj" -target Portalistic -configuration Release \
  SYMROOT="$WORK/xcode" OBJROOT="$WORK/xcode/obj" BOTTLE_KIT_DIR= BOTTLE_PATH= \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >"$OUT/xcodebuild.log" 2>&1 \
  || { tail -20 "$OUT/xcodebuild.log"; die "The app didn't build (build/xcodebuild.log)."; }
ditto --norsrc --noextattr "$WORK/xcode/Release/Portalistic.app" "$APP"

C="$APP/Contents"
H="$C/Helpers"
FW="$C/Frameworks"
mkdir -p "$H/bin" "$H/libexec/lima" "$C/Resources/share/lima" "$FW" "$C/Resources/vulkan/icd.d" "$C/Resources/kit/host"
ln -s ../Resources/share "$H/share"

# ---- Lima (Go programs: nothing to relink) ----
cp "$LIMACTL" "$H/bin/limactl"
cp "$DRIVER" "$H/libexec/lima/lima-driver-krunkit"
cp "$AGENT" "$C/Resources/share/lima/"
chmod 755 "$H/bin/limactl" "$H/libexec/lima/lima-driver-krunkit"

# ---- krunkit and the libraries it loads, pointed at Contents/Frameworks ----
cp "$KRUNKIT" "$H/bin/krunkit"
chmod 755 "$H/bin/krunkit"
copy_deps() {  # the non-system libraries $1 links to, into Frameworks (recursively)
  local dep base
  for dep in $(otool -L "$1" | awk 'NR > 1 {print $1}' | grep -E '^(/opt/homebrew|/usr/local)/' || true); do
    base="${dep##*/}"
    [[ -f "$FW/$base" ]] && continue
    cp -L "$dep" "$FW/$base"
    chmod 644 "$FW/$base"
    copy_deps "$FW/$base"
  done
}
copy_deps "$H/bin/krunkit"
# libkrun opens the VM's kernel, libkrunfw, by bare name ("libkrunfw.5.dylib") when a VM starts;
# dyld finds bare names through the program's rpath too (krunkit's: Contents/Frameworks).
cp -L "$KRUNFW" "$FW/libkrunfw.5.dylib"
# krunkit boots the VM through EFI firmware it looks for at ../share/krunkit/ from its own folder
# ("can't find a firmware to load" without it)
mkdir -p "$C/Resources/share/krunkit"
cp "$KRUNKIT_FW" "$C/Resources/share/krunkit/"
cp -L "$KK" "$FW/libvulkan_kosmickrisp.dylib"
chmod 644 "$FW"/*.dylib
relink() {  # $1 = binary, $2 = the rpath to give it
  local dep rp
  for dep in $(otool -L "$1" | awk 'NR > 1 {print $1}' | grep -E '^(/opt/homebrew|/usr/local)/' || true); do
    int -change "$dep" "@rpath/${dep##*/}" "$1"
  done
  for rp in $(otool -l "$1" | awk '/LC_RPATH/ {getline; getline; print $2}'); do
    int -delete_rpath "$rp" "$1" || true
  done
  int -add_rpath "$2" "$1"
}
relink "$H/bin/krunkit" "@executable_path/../../Frameworks"
for f in "$FW"/*.dylib; do
  int -id "@rpath/${f##*/}" "$f"
  relink "$f" "@loader_path"
done
left="$(for f in "$H/bin/krunkit" "$FW"/*.dylib; do otool -L "$f" | awk 'NR > 1 {print $1}'; done | grep -E '^(/opt/homebrew|/usr/local)/' || true)"
[[ -z "$left" ]] || die "Still linked to Homebrew: $left"
cat > "$C/Resources/vulkan/icd.d/kosmickrisp_icd.json" <<'EOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "../../../Frameworks/libvulkan_kosmickrisp.dylib",
        "api_version": "1.4.0"
    }
}
EOF

# ---- the sound player, built here (the app's users have no Swift compiler) ----
swiftc -O -target arm64-apple-macosx13.0 -o "$H/bin/bottle-audio" "$KIT/host/bottle-audio.swift" >"$OUT/audio-build.log" 2>&1 \
  || die "The sound player didn't build (build/audio-build.log)."

# ---- the kit: the bottle command and the VM's side (not the kit's tests or build files) ----
cp "$KIT/host/bottle" "$KIT/host/bottle-fexfix.py" "$C/Resources/kit/host/"
# where the app gets its Linux system on first launch (host/build-image.sh writes it)
if [[ -f "$KIT/host/image.env" ]]; then cp "$KIT/host/image.env" "$C/Resources/kit/host/"
else echo "  (no host/image.env yet: this app can't set up a new Mac; host/build-image.sh makes one)"; fi
chmod 755 "$C/Resources/kit/host/bottle"
COPYFILE_DISABLE=1 tar -C "$KIT" --exclude .DS_Store --exclude __pycache__ --exclude 'guest/tests' \
    --exclude 'guest/prebuilt/aarch64.new' -cf - guest \
  | tar -C "$C/Resources/kit" -xf -
echo "$VERSION" > "$C/Resources/kit/VERSION"
# notices for what the app carries (LICENSES.md in the kit)
[[ -f "$KIT/LICENSES.md" ]] && cp "$KIT/LICENSES.md" "$C/Resources/"

# ---- signing: inside out, hardened runtime, secure timestamp ----
info "Signing…"
ENT="$WORK/krunkit.entitlements"
cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.hypervisor</key>
	<true/>
</dict>
</plist>
EOF
# (extended attributes, e.g. Finder info or where a file was downloaded from, aren't allowed in a
# signed bundle)
xattr -cr "$APP"
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@" 2>&1 | grep -v "replacing existing signature" || true; }
for f in "$FW"/*.dylib; do sign "$f"; done
sign "$H/bin/limactl" "$H/libexec/lima/lima-driver-krunkit" "$H/bin/bottle-audio"
sign --entitlements "$ENT" "$H/bin/krunkit"
sign "$APP"
codesign --verify --deep --strict "$APP" || die "The signature doesn't verify."
du -sh "$APP" | awk '{print "  app: " $1}'

if (( ZIP )); then
  ZIPF="$WORK/Portalistic-$VERSION.zip"
  rm -f "$ZIPF"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIPF"
  if [[ -n "$NOTARY" ]]; then
    info "Notarizing (Apple checks it; a few minutes)…"
    xcrun notarytool submit "$ZIPF" --keychain-profile "$NOTARY" --wait | tee "$OUT/notarize.log"
    grep -q "status: Accepted" "$OUT/notarize.log" || die "Apple didn't accept it (build/notarize.log; xcrun notarytool log <id> --keychain-profile $NOTARY)."
    xcrun stapler staple "$APP"
    rm -f "$ZIPF"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIPF"
  fi
  cp -f "$ZIPF" "$OUT/"
  ls -lh "$OUT/${ZIPF##*/}" | awk '{print "  zip: " $5 "  " $NF}'
fi
rm -rf "$OUT/Portalistic.app"
ditto "$APP" "$OUT/Portalistic.app"   # (a copy to look at; the zip is what goes out)
info "Done: $OUT/Portalistic.app"
