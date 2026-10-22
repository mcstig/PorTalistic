#!/usr/bin/env bash
# Publish a Portalistic release on GitHub: the notarized app and the Linux image it downloads on
# first launch, with the sources the GPL asks for. On the development Mac, after pushing this
# version's source to the repository (host/push-source.sh):
#
#   host/release.sh OWNER/REPO [--notary PROFILE] [--draft]
#     OWNER/REPO  the GitHub repository (made, public, if it doesn't exist)
#     --notary    notarytool keychain profile; by default the first that works of "portalistic"
#                 and "PorTalistic-Notary" (made once with: xcrun notarytool store-credentials
#                 NAME --apple-id … --team-id …, which asks for an app-specific password)
#     --draft     leave the release as a draft (published by hand on GitHub)
#
# The Linux image: host/image.env names it. One built for this version (host/build-image.sh, after
# bottle prebuild) goes into this release; an earlier one stays where it is, in the release it came
# with, and the app downloads it from there (the VM brings itself up to the app's kit when it
# starts, so the image only has to change when the VM's base system should).
# Steps: the image's address goes into host/image.env (the app carries it), the app is packaged
# and notarized (host/package-app.sh), then release v<version> gets: Portalistic-<version>.zip
# (the app updates itself from it), a new image (in parts under 2 GB) with its SHA-256 and
# packages list, LICENSES.md, and the source of libkrunfw and of the Linux kernel it's built
# from. The release stays a draft until
# every file is up, so nobody downloads an app whose image isn't there yet; if an upload stops,
# running this again carries on with the draft (files already up are kept).
# Needs GitHub's command-line tool, signed in: brew install gh && gh auth login
#
# Written for macOS's bash 3.2.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo "usage: host/release.sh OWNER/REPO [--notary PROFILE] [--draft]" >&2; exit 2; }
REPO="${1:-}"
[[ "$REPO" == */* ]] || usage
shift
NOTARY=""
KEEP_DRAFT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notary) NOTARY="${2:-}"; [[ -n "$NOTARY" ]] || usage; shift 2 ;;
    --draft)  KEEP_DRAFT=1; shift ;;
    *) usage ;;
  esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "Needs GitHub's command-line tool: brew install gh && gh auth login"
gh auth status >/dev/null 2>&1 || die "Sign in to GitHub first: gh auth login"
notary_ok() { xcrun notarytool history --keychain-profile "$1" >/dev/null 2>&1; }
if [[ -z "$NOTARY" ]]; then
  for p in portalistic PorTalistic-Notary; do
    notary_ok "$p" && { NOTARY="$p"; break; }
  done
  [[ -n "$NOTARY" ]] || die "No notarization password stored: xcrun notarytool store-credentials portalistic --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID"
else
  notary_ok "$NOTARY" || die "No notarization password stored as \"$NOTARY\": xcrun notarytool store-credentials $NOTARY --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID"
fi
info "Notarizing with the keychain profile \"$NOTARY\""

[[ -f "$KIT/host/image.env" ]] || die "No Linux image yet: host/build-image.sh"
# shellcheck disable=SC1091
. "$KIT/host/image.env"
VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' "$KIT/host/xcode/Bottle.xcconfig")"
TAG="v$VERSION"
IMG_TAG="v$PORTALISTIC_IMAGE_VERSION"
IMGDIR="$KIT/build/image"
PKGLIST="$IMGDIR/portalistic-linux-$PORTALISTIC_IMAGE_VERSION.packages.txt"
NEW_IMAGE=0
if [[ "$IMG_TAG" == "$TAG" ]]; then
  NEW_IMAGE=1
  for f in ${PORTALISTIC_IMAGE_PARTS:-$PORTALISTIC_IMAGE_FILE}; do
    [[ -f "$IMGDIR/$f" ]] || die "Missing $IMGDIR/$f: host/build-image.sh again."
  done
  [[ -f "$PKGLIST" ]] || die "Missing $PKGLIST: host/build-image.sh again."
fi

if ! gh repo view "$REPO" >/dev/null 2>&1; then
  info "Making the public repository ${REPO}…"
  gh repo create "$REPO" --public --description "Steam on Apple Silicon Macs, in a small Linux VM" >/dev/null
fi
# The release's tag is made on the repository's default branch: that has to be this version's
# source (the GPL's corresponding source for Portalistic's own code, and what people build).
BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)"
REMOTE_VERSION="$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/host/xcode/Bottle.xcconfig?ref=$BRANCH" 2>/dev/null \
  | sed -n 's/^MARKETING_VERSION *= *//p' || true)"
[[ "$REMOTE_VERSION" == "$VERSION" ]] \
  || die "$REPO's $BRANCH branch has Portalistic ${REMOTE_VERSION:-(none)}, this kit is $VERSION: push this version's source first."

STATE="$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq 'if .isDraft then "draft" else "published" end' 2>/dev/null || echo none)"
[[ "$STATE" == published ]] && die "$REPO already has a release $TAG: raise MARKETING_VERSION in host/xcode/Bottle.xcconfig."
if (( ! NEW_IMAGE )); then
  # an earlier release's image: it has to be there, whole
  HAVE="$(gh release view "$IMG_TAG" --repo "$REPO" --json isDraft,assets \
    --jq 'if .isDraft then empty else (.assets[] | "\(.name) \(.size)") end' 2>/dev/null || true)"
  [[ -n "$HAVE" ]] || die "The image is for $PORTALISTIC_IMAGE_VERSION, but $REPO has no published release $IMG_TAG with it: host/build-image.sh for $VERSION, or publish $IMG_TAG first."
  TOTAL=0
  for f in ${PORTALISTIC_IMAGE_PARTS:-$PORTALISTIC_IMAGE_FILE}; do
    s="$(awk -v n="$f" '$1 == n {print $2}' <<<"$HAVE")"
    [[ -n "$s" ]] || die "Release $IMG_TAG on $REPO doesn't have $f (part of the image)."
    TOTAL=$(( TOTAL + s ))
  done
  (( TOTAL == PORTALISTIC_IMAGE_SIZE )) || die "Release $IMG_TAG's image files add up to $TOTAL bytes, host/image.env says $PORTALISTIC_IMAGE_SIZE."
fi

info "The app will download its Linux system from github.com/$REPO, release $IMG_TAG"
URL="https://github.com/$REPO/releases/download/$IMG_TAG"
sed -i '' "s#^PORTALISTIC_IMAGE_URL=.*#PORTALISTIC_IMAGE_URL=$URL#" "$KIT/host/image.env"
grep -q '^PORTALISTIC_IMAGE_URL=' "$KIT/host/image.env" || echo "PORTALISTIC_IMAGE_URL=$URL" >> "$KIT/host/image.env"

info "Packaging and notarizing the app…"
bash "$KIT/host/package-app.sh" --notarize "$NOTARY"
ZIP="$KIT/build/Portalistic-$VERSION.zip"
[[ -f "$ZIP" ]] || die "No $ZIP"

info "Getting libkrunfw's source and the Linux kernel's it's built from (the GPL's corresponding source)…"
SRC="$KIT/build/source"
mkdir -p "$SRC"
KFW_VER="$(brew info --json=v2 libkrunfw | python3 -c 'import json,sys; print(json.load(sys.stdin)["formulae"][0]["versions"]["stable"])')"
KFW_TGZ="$SRC/libkrunfw-$KFW_VER-source.tar.gz"
[[ -f "$KFW_TGZ" ]] || curl -fsSL -o "$KFW_TGZ" "https://github.com/containers/libkrunfw/archive/refs/tags/v$KFW_VER.tar.gz"
KVER="$(tar -xzOf "$KFW_TGZ" "libkrunfw-$KFW_VER/Makefile" | sed -n 's/^KERNEL_VERSION *= *//p' | head -1)"
[[ -n "$KVER" ]] || die "Couldn't tell which kernel libkrunfw $KFW_VER builds (its Makefile)."
KTAR="$SRC/$KVER.tar.xz"
KMAJ="$(echo "$KVER" | sed -n 's/^linux-\([0-9]*\)\..*/\1/p')"
[[ -f "$KTAR" ]] || curl -fsSL -o "$KTAR" "https://cdn.kernel.org/pub/linux/kernel/v$KMAJ.x/$KVER.tar.xz"
echo "  libkrunfw $KFW_VER, $KVER"

NOTES="$KIT/build/release-notes.md"
if (( NEW_IMAGE )); then IMAGE_WHERE="the \`portalistic-linux\` files below"
else IMAGE_WHERE="from release [$IMG_TAG](https://github.com/$REPO/releases/tag/$IMG_TAG)"; fi
{
cat <<EOF
Portalistic $VERSION: Steam on an Apple Silicon Mac (macOS 26 or newer, 8 GB of memory or more).

Download **Portalistic-$VERSION.zip**, unzip it and move Portalistic to Applications. On its first
launch it downloads its Linux system ($(awk -v b="$PORTALISTIC_IMAGE_SIZE" 'BEGIN {printf "%.1f", b / 1e9}') GB, $IMAGE_WHERE: you don't need to download
it yourself), then Steam installs itself and asks you to sign in. Portalistic updates itself from
0.7.0.1 on: it offers each new version (a copy of 0.7.0 needs this download once).

EOF
# what changed (host/release-notes/VERSION.md, if there is one) goes between the download text and the licenses
if [[ -f "$KIT/host/release-notes/$VERSION.md" ]]; then cat "$KIT/host/release-notes/$VERSION.md"; echo; fi
cat <<EOF
Portalistic isn't affiliated with Valve. Third-party software and licenses: LICENSES.md; the
Linux kernel's source (libkrunfw-$KFW_VER-source.tar.gz, $KVER.tar.xz) is attached, and the
image's package list is with the image.

Linux image $PORTALISTIC_IMAGE_VERSION, SHA-256: \`$PORTALISTIC_IMAGE_SHA256\`
EOF
} > "$NOTES"

if [[ "$STATE" == none ]]; then
  info "Making release $TAG on $REPO (a draft until every file is up)…"
  gh release create "$TAG" --repo "$REPO" --target "$BRANCH" --title "Portalistic $VERSION" \
    --notes-file "$NOTES" --draft >/dev/null
else
  info "Carrying on with the draft release ${TAG}…"
  gh release edit "$TAG" --repo "$REPO" --notes-file "$NOTES" >/dev/null
fi
# files already up with the same size are kept (an upload that stopped midway is redone)
UP="$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[] | "\(.name) \(.size)"')"
upload() {
  local f="$1" name size
  name="$(basename "$f")"
  size="$(stat -f %z "$f")"
  if grep -qx "$name $size" <<<"$UP"; then echo "  $name: already up"; return; fi
  info "  uploading $name ($(( size / 1048576 )) MB)…"
  gh release upload "$TAG" --repo "$REPO" --clobber "$f"
}
for f in "$ZIP" "$KIT/LICENSES.md" "$KFW_TGZ" "$KTAR"; do
  upload "$f"
done
if (( NEW_IMAGE )); then
  upload "$IMGDIR/$PORTALISTIC_IMAGE_FILE.sha256"
  upload "$PKGLIST"
  for f in ${PORTALISTIC_IMAGE_PARTS:-$PORTALISTIC_IMAGE_FILE}; do
    upload "$IMGDIR/$f"
  done
fi

if (( KEEP_DRAFT )); then
  info "Done: the draft is at https://github.com/$REPO/releases (publish it there)"
else
  gh release edit "$TAG" --repo "$REPO" --draft=false --latest >/dev/null
  info "Done: https://github.com/$REPO/releases/tag/$TAG"
fi
