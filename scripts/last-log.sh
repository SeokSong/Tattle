#!/bin/sh
# prints the newest capture log written by the Mac app (never contains the device udid)
dir="$HOME/Library/Application Support/Tattle/logs"
# before first run of the renamed app the logs may still be in the old Watch folder
[ -d "$dir" ] || { [ -d "$HOME/Library/Application Support/Watch/logs" ] && dir="$HOME/Library/Application Support/Watch/logs"; }
newest=$(/bin/ls -t "$dir" 2>/dev/null | head -n 1)
if [ -z "$newest" ]; then echo "no capture logs in $dir"; exit 1; fi
echo "== $newest"
cat "$dir/$newest"
