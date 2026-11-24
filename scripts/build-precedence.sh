#!/bin/sh
# after editing precedence.tsv, apple-owner-aliases.tsv, reference-aliases.tsv, tracker-categories.tsv or tracker-owner-aliases.tsv in Sources/Companies/Resources: refreshes their
# entries in manifest.json (hash, row count, optional new version). it never downloads anything.
# usage: scripts/build-precedence.sh [version]   (the version applies to all files; default: keep each one's)
set -eu
cd "$(dirname "$0")/.." || exit 1
res=Sources/Companies/Resources
manifest=$res/manifest.json
today=$(date -u +%Y-%m-%d)
for spec in "precedence.tsv|Tattle source precedence table" "apple-owner-aliases.tsv|Tattle Apple owner aliases" "reference-aliases.tsv|Tattle audit reference aliases" "tracker-categories.tsv|Tattle tracker category map" "tracker-owner-aliases.tsv|Tattle tracker owner aliases"; do
  file=${spec%%|*}; name=${spec#*|}
  tsv=$res/$file
  [ -f "$tsv" ] || { echo "no $tsv" >&2; exit 1; }
  version=${1:-$(jq -r --arg f "$file" '.datasets[] | select(.file == $f) | .version' "$manifest" | head -1)}
  version=${version:-1}
  sha=$(shasum -a 256 "$tsv" | cut -d' ' -f1)
  rows=$(($(wc -l < "$tsv") - 1))
  jq --arg n "$name" --arg f "$file" --arg v "$version" --arg sha "$sha" --argjson rows "$rows" --arg d "$today" '
    .datasets = (.datasets | map(select(.file != $f))) + [{
      name: $n, file: $f, version: $v, commit: "", sourceURL: "", licence: "MIT (own data, public knowledge)",
      fetched: $d, sha256: $sha, sourceSHA256: $sha, rules: $rows }]' "$manifest" > "$manifest.new"
  mv "$manifest.new" "$manifest"
  echo "updated $file ($rows rows, version $version)"
done
