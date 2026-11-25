#!/bin/sh
# launches the Mac app with the made-up demo summary and a throwaway data folder, and saves a picture of its
# window only (never the whole screen, which can show private windows). the real data folder
# (~/Library/Application Support/Tattle) is never opened: TATTLE_SUPPORT_BASE points the app elsewhere.
# usage: scripts/demo-screenshot.sh <output.png> [seconds to wait before the picture, default 4]
#        leaves the app running so it can be clicked; quit it with Cmd-Q or: pkill -f .build/debug/TattleApp
set -eu
out=${1:?usage: scripts/demo-screenshot.sh <output.png> [wait-seconds]}
wait=${2:-4}
case $wait in ''|*[!0-9]*) echo "wait-seconds must be a whole number" >&2; exit 2 ;; esac
cd "$(dirname "$0")/.." || exit 1
base=$(mktemp -d "${TMPDIR:-/tmp}/tattle-demo-base.XXXXXX")
swift build --product TattleApp >/dev/null
TATTLE_DEMO_SUMMARY=1 TATTLE_SUPPORT_BASE="$base" nohup .build/debug/TattleApp >"$base/app.log" 2>&1 &
pid=$!
perl -e 'select(undef, undef, undef, $ARGV[0])' "$wait"
# the window of the process started above, matched by its pid, never by name: another TattleApp window may show
# real data (review of PR #10)
id=$(TATTLE_PID="$pid" swift - <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int(ProcessInfo.processInfo.environment["TATTLE_PID"] ?? "") ?? -1
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String] ?? "")
}
SWIFT
)
id=$(printf '%s\n' "$id" | head -1)
[ -n "$id" ] || { echo "no TattleApp window found (is the app showing?)" >&2; exit 1; }
screencapture -x -o -l "$id" "$out"
echo "saved $out (window $id, pid $pid); data folder $base"
