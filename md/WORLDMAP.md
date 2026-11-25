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
| `Camera.swift` | The camera rules (owner, 2026-11-25). `CameraDirector.target`: start close on the user (zoom 2.5, about 1,300 km across); zoom out to fit the start and every line while all head offices are in the United States, Canada or Mexico (by the data's country; a box round the continent when there is none); the first head office elsewhere switches to the whole globe (zoom 0.42), facing the side with the most head offices, turning 3° a second (a full turn in two minutes). The view looks from a little south (at most 12°, a quarter of the view's half-width) so rising arcs show their curve. `step` eases the camera (half-life 0.6 s; zoom on a log scale; longitude the short way round). `Replay`: the Summary's lines nearest first, 0.8 s each, starting 0.35 s apart; the camera fits the lines started so far, then holds still |
| `GlobeView.swift` | SwiftUI `Canvas` drawing: space, a glow round the globe, shaded ocean and land (lit from the upper left), a faint 15° grid, borders, lines that rise off the surface like flight paths (higher for longer lines, at most 0.18 globe radii) with a soft glow, glowing head-office dots, the start point. Camera (centre, zoom) and lines come from outside. Style: Night (owner's choice from three previews; polished after the owner found the first one plain, 2026-11-25) |

- One projection for every view, so "start at the user, zoom out, spin" is one smooth change of centre and zoom
- Speed (Part 0): about 1.1 ms per frame with 300 lines, offscreen at 1400x900
- The outline is built by `scripts/build-world-outline.sh` (downloads a pinned release once, outside the repo)
- A preview draws the globe with made-up traffic to real head offices, for checking the look without the app; the start point is the middle of the contiguous US. From the repo folder:

```sh
swift build --product tattle && .build/debug/tattle globe-preview ~/Desktop/globe.png && open ~/Desktop/globe.png
.build/debug/tattle globe-preview ~/Desktop/globe-world.png 30,10 0.42   # centre latitude,longitude and zoom (0.45 = whole globe)
.build/debug/tattle globe-preview ~/Desktop/globe-live.gif live && open -a Safari ~/Desktop/globe-live.gif     # the camera during a made-up capture
.build/debug/tattle globe-preview ~/Desktop/globe-replay.gif replay && open -a Safari ~/Desktop/globe-replay.gif # the Summary's replay
```

## Next
Part 4 (Live, Summary and Map screen), Part 5 (location and the Settings switch). Plan: md/milestone4/PLAN.md (private).
