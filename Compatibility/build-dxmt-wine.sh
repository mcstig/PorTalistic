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

BREW_DEPS=(mingw-w64 bison pkgconf make)

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

# ── x86_64 freetype ──────────────────────────────────────────────────────────────────────
say "Building x86_64 freetype"

# Without freetype Wine rasterizes no glyphs at all, which for most games means menus with
# no text in them. The obstacle is that `$BREW_PREFIX` is arm64 and an x86_64 Wine cannot
# link against it.
#
# Homebrew's own x86_64 bottles were the first plan and are not a plan any more. Homebrew
# has stopped building them for current formula versions — freetype's current version
# exists only as `arm64_tahoe` — so there is nothing to unpack under any macOS tag, and no
# reason to expect that to come back.
#
# freetype builds from source in about a minute with nothing but clang, so it is built here
# instead. Every optional dependency is off: PNG is only for colour-bitmap emoji glyphs,
# harfbuzz only improves autohinting, brotli only unpacks WOFF2 web fonts. Wine wants none
# of them. zlib comes from the SDK, which is universal.
#
# The install name is rewritten to a bare leaf name, which makes dyld resolve it through
# `DYLD_FALLBACK_LIBRARY_PATH` — and that is exactly what PorTalistic sets to a runtime's
# `Frameworks` directory, where the packaging stage below puts this dylib. It is also how
# the Sikarugir engines are arranged, which is the one arrangement known to work with this
# app. Rewriting an install name invalidates the signature, so it is re-signed.
#
# gnutls is not built. It would drag in nettle, gmp, libtasn1, libidn2, libunistring and
# p11-kit, and all it buys is TLS for Windows code running *inside* the prefix — which a
# game does not use, because the store client and the launcher both live outside it.

FT_VERSION="2.14.3"
# From Homebrew's own freetype formula.
FT_SHA256="36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f"

DEPS="$WORK/deps"
DEPPREFIX="$DEPS/prefix"
FT_SRC="$DEPS/freetype-$FT_VERSION"

# Not negotiable, and declared here rather than at `configure` so it sits next to why.
WITHOUT_GNUTLS="--without-gnutls"

if [[ -f "$DEPS/.ready" ]]; then
    ok "already built (delete $DEPS to redo)"
else
    mkdir -p "$DEPS"

    FT_TARBALL="$DEPS/freetype-$FT_VERSION.tar.xz"
    if [[ -f "$FT_TARBALL" ]] && verify "$FT_TARBALL" "$FT_SHA256"; then
        ok "tarball already here and verified"
    else
        # SourceForge is the download Homebrew uses; Savannah is upstream's own.
        curl -fL --retry 3 -o "$FT_TARBALL" \
            "https://downloads.sourceforge.net/project/freetype/freetype2/$FT_VERSION/freetype-$FT_VERSION.tar.xz" \
        || curl -fL --retry 3 -o "$FT_TARBALL" \
            "https://download.savannah.gnu.org/releases/freetype/freetype-$FT_VERSION.tar.xz"
        verify "$FT_TARBALL" "$FT_SHA256" \
            || die "freetype digest mismatch — got $(shasum -a 256 "$FT_TARBALL" | awk '{print $1}'), expected $FT_SHA256"
        ok "downloaded and verified"
    fi

    rm -rf "$FT_SRC" "$DEPPREFIX"
    mkdir -p "$DEPPREFIX"
    tar -xJf "$FT_TARBALL" -C "$DEPS"
    [[ -x "$FT_SRC/configure" ]] || die "freetype tarball did not unpack to $FT_SRC"

    (
        cd "$FT_SRC"
        CC="clang -arch x86_64" \
        CXX="clang++ -arch x86_64" \
        CFLAGS="-O2" \
        ./configure \
            --prefix="$DEPPREFIX" \
            --host=x86_64-apple-darwin \
            --enable-shared \
            --disable-static \
            --with-zlib=yes \
            --with-bzip2=no \
            --with-png=no \
            --with-harfbuzz=no \
            --with-brotli=no \
            >"$DEPS/freetype-configure.log" 2>&1
        make -j"$(sysctl -n hw.ncpu)" >"$DEPS/freetype-build.log" 2>&1
        make install >>"$DEPS/freetype-build.log" 2>&1
    ) || die "freetype build failed — the tail of $DEPS/freetype-configure.log and $DEPS/freetype-build.log says why"

    FT_DYLIB="$(find "$DEPPREFIX/lib" -maxdepth 1 -name 'libfreetype*.dylib' -not -type l | head -1)"
    [[ -n "$FT_DYLIB" ]] || die "freetype built but installed no dylib into $DEPPREFIX/lib"

    FT_ARCHS="$(lipo -archs "$FT_DYLIB" 2>/dev/null || echo unknown)"
    [[ "$FT_ARCHS" == *x86_64* ]] \
        || die "the freetype that came out is $FT_ARCHS, not x86_64 — Wine would fail at the first link"

    install_name_tool -id "$(basename "$FT_DYLIB")" "$FT_DYLIB" 2>/dev/null
    codesign --force --sign - "$FT_DYLIB" 2>/dev/null

    [[ -f "$DEPPREFIX/lib/pkgconfig/freetype2.pc" ]] \
        || die "no freetype2.pc in $DEPPREFIX/lib/pkgconfig — Wine's configure finds freetype through pkg-config"

    ok "freetype $FT_VERSION ($FT_ARCHS)"
    warn "no gnutls: Windows code inside the prefix gets no TLS; games don't use it"
    touch "$DEPS/.ready"
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
export CFLAGS="-O2 -g -I$DEPPREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$DEPPREFIX/lib"

# The freetype built above, never `$BREW_PREFIX` — that one is arm64, and linking an x86_64
# Wine against it fails at the first link. Listed first so it wins over pkgconf's defaults,
# which do include Homebrew's arm64 `.pc` files.
export PKG_CONFIG_PATH="$DEPPREFIX/lib/pkgconfig"

BUILD="$WORK/build"
mkdir -p "$BUILD"

# A build directory configured by an older version of this script is not reusable: the
# first run's was arm64, and the ones after it had no freetype, so their Makefiles would
# quietly produce a Wine with no glyph rasterizer. The marker changes whenever the answer
# changes, and a directory without the current one is thrown away.
if [[ -f "$BUILD/Makefile" && ! -f "$BUILD/.configured-x86_64-freetype" ]]; then
    warn "build directory was configured by an older version of this script; starting it over"
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
            $WITHOUT_GNUTLS \
            --without-oss \
            --without-v4l2
    ) || die "configure failed — the tail of $BUILD/config.log says why"
    touch "$BUILD/.configured-x86_64-freetype"
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

# Whether the patch's code is actually in the driver.
#
# Not `nm -gU`: winemac.drv is built with -fvisibility=hidden, so none of this is a global
# symbol and the first version of this check cried wolf on a good build. DXMT reaches these
# through Wine's own client-surface plumbing rather than by dlsym, so hidden is correct.
missing_markers=()
for marker in WineMetalLayer dxmt_client_surface CLIENT_SURFACE_PRESENTED; do
    grep -qa "$marker" "$PREFIX/lib/wine/x86_64-unix/winemac.so" || missing_markers+=("$marker")
done

if (( ${#missing_markers[@]} == 0 )); then
    ok "the DXMT hooks are compiled into winemac.so"
else
    die "winemac.so is missing ${missing_markers[*]} — the patch didn't take"
fi

# The dylibs travel with the runtime. `Frameworks` is not an arbitrary name:
# `RuntimeInstaller.supportLibrariesDirectoryName` is "Frameworks", and
# `Wine.transformProcess` puts that directory on `DYLD_FALLBACK_LIBRARY_PATH` — which is how
# the bare install names set above get resolved. Same arrangement as the Sikarugir engines.
mkdir -p "$PREFIX/Frameworks"
find "$DEPPREFIX/lib" -maxdepth 1 -name "*.dylib" -exec cp -a {} "$PREFIX/Frameworks/" \;
ok "$(find "$PREFIX/Frameworks" -name '*.dylib' | wc -l | tr -d ' ') support libraries bundled"

if "$PREFIX/bin/wine" --version >/dev/null 2>&1; then
    ok "wine still starts with the bundled libraries"
else
    warn "wine --version failed after bundling — check DYLD_FALLBACK_LIBRARY_PATH resolution"
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
