#!/bin/sh
# downloads and updates the independent references for the company classification audit (OD13), into the
# private folder only, never into the repo: the entity map is licensed CC BY-NC-SA 4.0 and is not bundled.
# the app never fetches anything; only this script does.
#
# usage: scripts/audit-references.sh entities                  download the DuckDuckGo Tracker Radar entity map
#        scripts/audit-references.sh certs <domains-file>      fetch each domain's certificate organisation once
#        env: TATTLE_REFERENCES  folder (default ~/dev/tattle-fixtures/reference, mode 700)
#             RATE            certificate fetches per second (default 2)
#             RETRY_FAILED=1  fetch again the domains whose cached answer is a failure
#             RADAR_COMMIT    commit of duckduckgo/tracker-radar to pin (default: latest main, resolved once)
# the domains file is made by: tattle companies audit --references <dir> --domains-out <file> ...
set -eu
dir=${TATTLE_REFERENCES:-$HOME/dev/tattle-fixtures/reference}
rate=${RATE:-2}
repo=$(cd "$(dirname "$0")/.." && pwd -P)
umask 077
mkdir -p "$dir"
# resolve first (relative paths, symlinks), then refuse anything inside this repo or any other git work tree
dir=$(cd "$dir" && pwd -P)
case "$dir" in
  "$repo"|"$repo"/*) echo "the references folder must be outside the repo" >&2; exit 1 ;;
esac
if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "the references folder must not be inside a git work tree" >&2; exit 1
fi
chmod 700 "$dir"

entities() {
  commit=${RADAR_COMMIT:-$(curl -sS -m 30 "https://api.github.com/repos/duckduckgo/tracker-radar/commits/main" | sed -n 's/^  "sha": "\([0-9a-f]*\)".*/\1/p' | head -1)}
  [ -n "$commit" ] || { echo "could not resolve the tracker radar commit" >&2; exit 1; }
  url="https://raw.githubusercontent.com/duckduckgo/tracker-radar/$commit/build-data/generated/domain_map.json"
  tmp=$dir/ddg-domain-map.json.new
  curl -sS -f -m 300 -o "$tmp" "$url"
  chmod 600 "$tmp"
  mv "$tmp" "$dir/ddg-domain-map.json"
  sha=$(shasum -a 256 "$dir/ddg-domain-map.json" | cut -d' ' -f1)
  printf 'url\t%s\ncommit\t%s\nsha256\t%s\nlicence\tCC BY-NC-SA 4.0, reference only, never bundled or committed\nfetched\t%s\n' \
    "$url" "$commit" "$sha" "$(date -u +%Y-%m-%d)" > "$dir/ddg-provenance.txt"
  chmod 600 "$dir/ddg-provenance.txt"
  echo "entity map saved ($(wc -c < "$dir/ddg-domain-map.json" | tr -d ' ') bytes); provenance in the references folder"
}

# the organisation of the subject of the certificate a server presents, "none" when the subject has no O=
certs() {
  list=${1:?need a domains file}
  cache=$dir/cert-orgs.tsv
  [ -f "$cache" ] || { : > "$cache"; chmod 600 "$cache"; }
  delay=$(awk -v r="$rate" 'BEGIN { printf "%.3f", 1 / r }')
  done=0
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    if grep -q "^$(printf '%s' "$domain" | sed 's/[.]/\\./g')	" "$cache"; then
      if [ "${RETRY_FAILED:-0}" = 1 ] && grep -q "^$(printf '%s' "$domain" | sed 's/[.]/\\./g')	fail" "$cache"; then
        grep -v "^$(printf '%s' "$domain" | sed 's/[.]/\\./g')	fail" "$cache" > "$cache.new" || true
        mv "$cache.new" "$cache"; chmod 600 "$cache"
      else
        continue
      fi
    fi
    subject=$(printf '' | perl -e 'alarm 8; exec @ARGV' openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null \
      | openssl x509 -noout -subject -nameopt multiline,utf8 2>/dev/null || true)
    if [ -z "$subject" ]; then
      printf '%s\tfail\n' "$domain" >> "$cache"
    else
      org=$(printf '%s\n' "$subject" | sed -n 's/^ *organizationName *= *//p' | head -1)
      if [ -n "$org" ]; then printf '%s\torg\t%s\n' "$domain" "$org" >> "$cache"; else printf '%s\tnone\n' "$domain" >> "$cache"; fi
    fi
    done=$((done + 1))
    sleep "$delay"
  done < "$list"
  echo "fetched $done certificates; cache has $(wc -l < "$cache" | tr -d ' ') entries"
}

case "${1:-}" in
  entities) entities ;;
  certs) shift; certs "$@" ;;
  *) sed -n '2,13p' "$0" >&2; exit 1 ;;
esac
