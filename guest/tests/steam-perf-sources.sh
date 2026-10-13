#!/usr/bin/env bash
# (selftest: may run during a game)
# steam-perf-sources: where Steam's performance monitor could read GPU and temperature numbers on
# Linux: the strings in the ARM64 client's libraries and programs that name sysfs/hwmon files,
# vendor libraries (NVML, ...) or helpers; what the VM itself offers there; Steam's own
# system-performance logs.
set -u
S=~/.local/share/Steam
echo "== $(date)"
pat='gpu_busy|busy_percent|nvml|libnvidia-ml|hwmon|/sys/class/drm|/sys/class/hwmon|amdgpu|temp[0-9]_input|power1_average|mangoapp|gpu_metrics|pp_dpm|freq1_input|thermal_zone|gt_cur_freq|i915|xe/|nvidia-smi|libdrm_amdgpu|GetGPU|gpu_usage|GPUUtil|GpuUtil|CPerfMonitor|PerfOverlay|perfoverlay'
for f in "$S"/steamrtarm64/*.so "$S"/steamrtarm64/steam "$S"/steamrtarm64/gameoverlayui "$S"/steamrtarm64/*.so.* \
         "$S"/linuxarm64/*.so "$S"/ubuntu12_64/gameoverlayrenderer.so; do
  [[ -f "$f" ]] || continue
  hits="$(grep -a -o -E "[[:print:]]{0,60}($pat)[[:print:]]{0,60}" "$f" 2>/dev/null | sort -u | head -60)"
  [[ -n "$hits" ]] && { echo "-- ${f#"$S"/} ($(stat -c %s "$f") bytes)"; echo "$hits" | cut -c1-200; }
done
echo "== the VM: drm and hwmon"
ls -la /sys/class/drm/ 2>&1 | head; ls /sys/class/hwmon/ 2>&1; ls /sys/class/thermal/ 2>&1 | head
for d in /sys/class/drm/card*/device; do echo "-- $d"; ls "$d" 2>&1 | head -40 | tr '\n' ' '; echo; done
echo "== Steam's perf logs"
for f in "$S"/logs/systemperfmanager.txt "$S"/logs/systemperfreporting.txt "$S"/logs/perf*.txt; do
  [[ -f "$f" ]] && { echo "-- $f"; tail -n 30 "$f" | cut -c1-200; }
done
