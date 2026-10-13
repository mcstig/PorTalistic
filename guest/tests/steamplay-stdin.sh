#!/usr/bin/env bash
# (selftest: may run during a game)
# steamplay-stdin: the kit's bottle-steamplay run from standard input (as `bottle version` does
# now), status only, and which game "cs2" names. Changes nothing.
set -u
cd "$(dirname "$0")" || exit 1
python3 - status < ./steamplay-copy | head -5
python3 - <<'PY'
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("bs", "./steamplay-copy").load_module()
apps = {a: i for a, i in m.installed_apps().items() if not i["tool"]}
for q in ("cs2", "witcher", "w3", "730"):
    print(q, "->", [apps[a]["name"] for a in m.find_games(q, apps)])
PY
