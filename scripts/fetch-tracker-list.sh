#!/bin/sh
# downloads a pinned copy of the AdGuard companiesdb tracker list (CC BY-SA 4.0) into a folder outside
# the repo, with a provenance file. the app never fetches anything; only this script does. the compiled
# index that ships in the app is built from this copy by a separate step (problem 1.6).
#
# usage: scripts/fetch-tracker-list.sh
#        env: TATTLE_TRACKER_LIST  folder (default ~/dev/tattle-fixtures/tracker-list, mode 700)
#             ADGUARD_COMMIT       commit of AdguardTeam/companiesdb to pin (default: latest main, resolved once)
set -eu
dir=${TATTLE_TRACKER_LIST:-$HOME/dev/tattle-fixtures/tracker-list}
repo=$(cd "$(dirname "$0")/.." && pwd -P)
umask 077
# resolve through the parent so a refused folder is never created; refuse the repo or any git work tree
parent=$(dirname "$dir")
[ -d "$parent" ] || { echo "the parent of the tracker list folder must exist" >&2; exit 1; }
dir="$(cd "$parent" && pwd -P)/$(basename "$dir")"
[ -L "$dir" ] && dir=$(cd "$dir" && pwd -P)
case "$dir" in
  "$repo"|"$repo"/*) echo "the tracker list folder must be outside the repo" >&2; exit 1 ;;
esac
if git -C "$(dirname "$dir")" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { [ -d "$dir" ] && git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; }; then
  echo "the tracker list folder must not be inside a git work tree" >&2; exit 1
fi
mkdir -p "$dir"
chmod 700 "$dir"

commit=${ADGUARD_COMMIT:-$(curl -sS -m 30 "https://api.github.com/repos/AdguardTeam/companiesdb/commits/main" | sed -n 's/^  "sha": "\([0-9a-f]*\)".*/\1/p' | head -1)}
[ -n "$commit" ] || { echo "could not resolve the companiesdb commit" >&2; exit 1; }
base="https://raw.githubusercontent.com/AdguardTeam/companiesdb/$commit"

prov=$dir/adguard-provenance.txt.new
printf 'commit\t%s\nlicence\tCC BY-SA 4.0 (AdGuard companiesdb, based on Whotracks.me CC BY 4.0)\nfetched\t%s\n' \
  "$commit" "$(date -u +%Y-%m-%d)" > "$prov"
for f in dist/trackers.json dist/companies.json LICENSE; do
  name=$(basename "$f")
  tmp=$dir/$name.new
  curl -sS -f -m 300 -o "$tmp" "$base/$f"
  chmod 600 "$tmp"
  mv "$tmp" "$dir/$name"
  printf 'file\t%s\t%s\t%s\n' "$name" "$base/$f" "$(shasum -a 256 "$dir/$name" | cut -d' ' -f1)" >> "$prov"
done
chmod 600 "$prov"
mv "$prov" "$dir/adguard-provenance.txt"
echo "tracker list saved at commit $commit; provenance in the tracker list folder"
