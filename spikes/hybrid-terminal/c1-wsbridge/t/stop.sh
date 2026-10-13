#!/bin/zsh
pkill -f 'wsbridge --port' ; pkill -f 'ptyd hold'; pkill -f 'ptyd daemon'
# children of the holder (spawned shells / claude)
pkill -f 'spike-wsbridge/work' 2>/dev/null
sleep 0.3
