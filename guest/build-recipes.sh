# The VM's own programs (C, in this kit): how each is built, and the ready-made builds of them.
# Sourced by update-guest.sh, present-layer/install.sh and prebuild.sh, with PB_SRC set to the
# kit's guest/ folder.
#
# The kit can carry ready-made arm64 builds in guest/prebuilt/aarch64 (bottle prebuild on a
# development Mac makes them, in its VM, which has the build tools; MANIFEST records which
# sources each was built from). pb_get installs one of those when its sources are unchanged,
# and builds the program here otherwise (installing the build tools first). VMs set up by the
# packaged app have no build tools: they always get the ready-made builds (package-app.sh
# refuses to package builds older than their sources).
#
#   pb_get NAME OUT   the program NAME, ready to install, into the file OUT
#   PB_NAMES          every program
#   PB_RUNTIME        the packages the programs need to run (the build tools' -devel packages
#                     brought them in before)

# shellcheck disable=SC2034  # (used by the scripts that source this)
PB_NAMES="bottle-screen libnvidia-ml.so.1 libVkLayer_bottle_present.so libbottle_kopper.so bottle-gltest"
# shellcheck disable=SC2034
PB_RUNTIME="libX11 libXext libXdamage libXfixes libXtst libXrender turbojpeg libxcb mesa-libGL mesa-libEGL"

pb_sources() {  # its source files, in guest/
  case "$1" in
    bottle-screen)                echo screen/bottle-screen.c ;;
    libnvidia-ml.so.1)            echo nvml/bottle-nvml.c ;;
    libVkLayer_bottle_present.so) echo present-layer/bottle_present.c ;;
    libbottle_kopper.so)          echo present-layer/bottle_kopper.c ;;
    bottle-gltest)                echo present-layer/bottle_gltest.c ;;
  esac
}

pb_devel() {  # the packages building it needs
  case "$1" in
    bottle-screen)                echo gcc libX11-devel libXext-devel libXdamage-devel libXfixes-devel libXtst-devel turbojpeg-devel ;;
    libnvidia-ml.so.1)            echo gcc ;;
    libVkLayer_bottle_present.so) echo gcc vulkan-headers libxcb-devel libX11-devel ;;
    libbottle_kopper.so)          echo gcc ;;
    bottle-gltest)                echo gcc mesa-libGL-devel mesa-libEGL-devel libXrender-devel libX11-devel ;;
  esac
}

pb_build() {  # $1 = name, $2 = output file
  local s="$PB_SRC"
  case "$1" in
    bottle-screen)
      gcc -O2 -Wall -o "$2" "$s/screen/bottle-screen.c" \
        -lX11 -lXext -lXdamage -lXfixes -lXtst -lturbojpeg -lpthread ;;
    libnvidia-ml.so.1)
      gcc -O2 -Wall -fPIC -shared -fvisibility=hidden -Wl,-soname,libnvidia-ml.so.1 -o "$2" "$s/nvml/bottle-nvml.c" ;;
    libVkLayer_bottle_present.so)
      gcc -O2 -fPIC -shared -fvisibility=hidden -Wall -o "$2" "$s/present-layer/bottle_present.c" -lxcb -lxcb-shm -lpthread ;;
    libbottle_kopper.so)
      gcc -O2 -fPIC -shared -Wall -Wl,-soname,libbottle_kopper.so -o "$2" "$s/present-layer/bottle_kopper.c" -ldl ;;
    bottle-gltest)
      gcc -O2 -Wall -o "$2" "$s/present-layer/bottle_gltest.c" -lX11 -lXrender -lGL -lEGL ;;
    *) return 1 ;;
  esac
}

pb_hash() {  # what NAME's sources are now (sha1, 16 digits; the Mac's shasum gives the same)
  local f
  for f in $(pb_sources "$1"); do cat "$PB_SRC/$f"; done | sha1sum | cut -c1-16
}

pb_get() {  # $1 = name, $2 = output file
  local pre="$PB_SRC/prebuilt/aarch64" p missing=0
  if [[ -f "$pre/$1" && "$(awk -v n="$1" '$1 == n {print $2}' "$pre/MANIFEST" 2>/dev/null)" == "$(pb_hash "$1")" ]]; then
    cp "$pre/$1" "$2"
    echo "  $1: ready-made build"
    return 0
  fi
  for p in $(pb_devel "$1"); do
    rpm -q "$p" >/dev/null 2>&1 || dnf install -y -q "$p" >/dev/null 2>&1 || missing=1
  done
  if (( missing )); then
    echo "  $1: no ready-made build of these sources in the kit, and the build tools didn't install" >&2
    return 1
  fi
  pb_build "$1" "$2" && echo "  $1: built here"
}
