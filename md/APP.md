# App

**Status:** Working prototype (2026-11-17). Connect → admin password → Live → Stop → Sessions all verified on the phone (35,577 packets / 446 flows in one run). Stop ends tcpdump with KILL after ~2 s by design (see [CAPTURE.md](CAPTURE.md)). Known cosmetic bug: system rows other than mDNSResponder say "lookups for" instead of "on behalf of".

Mockups (made before the app was built):

| Connect | Grant access |
|---|---|
| ![Connect](../img/01-connect.png) | ![Grant access](../img/02-grant-access.png) |
| **Live capture** | **Settings** |
| ![Live capture](../img/03-live-capture.png) | ![Settings](../img/04-settings.png) |

## Purpose

- The Mac app the user drives: connect, start, watch live, stop, review, delete
- Assumes the Mac shows the data in V1 (open question in [DESIGN.md](DESIGN.md#10-open-questions))

## Screens

| Screen | Shows | Requirements |
|---|---|---|
| Connect | USB, device link and capture access checks, Start button | F1 |
| Grant access | Allow once / Always allow / Cancel, what root is used for | N6 |
| Live capture | Red capture bar with timer and Stop, totals, traffic by process | F2, F3, F4 |
| Settings | Revoke access, retention, delete all, diagnostic capture | N2, N6 |

## Live capture

- Capture bar always visible while capturing, with a large Stop (F3)
- Totals: packets, flows, share unattributed
- By process: name, PIDs, packets, IP bytes
    - Unattributed is its own row, never hidden or merged
    - System processes labelled as system
    - `mDNSResponder` rows say which apps the lookups were for
- Labelled "Live · this session" so it can't be mistaken for history

## Rules for what the UI says

- Show counts as packets or bytes, never as "data sent to company X"
- DNS-only hostnames are labelled "from DNS", not "contacted"
- Unknown is written as unknown, never left blank or guessed

## Later

- Session history list and per-session detail
- Per-flow view with server name and domain evidence
- Filter by app (default: All Apps)

## Implementation spec (prototype, free mode)

Target `WatchApp` (SwiftUI, SwiftPM executable, no app bundle yet; run with `swift run WatchApp` as the normal user). Depends on `Capture`, `Pipeline`, `Storage`, `Attribution`, `Flows`, `Domains`, `PacketDecoder`, `PCAPNG`. Tests in `WatchAppTests` for the non-UI logic.

### Getting root without running the GUI as root

- The app never runs as root. On Start it launches a privileged script through `osascript -e 'do shell script "/bin/sh <scriptPath>" with administrator privileges'`, which shows the native admin-password dialog (the "Grant access" screen's **Allow once**). This is a stand-in for the `SMAppService` helper; the protocol is the same three steps
- `PrototypeCaptureLauncher` (in the `Capture` target):
    - makes a private run directory (`0700`, under `~/Library/Application Support/Watch/run/<uuid>/`) holding `script.sh` (`0600`), a FIFO `stream`, and the path of a `stop` marker
    - `script.sh`: run `rvictl -s <udid>`; require `[SUCCEEDED]` and parse `with interface <rviN>`; `exec tcpdump -i <rviN> -n -p -s 0 -U -P -w - > stream &`; loop `while [ ! -e stop ] && kill -0 $pid; do sleep 0.2; done`; `kill -INT $pid; wait $pid`; `rvictl -x <udid>`; exit codes 1 rvi failed, 2 tcpdump failed. Its stderr goes to `log` in the run dir
    - `start(udid:) async throws -> FileHandlePacketSource`: writes the script, runs osascript on a background task, opens the FIFO for reading (opening blocks until tcpdump opens the write end; do it on a background task with a 60 s timeout for the password dialog) and returns the source
    - `stop() async`: creates the `stop` file, waits for osascript to exit (up to 5 s), deletes the run directory including the script (the udid lives only there, briefly, and in memory)
    - osascript cancelled by the user → `CaptureError.accessDenied`; nothing started
- `FileHandlePacketSource` (in `PCAPNG`): a `PacketSource` over a `FileHandle`, 64 KB reads through `PCAPNGStreamParser`; `ProcessPacketSource` can be rebuilt on top of it, but leave it as is
- `DeviceLookup` (in `Capture`): move the devicectl lookup out of the CLI into `public struct DeviceLookup { static func wiredDevices() async throws -> [DeviceSummary] }` with `DeviceSummary { name, udid, transport, pairing, tunnel }`; the CLI's `capture --device` and the app both use it. `DeviceSummary` is never printed whole; views show `name` only

### App structure

- `@main struct WatchApp: App` with `NSApplicationDelegateAdaptor` that sets `NSApp.setActivationPolicy(.regular)` and activates the app (needed when launched from `swift run`)
- `@MainActor final class AppModel: ObservableObject` owns everything the views show:
    - `deviceStatus: DeviceStatus?` refreshed every 5 s while on the Connect screen (devicectl is slow; never block the main thread)
    - `captureState: idle | requestingAccess | starting | capturing(since: Date) | stopping | failed(message)`
    - `liveStats: PipelineStats`, `liveFlows: [Flow]`, refreshed every 2 s from the pipeline (`stats`, `flowsSnapshot()` with `retainFlows: true`)
    - `processRows: [ProcessRow]` computed from `liveFlows`: group by `Attributor.attribute(flow.tally)` → app name (or "Unattributed", "System: name"), with pid set, packets, IP bytes; sorted by bytes
    - `sessions: [SessionRow]` from `Store.sessions()` plus per-session packet/flow counts
    - settings: `retentionDays` (7 default, `@AppStorage`), `diagnosticCapture` (off)
    - `startCapture()`: device check → `requestingAccess` → launcher.start → new `Store(path:)` for the pipeline (the app keeps its own `Store` for reads; SQLite WAL allows both) → `CapturePipeline(... retainFlows: true)` → `run` on a task → `capturing`. Any failure → `failed(message)` with the launcher stopped
    - `stopCapture()`: `stopping` → `launcher.stop()` → wait for `run` to return → `pipeline.stop(reason: .captureStopped)` → `idle`, sessions refreshed
    - on launch: `store.markInterruptedSessions()`, `store.expire(olderThan: retentionDays × 86400)`
- Views, one file each, matching the mockup (see the mockups above):
    - `ConnectView`: three check rows (USB, Device link, Capture access = "Asked on start"), Start button enabled only when ready
    - `AccessView`: the explanation and three buttons; **Allow once** triggers the osascript prompt; **Always allow** disabled with the note "needs the signed helper (later)"; Cancel
    - `LiveView`: red capture bar (dot, "Capturing", mm:ss timer, interface, Stop), three tiles (packets, flows, % unattributed), the by-process table (Unattributed row always present, system rows labelled), top 10 flows by bytes with server name and attribution
    - `SessionsView`: list of past sessions (start, duration, packets, flows), select one to see its process totals from `Store.processTotals` and top flows
    - `SettingsView`: capture access (shows "Asked each time (prototype)"; Revoke disabled), retention picker 1/3/7 days, Delete all (with confirmation), diagnostic capture toggle (writes the raw stream to `~/Library/Application Support/Watch/diagnostic-<date>.pcapng` via a tee; shown in the capture bar when on)
    - Window: sidebar (Connect, Live, Sessions, Settings) + detail, 880×560 minimum. Live is selected automatically when a capture starts
- The UI never shows the udid or the device hash. Addresses and hostnames are shown (that is the product), nothing else leaves the process

### Tests (`WatchAppTests`, no UI)

- `processRows` from hand-built flows: an app with two pids collapses to one row; `.none`-only tally → "Unattributed" row; system process → "System:" row; sorted by bytes
- `PrototypeCaptureLauncher.renderScript(udid:, runDirectory:)` contains the rvictl, tcpdump `-P -w -` and `rvictl -x` lines, the stop loop, and exits non-zero without `[SUCCEEDED]`
- Run directory and script are created `0700`/`0600` and removed by `stop()` even if `start` failed
- `DeviceLookup` decodes a saved devicectl JSON sample (wired and absent cases)

### Acceptance

- `swift build` and `swift test` green; `swift run WatchApp` opens the window as the normal user
- Live run on the phone (user): Start → password dialog → Live screen fills → Stop → session appears in Sessions; `rvictl -l` empty afterwards

## Open questions

- SwiftUI app target alongside the SwiftPM package, or move to an Xcode project when the helper needs signing?
- Menu bar item showing capture state?

## See also

[CAPTURE.md](CAPTURE.md) · [ATTRIBUTION.md](ATTRIBUTION.md) · [STORAGE.md](STORAGE.md)
