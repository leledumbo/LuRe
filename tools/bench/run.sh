#!/bin/sh
# usage: run.sh <lua-binary>...   best-of-5 wall time in seconds of each benchmark per interpreter
export LC_ALL=C
# resolve the interpreters before changing directory
bins=""
for b in "$@"; do bins="$bins $(readlink -f "$b")"; done
set -- $bins
cd "$(dirname "$0")"
printf '%-8s' bench; n=0; for b in "$@"; do n=$((n+1)); printf '%10s' "lua$n"; done; echo
for f in ${BENCHES:-fib loop table string oop sort}; do
  printf '%-8s' $f
  for b in "$@"; do
    best=999
    for i in 1 2 3 4 5; do
      s=$(date +%s.%N); "$b" $f.lua >/dev/null 2>&1; e=$(date +%s.%N)
      t=$(echo "$e - $s" | bc)
      best=$(echo "if ($t < $best) $t else $best" | bc)
    done
    printf '%10.2f' "$best"
  done; echo
done
