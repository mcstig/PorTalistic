#!/usr/bin/env bash
# Open the bottle's desktop in Screen Sharing. Kept for old instructions: same as `bottle vnc`.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bottle" vnc "$@"
