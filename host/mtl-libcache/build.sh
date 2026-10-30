#!/bin/bash
# Builds libportalistic_mtlcache.dylib next to this script (see mtl_libcache.m). macOS only.
set -euo pipefail
cd "$(dirname "$0")"
clang -dynamiclib -O2 -fno-objc-arc -mmacosx-version-min=14.0 -arch arm64 \
  -framework Foundation -framework Metal -o libportalistic_mtlcache.dylib mtl_libcache.m
codesign -s - -f libportalistic_mtlcache.dylib >/dev/null 2>&1 || true
echo "built $(pwd)/libportalistic_mtlcache.dylib"
