#!/bin/sh
# creates and checks the private fixtures folder (real captures hold personal traffic,
# so it must stay outside git and outside iCloud).
# usage: scripts/fixtures.sh init|check
#   TATTLE_FIXTURES=/some/dir scripts/fixtures.sh check    (default ~/dev/tattle-fixtures)
# WATCH_FIXTURES is the deprecated old name, still read as a fallback; so is the old default
# folder ~/dev/watch-fixtures when ~/dev/tattle-fixtures does not exist
set -eu

if [ -n "${TATTLE_FIXTURES:-}" ]; then
    dir=$TATTLE_FIXTURES
elif [ -n "${WATCH_FIXTURES:-}" ]; then
    dir=$WATCH_FIXTURES
elif [ ! -d "$HOME/dev/tattle-fixtures" ] && [ -d "$HOME/dev/watch-fixtures" ]; then
    dir=$HOME/dev/watch-fixtures
else
    dir=$HOME/dev/tattle-fixtures
fi
case $dir in
    "~") dir=$HOME ;;
    "~/"*) dir=$HOME/${dir#"~/"} ;;
esac

init() {
    umask 077
    for sub in captures scenarios reports db; do
        mkdir -p "$dir/$sub"
        chmod 700 "$dir/$sub"
    done
    chmod 700 "$dir"
    echo "fixtures folder ready: $dir"
}

check() {
    fail=0
    if [ ! -d "$dir" ]; then
        echo "fail: $dir does not exist (run: scripts/fixtures.sh init)"
        exit 1
    fi
    real=$(cd "$dir" && pwd -P)

    if command -v git >/dev/null 2>&1 && git -C "$real" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "fail: $real is inside a git work tree"
        fail=1
    fi
    case $real in
        *"Mobile Documents"*|*/Desktop|*/Desktop/*|*/Documents|*/Documents/*)
            echo "fail: $real is in a folder that syncs to iCloud (Mobile Documents, Desktop or Documents)"
            fail=1 ;;
    esac
    # group/world access shows up as any non-zero digit after the owner digit
    for p in "$real" "$real"/captures "$real"/scenarios "$real"/reports "$real"/db; do
        [ -d "$p" ] || continue
        mode=$(stat -f %Lp "$p")
        case $mode in
            ?00|?0|?) ;;
            *) echo "fail: $p has mode $mode, expected 700"; fail=1 ;;
        esac
    done
    for sub in captures scenarios reports db; do
        [ -d "$real/$sub" ] || echo "warn: missing $sub/ (run: scripts/fixtures.sh init)"
    done

    if [ "$fail" -ne 0 ]; then
        echo "check failed"
        exit 1
    fi

    cd "$real"
    echo "files in $real:"
    manifest=MANIFEST.sha256
    tmp=$(mktemp "${TMPDIR:-/tmp}/tattle-manifest.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    find . -type f ! -name "$manifest" ! -name .DS_Store | sort | while IFS= read -r f; do
        size=$(stat -f %z "$f")
        echo "  $size  ${f#./}"
        shasum -a 256 "$f" >> "$tmp"
    done
    umask 077
    cat "$tmp" > "$manifest"
    echo "wrote $real/$manifest ($(wc -l < "$manifest" | tr -d ' ') files)"
    echo "check passed"
}

case ${1:-} in
    init) init ;;
    check) check ;;
    *) echo "usage: scripts/fixtures.sh init|check" >&2; exit 2 ;;
esac
