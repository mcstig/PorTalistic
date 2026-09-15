#!/bin/bash
#
#  build-dxmt-wine.sh
#  PorTalistic
#
#  Created by Claude Opus 5 on 15/9/2026.
#  Copyright © 2026 Michael Stoian
#
#  Builds a Wine that DXMT can actually present through, because no shipped one does.
#
#  Run it on macOS, from anywhere:
#
#      bash Compatibility/build-dxmt-wine.sh
#
#  It is resumable: every stage skips itself if its output is already there, so a failed
#  run can be re-run without starting over. `--clean` throws the work tree away first.
#
#  ── Why this exists ───────────────────────────────────────────────────────────────────
#
#  DXMT needs two halves. `winemetal.so` issues the Metal commands, and something has to
#  hand a Wine window's swap chain a CAMetalLayer to present into. Stock winemac.drv does
#  not: DXMT's prebuilt release dropped into Gcenx's Wine Stable 11 creates a device
#  happily and then fails every swap chain with EGL_BAD_ALLOC — tried, on this machine,
#  and written up in RuntimeSelection.swift. Sikarugir's engine has the hooks but cannot
#  boot a prefix here at all. So: patch the driver, build the Wine.
#
#  ── Licensing ─────────────────────────────────────────────────────────────────────────
#
#  Wine is LGPL-2.1+ and aquadran's patch is compatible with it. Nothing here touches
#  Apple's Game Porting Toolkit or D3DMetal, whose licence is non-commercial only, or any
#  CrossOver binary. If the result is published, the corresponding source has to be
#  published with it — which is what pinning the tarball and vendoring the patch is for.

set -euo pipefail

WINE_VERSION="11.16"
WINE_SHA256="c66e2090343dcd727f7f7fd2f87ee0bfb0b118790c1d745ab7b8a4c3a4197f2f"

# Aquadran's winemac.drv patch, by way of macgameport/cities-skylines-2-macos. Pinned by
# digest: it is fetched once, verified, and kept in the repository so the next build and
# anyone reading it get the same bytes.
PATCH_SHA256="f470d52d3deac16f2f210e32f914b6190ceb2218deae86c8078edb2d31494130"
PATCH_URL="https://raw.githubusercontent.com/macgameport/cities-skylines-2-macos/main/scripts/wineandaqua-dxmt.patch"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$REPO/Compatibility/patches/wineandaqua-dxmt.patch"

WORK="$HOME/Games/wine-dxmt-build"
SRC="$WORK/wine-$WINE_VERSION"
PREFIX="$WORK/out/wine-dxmt-$WINE_VERSION"
DIST="$WORK/dist"

BREW_DEPS=(mingw-w64 bison pkgconf freetype gnutls make)

say()  { printf '\n\033[1;35m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ "${1:-}" == "--clean" ]] && { say "Removing $WORK"; rm -rf "$WORK"; }

# ── Preflight ────────────────────────────────────────────────────────────────────────────
say "Checking what's here"

[[ "$(uname -s)" == "Darwin" ]] || die "This has to run on macOS. (uname says $(uname -s).)"
ok "macOS $(sw_vers -productVersion) ($(uname -m))"

xcode-select -p >/dev/null 2>&1 || die "Xcode command line tools missing. Run: xcode-select --install"
ok "command line tools at $(xcode-select -p)"

command -v brew >/dev/null 2>&1 || die "Homebrew missing. See https://brew.sh"
BREW_PREFIX="$(brew --prefix)"
ok "homebrew at $BREW_PREFIX"

missing=()
for dep in "${BREW_DEPS[@]}"; do
    brew list --versions "$dep" >/dev/null 2>&1 || missing+=("$dep")
done

if (( ${#missing[@]} )); then
    warn "missing: ${missing[*]}"
    say "Installing them"
    brew install "${missing[@]}"
else
    ok "build dependencies present"
fi

# Wine's build wants GNU make and a bison newer than the one macOS ships, and Homebrew
# keeps both off the default PATH.
export PATH="$BREW_PREFIX/opt/bison/bin:$BREW_PREFIX/opt/make/libexec/gnubin:$PATH"
command -v x86_64-w64-mingw32-gcc >/dev/null || die "x86_64-w64-mingw32-gcc not on PATH after installing mingw-w64."
command -v i686-w64-mingw32-gcc   >/dev/null || die "i686-w64-mingw32-gcc not on PATH after installing mingw-w64."
ok "mingw-w64 cross compilers found"
ok "bison $(bison --version | head -1 | awk '{print $NF}')"

free_gb=$(df -g "$HOME" | awk 'NR==2{print $4}')
(( free_gb >= 12 )) || die "Only ${free_gb}GB free in $HOME; the build needs about 12GB."
ok "${free_gb}GB free"

mkdir -p "$WORK" "$DIST" "$(dirname "$PATCH")"

# ── The patch ────────────────────────────────────────────────────────────────────────────
say "Getting the winemac.drv patch"

verify() { [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$2" ]]; }

if [[ -f "$PATCH" ]] && verify "$PATCH" "$PATCH_SHA256"; then
    ok "already vendored at Compatibility/patches/"
else
    curl -fL --retry 3 -o "$PATCH.tmp" "$PATCH_URL"
    verify "$PATCH.tmp" "$PATCH_SHA256" \
        || die "patch digest mismatch — got $(shasum -a 256 "$PATCH.tmp" | awk '{print $1}'), expected $PATCH_SHA256"
    mv "$PATCH.tmp" "$PATCH"
    ok "fetched and verified; commit Compatibility/patches/ so the build is reproducible"
fi

# ── Source ───────────────────────────────────────────────────────────────────────────────
say "Getting Wine $WINE_VERSION"

TARBALL="$WORK/wine-$WINE_VERSION.tar.xz"
if [[ -f "$TARBALL" ]] && verify "$TARBALL" "$WINE_SHA256"; then
    ok "tarball already here and verified"
else
    curl -fL --retry 3 -o "$TARBALL" \
        "https://dl.winehq.org/wine/source/${WINE_VERSION%.*}.x/wine-$WINE_VERSION.tar.xz"
    verify "$TARBALL" "$WINE_SHA256" \
        || die "Wine tarball digest mismatch — got $(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    ok "downloaded and verified"
fi

if [[ -f "$SRC/.dxmt-patched" ]]; then
    ok "source already unpacked and patched"
else
    rm -rf "$SRC"
    tar -xJf "$TARBALL" -C "$WORK"
    ( cd "$SRC" && patch -p1 --forward < "$PATCH" )
    touch "$SRC/.dxmt-patched"
    ok "unpacked and patched"
fi

# ── Configure and build ──────────────────────────────────────────────────────────────────
say "Configuring"

# The whole thing has to be x86_64, including the unix side, and that is not the default on
# an Apple Silicon Mac.
#
# Two reasons, and either one alone decides it. DXMT ships `winemetal.so` as x86_64, and a
# unix library cannot load into a Wine whose unix side is arm64. And both builds that work
# on this machine — Gcenx's and Sikarugir's — are x86_64-only, running under Rosetta, so
# that is the configuration with any evidence behind it.
#
# The first attempt left this out and built an arm64 unix side. `dxmt_objc.h` wraps
# everything it declares in `#if defined(__x86_64__)`, so on arm64 the patch compiled to
# nothing and `cocoa_window.m` failed on `use of undeclared identifier 'WineMetalLayer'`.
# The guard was right and the build was wrong.
export CC="clang -arch x86_64"
export CXX="clang++ -arch x86_64"
export CFLAGS="-O2 -g"
export CXXFLAGS="$CFLAGS"
export LDFLAGS=""

# Deliberately *not* pointed at Homebrew. `$BREW_PREFIX` is arm64, and linking an x86_64
# Wine against arm64 libraries fails at the first link. Getting x86_64 freetype and gnutls
# means a second Homebrew under /usr/local installed through Rosetta, which is a big thing
# to do to a machine for an experiment — so the experiment goes without them, and a build
# meant for release gets them properly.
#
# What that costs: no font rendering inside Wine, and no TLS for Windows apps. Neither is
# in the way of the question being asked, which is whether a Direct3D 11 swap chain can
# present through this driver at all.
WITHOUT_DEPS=(--without-freetype --without-gnutls)
unset PKG_CONFIG_PATH

BUILD="$WORK/build"
mkdir -p "$BUILD"

# The first run's build directory is configured for arm64 and reusing it would repeat the
# failure, so it goes when the architecture it was configured for isn't the one we want.
if [[ -f "$BUILD/Makefile" && ! -f "$BUILD/.configured-x86_64" ]]; then
    warn "existing build directory was configured for another architecture; starting it over"
    rm -rf "$BUILD"
    mkdir -p "$BUILD"
fi

if [[ -f "$BUILD/Makefile" ]]; then
    ok "already configured (delete $BUILD to redo)"
else
    (
        cd "$BUILD"
        # i386 as well as x86_64: a 32-bit PE path is most of the older library, and the
        # engines that work here have one. DXMT itself is 64-bit only.
        "$SRC/configure" \
            --prefix="$PREFIX" \
            --host=x86_64-apple-darwin \
            --enable-archs=i386,x86_64 \
            --disable-tests \
            "${WITHOUT_DEPS[@]}" \
            --without-oss \
            --without-v4l2
    ) || die "configure failed — the tail of $BUILD/config.log says why"
    touch "$BUILD/.configured-x86_64"
    ok "configured for x86_64"
fi

say "Building (this is the hour)"
make -C "$BUILD" -j"$(sysctl -n hw.ncpu)" || die "build failed"
ok "built"

say "Installing to $PREFIX"
rm -rf "$PREFIX"
make -C "$BUILD" install >/dev/null
ok "installed"

# ── Sanity ───────────────────────────────────────────────────────────────────────────────
say "Checking what came out"

[[ -x "$PREFIX/bin/wine" ]] || die "no bin/wine in the output"
[[ -d "$PREFIX/lib/wine/x86_64-unix" ]] || die "no lib/wine/x86_64-unix in the output"
[[ -f "$PREFIX/lib/wine/x86_64-unix/winemac.so" ]] || die "winemac.so missing — the patch may not have applied"

ok "$("$PREFIX/bin/wine" --version 2>/dev/null || echo 'wine --version failed')"

ARCHS="$(lipo -archs "$PREFIX/lib/wine/x86_64-unix/winemac.so" 2>/dev/null || echo unknown)"
if [[ "$ARCHS" == *x86_64* ]]; then
    ok "winemac.so is $ARCHS"
else
    die "winemac.so is $ARCHS, not x86_64 — DXMT's winemetal.so could not load into it"
fi

# The patch's whole purpose: these have to be visible in the driver, not hidden.
if nm -gU "$PREFIX/lib/wine/x86_64-unix/winemac.so" 2>/dev/null | grep -q dxmt_client_surface; then
    ok "winemac.so exports the DXMT client-surface hooks"
else
    warn "couldn't see the DXMT hooks exported from winemac.so — worth a look before trusting it"
fi

# A marker, so PorTalistic can tell this build apart from a stock one.
echo "wine-$WINE_VERSION + aquadran winemac.drv DXMT patch ($PATCH_SHA256)" > "$PREFIX/dxmt_clientsurface"

# ── Package ──────────────────────────────────────────────────────────────────────────────
say "Packaging"

NAME="wine-dxmt-$WINE_VERSION"
TAR="$DIST/$NAME.tar.xz"
rm -f "$TAR"
( cd "$(dirname "$PREFIX")" && tar -cJf "$TAR" "$(basename "$PREFIX")" )
DIGEST="$(shasum -a 256 "$TAR" | awk '{print $1}')"

cat <<REPORT

$(printf '\033[1;32m━━ done ━━\033[0m')

  build    $PREFIX
  tarball  $TAR
  size     $(du -h "$TAR" | awk '{print $1}')
  sha256   $DIGEST

Next, in this order:

  1. Point PorTalistic at it locally and let it install DXMT on top:
       Settings ▸ Services ▸ Wine Runtimes, or just launch a Direct3D 11 game once
       the manifest entry below is in place.

  2. Manifest entry — add to Compatibility/manifest.json under "runtimes", then
     re-sign with: swift Compatibility/sign-manifest.swift

       {
         "id": "wine-dxmt-$WINE_VERSION",
         "name": "Wine $WINE_VERSION (DXMT)",
         "version": "$WINE_VERSION.0",
         "downloadURL": "https://github.com/mcstig/PorTalistic/releases/download/<tag>/$NAME.tar.xz",
         "sha256": "$DIGEST",
         "payloadSubpath": "$(basename "$PREFIX")",
         "executableSubpath": "bin/wine",
         "exposesMetalEscapes": true,
         "summary": "Wine $WINE_VERSION built from winehq source with aquadran's winemac.drv patch, so DXMT has a CAMetalLayer to present into. Built here rather than downloaded: no shipped build has both a working prefix and the Metal hooks."
       }

  3. If device creation works but swap chains still fail, the prebuilt DXMT release was
     compiled against a different Wine. Then DXMT has to be built against *this* one —
     it takes -Dwine_install_path=$PREFIX — and that is stage two.

REPORT
