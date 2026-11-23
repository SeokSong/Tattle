#!/bin/sh
# prints the SHAPE of an App Privacy Report export (ndjson) and never a value: key paths, json
# types, string length ranges, number ranges, time stamp formats and offsets, record counts per
# type, line count, file size, longest line. small closed vocabularies (the record type, the kind
# and the category of an access record, the initiated type) are listed because they are format
# words, not user data; every other string is reported by length only.
# needs jq (brew install jq). usage: scripts/privacy-report-schema.sh [file.ndjson]
# default file: the newest export in $TATTLE_FIXTURES/privacy-reports (or ~/dev/tattle-fixtures)
set -eu
command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
file=${1:-}
if [ -z "$file" ]; then
  dir="${TATTLE_FIXTURES:-$HOME/dev/tattle-fixtures}/privacy-reports"
  file=$(/bin/ls -t "$dir"/*.ndjson 2>/dev/null | head -n 1 || true)
fi
[ -n "$file" ] && [ -f "$file" ] || { echo "no export found; pass a file" >&2; exit 1; }

# the file name pattern, with the time stamp digits masked
name=$(basename "$file" | sed -E 's/[0-9]/9/g')
echo "file name shape: $name"
echo "file size bytes: $(wc -c < "$file" | tr -d ' ')"
echo "lines: $(wc -l < "$file" | tr -d ' ') newline-terminated, $(awk 'END{print NR}' "$file") total"
echo "longest line bytes: $(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$file")"
echo "mode: $(stat -f %Lp "$file")"
echo

jq -R -n -r '
  # words that may be printed as values because they are format vocabulary
  def vocab: ["type", "kind", "category", "initiatedType"];
  def mask: gsub("[0-9]"; "9");
  def keypath($p): $p | map(if type == "number" then "[]" else . end) | join(".");

  [inputs | (try fromjson catch {"__unparseable": true})] as $all
  | ($all | map(select(.__unparseable? == true)) | length) as $bad
  | ($all | map(select(.__unparseable? != true))) as $recs
  | "unparseable lines: \($bad)",
    "non-object lines: \($recs | map(select(type != "object")) | length)",
    "",
    ( $recs | map(select(type == "object"))
      | group_by(.type // "(no type)")
      | .[]
      | . as $group
      | ($group[0].type // "(no type)") as $t
      | "== record type \($t): \($group | length) records",
        ( [ $group[] | . as $r
            | [ path(..) as $p | ($r | getpath($p)) as $x | select(($x | type) as $ty | $ty != "object" and $ty != "array") | {k: keypath($p), v: $x} ]
            | .[]
          ]
          | group_by(.k)
          | .[]
          | . as $vals
          | $vals[0].k as $k
          | ($vals | map(.v)) as $v
          | ($v | map(type) | unique | join("|")) as $types
          | ( "  \($k): present \($vals | length)/\($group | length), types \($types)"
              + (if ($v | map(type) | unique) == ["string"] then
                   ", length \($v | map(length) | min) to \($v | map(length) | max), empty \($v | map(select(. == "")) | length), distinct \($v | unique | length)"
                   + (if ($k | IN(vocab[])) and ($v | unique | length) <= 12 then ", words \($v | group_by(.) | map("\(.[0]) \(length)") | join("; "))" else "" end)
                   + (if ($k | test("[Tt]ime[Ss]tamp")) then
                        ", formats \($v | map(mask | sub("[+-]99:99$|Z$"; "<tz>")) | group_by(.) | map("\(.[0]) x\(length)") | join("; ")), offsets \($v | map(capture("(?<o>[+-][0-9]{2}:[0-9]{2}|Z)$").o? // "none") | group_by(.) | map("\(.[0]) x\(length)") | join("; "))"
                      else "" end)
                 elif ($v | map(type) | unique) == ["number"] then
                   ", min \($v | min), max \($v | max), sum \($v | add), distinct \($v | unique | length)"
                   + (if ($v | unique | length) <= 6 then ", values \($v | group_by(.) | map("\(.[0]) x\(length)") | join("; "))" else "" end)
                 elif ($v | map(type) | unique) == ["boolean"] then
                   ", true \($v | map(select(.)) | length)"
                 else "" end) ) ),
        ""
    ),
    ( $recs | map(select(type == "object" and .type == "networkActivity")) as $n
      | "== bundle id and domain shapes (networkActivity)",
        "  distinct bundle ids: \($n | map(.bundleID) | unique | length)",
        "  distinct domains: \($n | map(.domain) | unique | length)",
        "  distinct domain owners (non-empty): \($n | map(.domainOwner) | map(select(. != "")) | unique | length)",
        "  records with an owner: \($n | map(select(.domainOwner != "")) | length) of \($n | length)",
        "  bundle id dot-component counts: \($n | map(.bundleID) | unique | group_by(split(".") | length) | map("\(.[0] | split(".") | length) parts x\(length)") | join("; "))",
        "  bundle ids starting with a reverse-dns first part of 3 letters (com, net, org...): \($n | map(.bundleID) | unique | map(select(test("^[a-z]{2,3}\\."))) | length)",
        "  bundle ids with a recognisable last component (letters only, 3 to 30 chars): \($n | map(.bundleID) | unique | map(select(split(".")[-1] | test("^[A-Za-z]{3,30}$"))) | length)",
        "  bundle ids whose last component is generic (app, ios, mobile, iphone, ipad, release, prod): \($n | map(.bundleID) | unique | map(select(split(".")[-1] | ascii_downcase | IN("app", "ios", "mobile", "iphone", "ipad", "release", "prod", "client", "main"))) | length)",
        "  domains with an ip-literal shape: \($n | map(.domain) | unique | map(select(test("^[0-9.]+$|:"))) | length)",
        "  domains with upper case letters: \($n | map(.domain) | unique | map(select(test("[A-Z]"))) | length)",
        "  domains with a trailing dot: \($n | map(.domain) | unique | map(select(endswith("."))) | length)",
        "  period fields: firstTimeStamp and timeStamp, see formats above"
    )
' "$file"
