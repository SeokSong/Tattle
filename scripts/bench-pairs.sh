#!/bin/bash
# back-to-back throughput check: the new release build alternates with the frozen older tools on the same
# capture, so a busy Mac slows all of them alike. leave the Mac idle while it runs.
# usage: scripts/bench-pairs.sh [pairs] [capture]
# needs: swift build -c release --product tattle; ~/dev/tattle-bin/tattle (M2 build) and
# ~/dev/tattle-bin/WatchCapture-baseline (pre-M2); the capture defaults to the fixture s3-youtube-quic
set -euo pipefail
pairs=${1:-3}
capture=${2:-${TATTLE_FIXTURES:-$HOME/dev/tattle-fixtures}/captures/s3-youtube-quic.pcapng}
new=.build/release/tattle
m2=$HOME/dev/tattle-bin/tattle
base=$HOME/dev/tattle-bin/WatchCapture-baseline
for tool in "$new" "$m2" "$base"; do [ -x "$tool" ] || { echo "missing: $tool" >&2; exit 1; }; done
[ -f "$capture" ] || { echo "missing capture: $capture" >&2; exit 1; }

best() { "$1" bench "$capture" | awk '/^Best:/ {print $2}'; }
for i in $(seq 1 "$pairs"); do
    echo "pair $i: new $(best "$new")  M2 $(best "$m2")  baseline $(best "$base") packets/s"
done
