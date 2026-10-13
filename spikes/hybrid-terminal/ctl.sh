#!/bin/bash
# usage: ctl.sh <command...>   writes a command file for c2host and prints its output
D=${C2_CTL:-$TMPDIR/c2ctl}
id=$(date +%s%N)
echo "$*" > $D/$id.tmp && mv $D/$id.tmp $D/$id.cmd
for i in $(seq 1 100); do [ -f $D/$id.out ] && { cat $D/$id.out; echo; rm -f $D/$id.out; exit 0; }; sleep 0.1; done
echo "TIMEOUT"
