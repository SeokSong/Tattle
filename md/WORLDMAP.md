# WorldMap: the company map (Milestone 4)

Draws where the companies an app contacted are based: a line from the start point to each head office.
A head office, never where the servers are. Head-office data: [COMPANIES.md](COMPANIES.md#head-offices-milestone-4-part-1).

## Parts

| File | Does |
|---|---|
| `Geo.swift` | `GeoPoint`, distance along the surface, great-circle paths (the shortest way over the globe) |
| `Orthographic.swift` | The globe as seen from space: `project`, `unproject` (for dragging), `projectOntoRim` (land that goes behind the globe follows the edge), `visiblePieces` (a line breaks where it goes behind) |
| `WorldOutline.swift` | Land and country borders, Natural Earth 1:110m (public domain), from `Resources/land.txt` and `borders.txt` |
| `MapLines.swift` | One line per head-office place; connections to companies at the same place (rounded to about 1 km) share it. Brightness and width grow with the logarithm of the count: faint and 1 point at 1 connection, full and 3 points at 32 or more (owner, 2026-11-25). Connections with no company or no known head office are counted, not drawn. `nearestFirst` orders lines for the Summary's replay |
| `GlobeView.swift` | SwiftUI `Canvas` drawing: space, ocean, land, borders, lines, head-office dots, start point. Camera (centre, zoom) and lines come from outside. Style: Night (owner's choice from three previews) |

- One projection for every view, so "start at the user, zoom out, spin" is one smooth change of centre and zoom
- Speed (Part 0): about 1.1 ms per frame with 300 lines, offscreen at 1400x900
- The outline is built by `scripts/build-world-outline.sh` (downloads a pinned release once, outside the repo)
- `tattle globe-preview <out.png> [lat,lon] [zoom]` draws the globe with made-up traffic to real head offices, for checking the look without the app; the start point is the middle of the contiguous US

## Next
Part 3 (camera), Part 4 (Live, Summary and Map screen), Part 5 (location and the Settings switch). Plan: md/milestone4/PLAN.md (private).
