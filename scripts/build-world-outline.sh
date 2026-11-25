#!/bin/sh
# builds the world outline for the company map (Milestone 4) from Natural Earth (public domain), 1:110m:
# land polygons and country border lines. downloads a pinned release once into a folder outside the repo
# (developer only; the app never fetches anything), then writes compact text files into
# Sources/WorldMap/Resources: one line per ring or border line, "lon,lat lon,lat ..." rounded to 2 decimals
# (about 1 km, far finer than the map can show). refreshes manifest.json beside them.
# usage: scripts/build-world-outline.sh
# env: TATTLE_NATURAL_EARTH  download folder (default ~/dev/tattle-fixtures/natural-earth)
set -eu
cd "$(dirname "$0")/.." || exit 1
version=v5.1.2
src=${TATTLE_NATURAL_EARTH:-$HOME/dev/tattle-fixtures/natural-earth}
out=Sources/WorldMap/Resources
umask 077
mkdir -p "$src" "$out"
for f in ne_110m_land ne_110m_admin_0_boundary_lines_land; do
  [ -f "$src/$f.geojson" ] || curl -sS -f -m 120 -o "$src/$f.geojson" \
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/$version/geojson/$f.geojson"
done
umask 022

# every ring of every polygon (land) or every line (borders), one per output line
lines='.features[].geometry | if .type == "Polygon" then .coordinates[]
  elif .type == "MultiPolygon" then .coordinates[][]
  elif .type == "LineString" then .coordinates
  elif .type == "MultiLineString" then .coordinates[] else empty end
  | map("\(.[0] * 100 | round / 100),\(.[1] * 100 | round / 100)") | join(" ")'
jq -r "$lines" "$src/ne_110m_land.geojson" > "$out/land.txt"
jq -r "$lines" "$src/ne_110m_admin_0_boundary_lines_land.geojson" > "$out/borders.txt"

entry() {
  printf '{"name": "Natural Earth 1:110m %s", "file": "%s", "version": "%s", "sourceURL": "https://github.com/nvkelso/natural-earth-vector", "licence": "public domain", "sourceSHA256": "%s", "sha256": "%s", "lines": %s}' \
    "$1" "$2" "$version" "$(shasum -a 256 "$src/$3.geojson" | cut -d' ' -f1)" \
    "$(shasum -a 256 "$out/$2" | cut -d' ' -f1)" "$(wc -l < "$out/$2" | tr -d ' ')"
}
printf '{"datasets": [%s, %s]}\n' "$(entry land land.txt ne_110m_land)" \
  "$(entry "country borders" borders.txt ne_110m_admin_0_boundary_lines_land)" | jq . > "$out/manifest.json"
echo "land.txt: $(wc -l < "$out/land.txt" | tr -d ' ') rings, borders.txt: $(wc -l < "$out/borders.txt" | tr -d ' ') lines, $(cat "$out/land.txt" "$out/borders.txt" | wc -c | tr -d ' ') bytes"
