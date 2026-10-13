#!/usr/bin/env bash
# (selftest: may run during a game)
# steamplay-status: the installed games as bottle-steamplay sees them (name, app ID, which
# version, Steam Play tool), and the native-apps list.
set -u
bottle-steamplay status 2>&1
echo "== native-apps"; cat ~/.config/steamos-bottle/native-apps 2>/dev/null || echo "(none)"
