#!/usr/bin/env bash
# (selftest: may run during a game)
# proton-script: how Proton Experimental's launcher script handles its settings and the game's
# command line (user_settings.py, sys.argv, PROTON_* switches), for changes to user_settings.py.
set -u
for p in ~/.local/share/Steam/steamapps/common/"Proton - Experimental"/proton /s/steamapps/common/"Proton - Experimental"/proton; do
  [[ -f "$p" ]] || continue
  echo "== $p ($(wc -l < "$p") lines)"
  grep -n -E "user_settings|sys\.argv|cmdlineappend|def run|def init_session|__main__|g_session = |PROTON_SET_GAME|commandline|SteamGameId" "$p" | cut -c1-220
  echo "== the end of the script"
  tail -n 60 "$p" | cut -c1-200
  break
done
