#!/usr/bin/env bash
# (selftest: may run during a game)
# build-check: the kit's new VM programs build and parse with the VM's own compiler and Python
# (copies in build-check/), without installing anything. Also: is xrandr there yet.
set -u
cd "$(dirname "$0")/build-check" || exit 1
t="$(mktemp -d)"
echo "== $(date); gcc $(gcc -dumpversion 2>/dev/null)"
gcc -O2 -Wall -o "$t/bottle-screen" bottle-screen.c -lX11 -lXext -lXdamage -lXfixes -lXtst -lturbojpeg -lpthread 2>&1 | head -20 \
  && [[ -x "$t/bottle-screen" ]] && echo "bottle-screen: builds"
gcc -O2 -Wall -fPIC -shared -fvisibility=hidden -Wl,-soname,libnvidia-ml.so.1 -o "$t/libnvidia-ml.so.1" bottle-nvml.c 2>&1 | head -20 \
  && [[ -f "$t/libnvidia-ml.so.1" ]] && echo "nvml: builds ($(nm -D --defined-only "$t/libnvidia-ml.so.1" | grep -c nvml) functions)"
python3 -c "import ast,sys; ast.parse(open('bottle-whyquit').read())" && echo "bottle-whyquit: parses"
bash -n bottle-resolution && echo "bottle-resolution: parses"
command -v xrandr >/dev/null && echo "xrandr: $(command -v xrandr)" || echo "xrandr: not installed yet (bottle update installs it)"
DISPLAY=:1 xrandr --query 2>/dev/null | head -3
rm -rf "$t"
