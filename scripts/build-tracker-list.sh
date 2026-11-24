#!/bin/sh
# builds Sources/Companies/Resources/tracker/tracker.tsv (domain, company, adguardCategory) from a pinned
# copy of the AdGuard companiesdb tracker list, copies its licence, and refreshes the manifest entry.
# it never downloads anything: run scripts/fetch-tracker-list.sh first.
# usage: scripts/build-tracker-list.sh
# env: TATTLE_TRACKER_LIST  folder with the pinned copy (default $HOME/dev/tattle-fixtures/tracker-list)
set -eu
cd "$(dirname "$0")/.." || exit 1
src=${TATTLE_TRACKER_LIST:-$HOME/dev/tattle-fixtures/tracker-list}
res=Sources/Companies/Resources
out=$res/tracker
manifest=$res/manifest.json
for f in trackers.json companies.json LICENSE adguard-provenance.txt; do
  [ -f "$src/$f" ] || { echo "no $src/$f" >&2; exit 1; }
done
[ -f "$res/tracker-categories.tsv" ] || { echo "no $res/tracker-categories.tsv" >&2; exit 1; }

prov=$src/adguard-provenance.txt
commit=$(awk -F'\t' '$1 == "commit" { print $2 }' "$prov")
fetched=$(awk -F'\t' '$1 == "fetched" { print $2 }' "$prov")
srcsha=$(awk -F'\t' '$1 == "file" && $2 == "trackers.json" { print $4 }' "$prov")
[ -n "$commit" ] && [ -n "$fetched" ] && [ -n "$srcsha" ] || { echo "provenance is missing a field" >&2; exit 1; }
printf '%s' "$commit" | grep -Eq '^[0-9a-f]{40}$' || { echo "provenance commit is not 40 lowercase hex characters" >&2; exit 1; }

actual=$(shasum -a 256 "$src/trackers.json" | cut -d' ' -f1)
[ "$actual" = "$srcsha" ] || { echo "trackers.json does not match its provenance" >&2; exit 1; }
# company names come from companies.json, so it must be the pinned copy too
compsha=$(awk -F'\t' '$1 == "file" && $2 == "companies.json" { print $4 }' "$prov")
[ -n "$compsha" ] && [ "$(shasum -a 256 "$src/companies.json" | cut -d' ' -f1)" = "$compsha" ] \
  || { echo "companies.json does not match its provenance" >&2; exit 1; }

mkdir -p "$out"
raw=$(mktemp "$out/raw.XXXXXX")
sorted=$(mktemp "$out/sorted.XXXXXX")
trap 'rm -f "$raw" "$sorted"' EXIT

jq -r --slurpfile c "$src/companies.json" '
  . as $root
  | .trackerDomains | to_entries[]
  | . as $e
  | $root.trackers[$e.value] as $t
  | $root.categories[($t.categoryId | tostring)] as $cat
  | (if $t.companyId != null then ($c[0].companies[$t.companyId].name | gsub("^\\s+|\\s+$"; ""))
     else ($t.name | gsub("^\\s+|\\s+$"; "")) as $n
          | if ($n | test("^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$")) then "" else $n end
     end) as $company
  | $e.key + "\t" + $company + "\t" + $cat' "$src/trackers.json" > "$raw"

awk -F'\t' -v cats="$res/tracker-categories.tsv" '
  BEGIN { while ((getline line < cats) > 0) { n++; if (n > 1) { split(line, a, "\t"); known[a[1]] = 1 } } }
  function bad(msg) { print "line " NR ": " msg > "/dev/stderr"; failed = 1 }
  {
    if (NF != 3) { bad("not 3 fields"); next }
    if ($1 !~ /^[a-z0-9.-]+$/ || $1 ~ /^\./ || $1 ~ /\.$/ || index($1, "..")) bad("bad domain")
    if ($3 == "") bad("empty category")
    else if (!($3 in known)) bad("unknown category")
    if (index($2, "\r")) bad("carriage return in company")
  }
  END { exit failed }' "$raw"

tab=$(printf '\t')
LC_ALL=C sort -t "$tab" -k1,1 "$raw" > "$sorted"
dups=$(LC_ALL=C cut -f1 "$sorted" | uniq -d)
[ -z "$dups" ] || { echo "duplicate domains in the list" >&2; exit 1; }

{ printf 'domain\tcompany\tadguardCategory\n'; cat "$sorted"; } > "$out/tracker.tsv"
cp "$src/LICENSE" "$out/LICENSE"

version=$(jq -r '.timeUpdated[0:10]' "$src/trackers.json")
sha=$(shasum -a 256 "$out/tracker.tsv" | cut -d' ' -f1)
rows=$(($(wc -l < "$out/tracker.tsv") - 1))
jq --arg v "$version" --arg commit "$commit" --arg d "$fetched" --arg sha "$sha" --arg ssha "$srcsha" --argjson rows "$rows" '
  .datasets = (.datasets | map(select(.file != "tracker/tracker.tsv"))) + [{
    name: "AdGuard companiesdb tracker list", file: "tracker/tracker.tsv", version: $v, commit: $commit,
    sourceURL: "https://github.com/AdguardTeam/companiesdb", licence: "CC-BY-SA-4.0", fetched: $d,
    sha256: $sha, sourceSHA256: $ssha, rules: $rows }]' "$manifest" > "$manifest.new"
mv "$manifest.new" "$manifest"

echo "tracker.tsv: $rows rows, version $version"
echo "rows with an empty company: $(awk -F'\t' 'NR>1 && $2==""' "$out/tracker.tsv" | wc -l | tr -d ' ')"
echo "rows per AdGuard category:"
tail -n +2 "$out/tracker.tsv" | cut -f3 | sort | uniq -c
