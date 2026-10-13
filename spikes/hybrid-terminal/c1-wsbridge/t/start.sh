#!/bin/zsh
# usage: start.sh [bridge extra args...]
cd "$(dirname $0)/.."
W=$PWD/t/state
./t/stop.sh >/dev/null 2>&1
rm -rf $W; mkdir -p $W/home
(${BIN:-.build/debug}/ptyd daemon --home $W/home > $W/holder.log 2>&1 &)
sleep 0.5
(${BIN:-.build/debug}/wsbridge --port 18750 --holder $W/home/ptyd.sock --token-file $W/token --allow-cwd $PWD/work --allow-shell "$@" > $W/bridge.log 2>&1 &)
sleep 0.7
echo "started: holder $(pgrep -f 'ptyd daemon') bridge $(pgrep -f 'wsbridge --port')"
