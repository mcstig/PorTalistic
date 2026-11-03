#!/bin/bash
# Nov 1: while CS2 runs, every 3 s: each thread's name, state, wait channel and system call
# (/proc), into ~/cs2-sample.log. Ends 2 minutes after CS2 is gone, or after 40 minutes.
L=~/cs2-sample.log; : > "$L"
end=$(( SECONDS + 2400 )); gone=0; seen=0
while (( SECONDS < end )); do
  p=$(pgrep -f "linuxsteamrt64/cs2" | head -1)
  if [[ -z "$p" ]]; then
    (( seen )) && (( gone++ )); (( gone > 40 )) && break; sleep 3; continue
  fi
  gone=0; seen=1
  { echo "== $(date '+%T') pid $p load $(cut -d' ' -f1-3 /proc/loadavg) rss $(awk '/VmRSS/ {print $2}' /proc/$p/status) kB threads $(ls /proc/$p/task | wc -l)"
    for t in /proc/$p/task/*; do
      read -r st < <(awk '{print $3, $14+$15}' "$t/stat" 2>/dev/null)
      printf '%s %-16s %s %s sys=%s\n' "${t##*/}" "$(cat "$t/comm" 2>/dev/null)" "$st" "$(cat "$t/wchan" 2>/dev/null)" "$(cut -d' ' -f1 "$t/syscall" 2>/dev/null)"
    done; } >> "$L"
  sleep 3
done
echo "== end $(date '+%T')" >> "$L"
