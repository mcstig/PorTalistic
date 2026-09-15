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

# ── x86_64 dependencies ──────────────────────────────────────────────────────────────────
say "Getting x86_64 freetype and gnutls"

# Without freetype Wine renders no text at all, which for most games means no menus. The
# obstacle is that `$BREW_PREFIX` is arm64 and an x86_64 Wine cannot link against it.
#
# Rather than install a whole second Homebrew under /usr/local through Rosetta, this pulls
# the x86_64 *bottles* — the same binaries that Homebrew would pour — and unpacks them into
# the build tree. Nothing is installed system-wide and nothing outside $WORK is touched.
#
# The cost is three fixups, all of which exist because a bottle that was never poured is
# still full of placeholders:
#
#   1. Its `.pc` files say `@@HOMEBREW_PREFIX@@` instead of a path.
#   2. Each dylib's own install name says the same, so anything linked against it would
#      record a path that doesn't exist and fail at load time.
#   3. Rewriting an install name invalidates the signature, so each one has to be re-signed.
#
# The install names become bare leaf names, which makes dyld resolve them through
# `DYLD_FALLBACK_LIBRARY_PATH` — and that is exactly what PorTalistic sets to a runtime's
# `Frameworks` directory. It is also how the Sikarugir engines are arranged, which is the
# one arrangement known to work with this app.

DEPS="$WORK/deps"
CELLAR="$DEPS/cellar"
DEPPREFIX="$DEPS/prefix"

if [[ -f "$DEPS/.ready" ]]; then
    ok "already unpacked (delete $DEPS to redo)"
else
    rm -rf "$DEPS"
    mkdir -p "$CELLAR" "$DEPPREFIX/include" "$DEPPREFIX/lib"

    # Which macOS release's x86_64 bottles to use.
    #
    # Not this one. Homebrew builds x86_64 bottles only for the releases Apple still ships
    # Intel Macs for, and macOS 26 is not one of them — asking for `tahoe` gets "Bottle for
    # tag :tahoe is unavailable" eleven times out of twelve. The native tag is no help either
    # for the same reason; it is `arm64_tahoe`, and stripping the prefix names a bottle that
    # was never built.
    #
    # An x86_64 bottle built for an older macOS runs fine on a newer one, so take the newest
    # tag that actually has one. Found by asking for it: availability is not something worth
    # predicting when one fetch settles it, and the fetch warms the cache either way.
    ok "looking for the newest macOS with x86_64 bottles"
    TAG=""
    for candidate in ${BOTTLE_TAG:-sequoia sonoma ventura monterey}; do
        if brew fetch --bottle-tag="$candidate" freetype >/dev/null 2>&1; then
            TAG="$candidate"
            break
        fi
        printf '  \033[33m!\033[0m no x86_64 bottle for %s\n' "$candidate"
    done

    if [[ -z "$TAG" ]]; then
        printf "\n  no macOS release has an x86_64 freetype bottle, which shouldn't happen.\n\n" >&2
        printf "  To see what Homebrew actually has:\n" >&2
        printf "      brew info --json=v2 freetype | python3 -m json.tool | grep -A25 files\n\n" >&2
        printf "  Then rerun with that tag:\n" >&2
        printf "      BOTTLE_TAG=<tag> bash Compatibility/build-dxmt-wine.sh\n" >&2
        die "no usable bottle tag"
    fi
    ok "bottle tag: $TAG"

    # Everything freetype and gnutls link against, not just the two themselves.
    # No `mapfile`: macOS ships bash 3.2 and that is a bash 4 builtin.
    FORMULAE=()
    while IFS= read -r formula; do
        [[ -n "$formula" ]] && FORMULAE+=("$formula")
    done < <(printf '%s\n' freetype gnutls $(brew deps --union freetype gnutls) | sort -u)

    (( ${#FORMULAE[@]} )) || die "brew deps returned nothing for freetype and gnutls"
    ok "${#FORMULAE[@]} formulae: ${FORMULAE[*]}"

    # Per formula rather than all at once, so a failure can name the formula instead of
    # leaving twelve possibilities. A bottle with no architecture — `ca-certificates` is one —
    # is tagged `all`, and `brew --cache` files it under that tag rather than this one, so
    # both are tried.
    MISSING=""
    for formula in "${FORMULAE[@]}"; do
        brew fetch --bottle-tag="$TAG" "$formula" >/dev/null 2>&1

        bottle=""
        for cachetag in "$TAG" all; do
            candidate="$(brew --cache --bottle-tag="$cachetag" "$formula" 2>/dev/null)"
            if [[ -f "$candidate" ]]; then
                bottle="$candidate"
                break
            fi
        done

        if [[ -z "$bottle" ]]; then
            MISSING="$MISSING $formula"
            continue
        fi

        tar -xzf "$bottle" -C "$CELLAR"
    done

    # freetype and gnutls are the point; a missing dependency of theirs would only fail later
    # and less clearly, so all of them are required.
    if [[ -n "$MISSING" ]]; then
        printf "\n  no x86_64 bottle for:%s\n\n" "$MISSING" >&2
        printf "  Try an older release:\n" >&2
        printf "      BOTTLE_TAG=sonoma bash Compatibility/build-dxmt-wine.sh\n" >&2
        die "incomplete dependency set"
    fi
    ok "unpacked into the build tree"

    # Flatten the Cellar layout into one prefix Wine's configure can be pointed at.
    for kegdir in "$CELLAR"/*/*/; do
        [[ -d "$kegdir/include" ]] && cp -R "$kegdir/include/." "$DEPPREFIX/include/" 2>/dev/null
        [[ -d "$kegdir/lib" ]] && cp -R "$kegdir/lib/." "$DEPPREFIX/lib/" 2>/dev/null
    done

    # 1. Placeholders in pkg-config files.
    # `-exec … +` rather than `xargs -r`: BSD xargs has no -r, and would run sed with no
    # arguments if nothing matched.
    find "$DEPPREFIX" -name "*.pc" -exec sed -i '' \
        -e "s|@@HOMEBREW_PREFIX@@|$DEPPREFIX|g" \
        -e "s|@@HOMEBREW_CELLAR@@|$CELLAR|g" {} +

    # 2 and 3. Install names, their dependents, and the signature.
    for dylib in "$DEPPREFIX"/lib/*.dylib; do
        [[ -f "$dylib" && ! -L "$dylib" ]] || continue

        install_name_tool -id "$(basename "$dylib")" "$dylib" 2>/dev/null

        otool -L "$dylib" | awk 'NR>1 {print $1}' | while read -r dependency; do
            case "$dependency" in
                @@HOMEBREW*|"$DEPPREFIX"*|"$CELLAR"*|"$BREW_PREFIX"*)
                    install_name_tool -change "$dependency" "$(basename "$dependency")" "$dylib" 2>/dev/null
                    ;;
            esac
        done

        codesign --force --sign - "$dylib" 2>/dev/null
    done

    ok "$(find "$DEPPREFIX/lib" -name '*.dylib' -not -type l | wc -l | tr -d ' ') libraries ready"
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

# The unpacked x86_64 bottles, never `$BREW_PREFIX` — that one is arm64 and linking an
# x86_64 Wine against it fails at the first link.
export PKG_CONFIG_PATH="$DEPPREFIX/lib/pkgconfig"

BUILD="$WORK/build"
mkdir -p "$BUILD"

# The first run's build directory is configured for arm64 and reusing it would repeat the
# failure, so it goes when the architecture it was configured for isn't the one we want.
if [[ -f "$BUILD/Makefile" && ! -f "$BUILD/.configured-x86_64-with-deps" ]]; then
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
            --without-oss \
            --without-v4l2
    ) || die "configure failed — the tail of $BUILD/config.log says why"
    touch "$BUILD/.configured-x86_64-with-deps"
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
