#!/bin/sh
# builds the bundled Public Suffix List data from a local copy. it never downloads anything:
# fetch the list by hand from https://publicsuffix.org/list/public_suffix_list.dat first.
# keeps the list's own licence header and the ICANN rules only (the private section is not
# used, see md/COMPANIES.md), then writes the manifest entry with the hashes.
# usage: scripts/build-companies-data.sh path/to/public_suffix_list.dat [fetch-date YYYY-MM-DD]
set -eu
[ $# -ge 1 ] || { echo "usage: $0 path/to/public_suffix_list.dat [fetch-date]" >&2; exit 2; }
input=$1
fetched=${2:-$(date -u +%Y-%m-%d)}
[ -f "$input" ] || { echo "no such file: $input" >&2; exit 1; }
cd "$(dirname "$0")/.." || exit 1
out=Sources/Companies/Resources

version=$(sed -n 's#^// VERSION: ##p' "$input" | head -1)
commit=$(sed -n 's#^// COMMIT: ##p' "$input" | head -1)
[ -n "$version" ] && [ -n "$commit" ] || { echo "no VERSION or COMMIT line in $input" >&2; exit 1; }
grep -q 'Mozilla Public' "$input" || { echo "licence header (MPL) not found in $input" >&2; exit 1; }

# header = every line before the ICANN section; rules = non-comment lines inside it
{
  awk '/^\/\/ ===BEGIN ICANN DOMAINS===/ { exit } { print }' "$input"
  echo "// ===BEGIN ICANN DOMAINS==="
  awk '/^\/\/ ===BEGIN ICANN DOMAINS===/ { on = 1; next }
       /^\/\/ ===END ICANN DOMAINS===/   { exit }
       on && !/^\/\// && NF { print $1 }' "$input"
  echo "// ===END ICANN DOMAINS==="
} > "$out/psl.dat"

source_sha=$(shasum -a 256 "$input" | cut -d' ' -f1)
data_sha=$(shasum -a 256 "$out/psl.dat" | cut -d' ' -f1)
rules=$(grep -v '^//' "$out/psl.dat" | grep . | sort -u | wc -l | tr -d ' ')
cat > "$out/manifest.json" <<JSON
{
  "datasets": [
    {
      "name": "Public Suffix List",
      "file": "psl.dat",
      "version": "$version",
      "commit": "$commit",
      "sourceURL": "https://publicsuffix.org/list/public_suffix_list.dat",
      "licence": "MPL-2.0",
      "fetched": "$fetched",
      "sha256": "$data_sha",
      "sourceSHA256": "$source_sha",
      "rules": $rules
    }
  ]
}
JSON
echo "wrote $out/psl.dat ($rules rules) and $out/manifest.json"
