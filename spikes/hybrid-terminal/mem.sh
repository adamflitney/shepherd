#!/bin/bash
# physical footprint of c2host + its WebKit helper processes (those started after it, parent launchd)
HOST=$(pgrep -x c2host)
PIDS="$HOST $(ps -axo pid,ppid,comm | awk -v h=$HOST '$1>h && $2==1 && /com.apple.WebKit/ {print $1}')"
total=0
for p in $PIDS; do
  name=$(ps -o comm= -p $p | sed 's|.*/||')
  mb=$(footprint -p $p 2>/dev/null | grep -m1 'Footprint:' | sed -E 's/.*Footprint: ([0-9.]+) (KB|MB|GB).*/\1 \2/' | awk '{ if ($2=="KB") print $1/1024; else if ($2=="GB") print $1*1024; else print $1 }')
  printf '  %-34s %6.1f MB\n' "$name" "$mb"; total=$(python3 -c "print($total+$mb)")
done
printf '  %-34s %6.1f MB\n' "TOTAL" "$total"
