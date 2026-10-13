#!/usr/bin/env bash
# Push this kit's source to GitHub as a new commit on the repository's default branch, before
# host/release.sh (a release's tag is made there, so it has to hold that version's source):
#
#   host/push-source.sh OWNER/REPO [--dry-run] [--message TEXT]
#     --dry-run   show what would change, push nothing
#     --message   the commit message (default: "Portalistic <version>")
#
# The kit is the working tree: its .gitignore leaves out build/, logs/ and the development-only
# checks. The repository's history is kept in ~/Library/Caches/Portalistic/source.git, outside
# the iCloud-synced Documents folder. Pushes with GitHub's command-line tool's sign-in (gh auth
# login); commits with your git name and email (git config --global user.name / user.email).
#
# Written for macOS's bash 3.2.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo "usage: host/push-source.sh OWNER/REPO [--dry-run] [--message TEXT]" >&2; exit 2; }
REPO="${1:-}"
[[ "$REPO" == */* ]] || usage
shift
DRY=0
MESSAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --message) MESSAGE="${2:-}"; [[ -n "$MESSAGE" ]] || usage; shift 2 ;;
    *) usage ;;
  esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "Needs GitHub's command-line tool: brew install gh && gh auth login"
gh auth status >/dev/null 2>&1 || die "Sign in to GitHub first: gh auth login"
[[ -f "$KIT/.gitignore" ]] || die "The kit has no .gitignore: it would push build/ and logs/ too."
VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' "$KIT/host/xcode/Bottle.xcconfig")"
[[ -n "$MESSAGE" ]] || MESSAGE="Portalistic $VERSION"
BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)"
URL="https://github.com/$REPO.git"
CRED=(-c credential.helper= -c 'credential.helper=!gh auth git-credential')

GD="$HOME/Library/Caches/Portalistic/source.git"
[[ -d "$GD" ]] || git init -q --bare "$GD"
export GIT_DIR="$GD" GIT_WORK_TREE="$KIT" GIT_INDEX_FILE="$GD/kit-index"
info "Getting $REPO's $BRANCH branch…"
git "${CRED[@]}" fetch -q "$URL" "+refs/heads/$BRANCH:refs/heads/$BRANCH"
git symbolic-ref HEAD "refs/heads/$BRANCH"
git read-tree "$BRANCH"
git add -A
if git diff --cached --quiet "$BRANCH"; then
  info "$REPO's $BRANCH already has this kit's source."
  exit 0
fi
git diff --cached --stat "$BRANCH" | tail -n 40
if (( DRY )); then
  info "(dry run: nothing committed or pushed)"
  exit 0
fi
[[ -n "$(git config user.email || true)" ]] \
  || die "git doesn't know your name for the commit: git config --global user.name NAME; git config --global user.email EMAIL"
git commit -q -m "$MESSAGE"
info "Pushing $(git rev-parse --short HEAD) \"$(git log -1 --format=%s)\" to $REPO's $BRANCH…"
git "${CRED[@]}" push -q "$URL" "$BRANCH:$BRANCH"
info "Done: https://github.com/$REPO/commits/$BRANCH"
