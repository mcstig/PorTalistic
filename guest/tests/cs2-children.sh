#!/bin/bash
# Logs the processes CS2 starts (polled every 0.3 s) and children stuck right after a fork
# (still the game's own program, one thread, in futex for 5 s+). For the fork hang (Oct 28).
OUT=/tmp/cs2-children.log; : > $OUT
declare -A seen
end=$((SECONDS + 3600))
while (( SECONDS < end )); do
  p=$(pgrep -f '^/mnt/portalistic/.*/linuxsteamrt64/cs2' | head -1)
  if [[ -z "$p" ]]; then sleep 1; continue; fi
  for c in $(pgrep -P "$p"); do
    cmd=$(tr '\0' ' ' < /proc/$c/cmdline 2>/dev/null | cut -c1-200); exe=$(readlink /proc/$c/exe 2>/dev/null)
    key="$c|$cmd"
    if [[ -z "${seen[$key]:-}" ]]; then
      seen[$key]=1
      thr=""; for t in /proc/$c/task/*; do thr+="$(cat $t/comm 2>/dev/null),"; done
      echo "$(date +%T.%N | cut -c1-12) child $c of $p exe=$exe threads=$thr cmd=$cmd" >> $OUT
    fi
    if [[ "$cmd" == *linuxsteamrt64/cs2* && "$(ls /proc/$c/task 2>/dev/null | wc -l)" == 1 && "$(cat /proc/$c/wchan 2>/dev/null)" == futex_do_wait ]]; then
      age=$(( $(date +%s) - $(stat -c %Y /proc/$c 2>/dev/null || date +%s) ))
      if (( age >= 5 )) && [[ -z "${seen[stuck$c]:-}" ]]; then
        seen[stuck$c]=1
        w=""; for t in /proc/$p/task/*; do [[ "$(cut -d' ' -f1 $t/syscall 2>/dev/null)" == 260 ]] && w+="$(cat $t/comm) "; done
        echo "$(date +%T) STUCK fork child $c ($(cat /proc/$c/comm)) for ${age}s; parent threads waiting: $w" >> $OUT
      fi
    fi
  done
  sleep 0.3
done
