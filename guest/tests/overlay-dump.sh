#!/usr/bin/env bash
# (selftest: may run during a game)
# overlay-dump: the x86 parts of Steam's overlay (ubuntu12_64/steamoverlayvulkanlayer.so and
# gameoverlayrenderer.so) as base64 between markers, to study how they draw when the overlay
# looks wrong in a game.
set -u
for f in ~/.local/share/Steam/ubuntu12_64/steamoverlayvulkanlayer.so ~/.local/share/Steam/ubuntu12_64/gameoverlayrenderer.so; do
  ls -l "$f"; md5sum "$f"
  echo "==B64-BEGIN== ${f##*/}"; base64 -w0 "$f"; echo; echo "==B64-END=="
done
