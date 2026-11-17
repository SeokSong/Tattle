#!/bin/sh
# runs the test suite with a time limit. clears test runners left over from an
# interrupted run first: they hold the build lock and make the next run hang.
# usage: scripts/test.sh [seconds] [swift test arguments...]
#   WATCH_FIXTURES=~/dev/watch-fixtures scripts/test.sh 300
limit=${1:-300}
[ $# -gt 0 ] && shift
pkill -9 -f swiftpm-testing-helper 2>/dev/null
cd "$(dirname "$0")/.." || exit 1
# swift-testing buffers its output when not on a terminal, so a run killed by the
# alarm prints nothing; the exit code (142) still says it timed out
exec /usr/bin/perl -e 'alarm shift; exec @ARGV' "$limit" swift test "$@"
