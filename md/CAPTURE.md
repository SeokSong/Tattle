# Capture

**Status:** Done, live-tested (2026-11-16). First run found the missing `-P` flag; second run: 26,916 packets in 177 s, Ctrl-C stopped cleanly, `Stream ended: clean`, tcpdump exit 0, 91 flows + 30 DNS answers saved. `rvictl -x` cleanup confirmed on the earlier failed run. `Sources/Capture`, 9 tests against fake rvictl/tcpdump scripts; `capture` CLI command. Signals: plain C handlers (not SIG_IGN) so tcpdump keeps the default Ctrl-C behaviour; the summary prints how the stream ended and tcpdump's exit status. `--device <name>` filters wired devices by name (see below). Awaiting the first live run.

## Purpose

- Start and stop the iPhone's virtual interface and tcpdump from Watch (F2)
- Hand tcpdump's output to the PCAPNG reader as a live stream (F4)
- Make sure nothing keeps running after Stop, a crash, or an unplugged cable

## Commands

| Step | Command | Notes |
|---|---|---|
| Start RVI | `rvictl -s <udid>` | Prints `[SUCCEEDED] with interface rvi0` |
| Check | `rvictl -l` | Lists active devices |
| Capture | `tcpdump -i rvi0 -n -p -s 0 -U -P -w -` | PCAPNG to stdout, one flush per packet |
| Stop capture | SIGINT to tcpdump | Lets it finish writing the last block |
| Stop RVI | `rvictl -x <udid>` | Removes `rvi0` |

- `-U` matters: without it tcpdump buffers output and the live view lags
- `-P` matters (found in the first live run, 2026-11-16): without it Apple's tcpdump writes a 24-byte classic pcap header before the PCAPNG data. On a file that header ends up at the end (the "trailer" the reader tolerates); on stdout it comes first and the parser rejects it. With `-P` the stream is pure PCAPNG from byte 0
- `-s 0` keeps whole packets. Needed for DNS answers and SNI. Raw bytes are dropped after decoding (N2)
- tcpdump warns `rvi0: That device doesn't support promiscuous mode`. Harmless: capture works. Could pass `-p` to skip the attempt
- `rvi0` shows `mtu 0` in `ifconfig`. Also harmless

## Admin access

- `rvictl` and `tcpdump` on `rvi0` need root
- Found live (2026-11-16): a tcpdump started as a background job of a script ignores SIGINT (shell rule for `&` jobs in non-interactive shells) and, in practice, survived SIGTERM too; `set -m` alone did not fix it: the macOS privilege helper (`do shell script ... with administrator privileges`) starts the script with INT and TERM ignored, and a shell cannot un-ignore inherited signals. tcpdump is launched through a perl wrapper that resets INT/TERM to default. The 2026-11-17 run showed that was not the cause either: tcpdump catches INT and TERM itself and exits only when its blocking read on `rvi0` returns (the CLI's Ctrl-C ended with exit status 0, a graceful exit). A 5 s wait did not help either (run of 2026-11-17 10:50: no exit stats printed, KILL after 7 s). Working explanation, unconfirmed: tcpdump acts on INT only when its blocking read on `rvi0` returns, which may not happen on a quiet phone. Decision (2026-11-17): accept KILL as the normal end of an app capture. Data is safe (`-U` flushes every packet; the reader tolerates a truncated last block). Waits are 1 s after INT and 0.6 s after TERM, so Stop takes about 2 s. Confirming test, if ever needed: `capture --duration 15` with the phone locked
- This is why the Mac companion is distributed outside the Mac App Store ([DESIGN.md](DESIGN.md#6a-distribution-and-app-store-priority-1)). Inside the sandbox none of this is permitted
- Two designs, picked by the distribution decision

| Mode | How root is obtained | Needs |
|---|---|---|
| Local / free | The CLI is run with `sudo` from a terminal; later, the app asks once per launch through an `AuthorizationRef` prompt and runs the helper as root | Nothing |
| Developer ID | `SMAppService.daemon` helper, approved once in System Settings, revocable | $99/yr program, signing, notarization |

- The helper's protocol is the same in both modes: `start(udid) → rvi name`, `capture(rvi) → pcapng stream`, `stop(udid)`. Only how it gets root changes
- V1 (Developer ID): a privileged helper registered with `SMAppService` (macOS 13+)
    - First Start asks: Allow once / Always allow / Cancel
    - "Always allow" registers the helper; it shows in System Settings › Login Items
    - Settings › Revoke access unregisters it (N6)
- The helper does three things only: start RVI, run tcpdump on `rvi0`, stop both
    - Never a general root shell
    - Takes no free-form arguments from the app beyond the device id
- Needs a signed app bundle. Until then the prototype uses an admin password prompt each run

## Stop and cleanup

- Stop: SIGINT tcpdump, wait briefly, then SIGKILL if still running. Then `rvictl -x`
- On launch: if Watch started an RVI device that is still active, stop it
- Every exit path closes the capture session (see failure table in [DESIGN.md](DESIGN.md#8-failure-handling))

## Stall watchdog and link health

- Problem: a pulled cable or a dropped `rvi0` can leave tcpdump blocked on a read while the pipeline's flush timer makes the session look alive (review 03-6)
- A timer task (`runStallWatchdog` in `Sources/Capture/StallWatchdog.swift`) wakes every `checkEvery` (5 s) and compares the clock with `lastByteAt`. The packet path only stores a timestamp per 64 KB chunk read (`ProcessPacketSource.lastByteAt`, `FileHandlePacketSource.lastByteAt`)
- The clock, the sleep and the link check are injected, so tests use a fake clock and a fake `ifconfig`; none sleeps for 15 s
- Not active during start: the existing access timeout (the plan says 30 s; the launcher uses 60 s for the password dialog) covers that phase. Both sources start `lastByteAt` at their creation time

| Signal (checked in this order) | Source | Verdict | What happens |
|---|---|---|---|
| tcpdump or the capture script exited | `terminationStatus` (CLI), `isFinished` (app) | `processExited` | The watchdog stops. The existing exit handling decides: error, or `captureStopped` |
| bytes read within `stallAfter` (15 s, wall clock, strictly more is a stall) | `lastByteAt` | `ok` | Nothing |
| stalled, link check passes | `ifconfig <rviN>` exits 0 and the flags on its first line list `UP` | `quietButAlive` | Nothing ends and nothing is recorded; the gap is counted from packet time when packets resume. The check repeats at most every 5 s |
| stalled, link check fails | `ifconfig` exits non-zero, or no `UP` flag | `linkDown` | `controller.stop()` (SIGINT, KILL, `rvictl -x`; the app's launcher stop), then `pipeline.stop(reason: .interrupted)`. Everything received so far is saved |

- Thresholds: `stallAfter = 15`, `checkEvery = 5`. Evidence: across five real captures the longest silence between packets was 3.07 s, including while the phone was locked (background services keep traffic flowing), so 15 s does not fire on a locked phone. Worst case from a pull to the end of the session: 15 s plus up to 5 s, about 20 s
- The link check needs no root (`CaptureTools.ifconfig`, `/sbin/ifconfig`) and never prints or logs the device id: only the interface name is passed. A name with anything but letters and digits is refused
- The app does not know the interface name (the privileged script parses it), so it takes the first name seen in the packets; before any packet it falls back to `ifconfig -l` and counts any `rvi*` name as present
- Message when the link is lost: "The iPhone link was lost (cable or phone disconnected)"
    - CLI: prints `Capture ended: <message>. Everything received so far was saved`, the usual summary, and exits 2
    - App: the capture screen returns to its error state with the message plus "Everything received so far was saved. Check the cable, then start again." The session appears in the sessions list as `interrupted`
- Validated on a real phone (PH-5, 2026-11-18, CLI, 300 s run with `--diagnostic`), numbers below. The watchdog stays as a backup for silent stalls; it never acted in this run

| Event on the real phone | What was seen |
|---|---|
| Phone locked for one minute (1:00 to 2:00) | The capture kept running. No gap longer than 5 s, so the stored session has `gap_count 0`. A lock does not end a session |
| Cable pulled at about 2:30 | tcpdump noticed within 2 to 3 s. Stderr: `tcpdump: pcap_loop: The interface disappeared`, then `5197 packets captured`, `5209 packets received by filter`, `0 packets dropped by kernel`. Exit status 1 |
| Stored session | `end_reason interrupted`, all 164 flows saved (116 ended `interrupted`) |
| After re-plugging | `rvictl -l` printed "Could not get list of devices" and `ifconfig` listed no `rvi` interface: cleanup was complete |

- Signal that fires first on a cable pull: tcpdump's own exit with the `The interface disappeared` line (not the 15 s stall check). `CaptureController.interfaceDisappeared(in:)` matches that line case-insensitively, with or without the `pcap_loop:` prefix, and it is treated as link lost, not as a failure
    - CLI: `controller.linkLostByTcpdump()` after the stream failed (and no stop was requested) sets the same link-lost state as the watchdog: same message, exit code 2, session `interrupted`
    - App: the launcher parses its run-directory log in `stop()` (`lastLinkLost`); `AppModel.captureEnded` shows the link-lost message when it is set
    - Any other stderr with a non-zero exit is still reported as a failure (`Capture failed: ...`) with the stderr tail
- Kernel drop count on this path: `CapturePipeline.run` stops the pipeline itself when the stream throws, before the caller can read tcpdump's summary. `pipeline.setKernelDroppedProvider` is asked for the count inside `stop`, right before the session stats are written, so the count is stored on every end path (the CLI uses `controller.kernelDropped()`, the app `launcher.kernelDroppedNow()`). Before this fix the stored `kernel_dropped` was NULL although the CLI printed 0
- The silent-stall case (link looks dead but tcpdump neither exits nor prints) is still only covered by the `ifconfig` check, which was not exercised on a real phone
- Not done: reconnecting automatically

### App path: the stream did not end when tcpdump exited (found in 7.1, fixed)

- Symptom: reading `FileHandlePacketSource.events()` inline in `launcherSeesLinkLossInTheScriptLog` never returned (the test had been changed to a polling task, which hid it)
- Root cause: the app reads tcpdump through a FIFO, and macOS `poll()` never reports end of file on a FIFO once its last writer has closed (it returns 0 forever; no `POLLHUP`, no `POLLIN`). A pipe (the CLI path) does report it. The source used `poll()` and read only when it said ready, so the stream never ended when tcpdump exited by itself. Checked with a 20-line C program: write, close, then poll every 300 ms gives `poll=0` indefinitely
- Effect in the app before the fix: after a cable pull the pipeline kept waiting. Only the stall watchdog could end it (15 s of silence, then `ifconfig` shows the interface gone), so the link-lost message took 15 to 20 s instead of the 2 to 3 s tcpdump needs. If tcpdump died with the link still up (a crash, a kill), the watchdog judged the link `quietButAlive` and the app stayed in "capturing" until the user pressed Stop. The CLI was not affected
- Fix: the source sets the descriptor non-blocking and reads after every wake-up (every 100 ms at most), whether `poll()` said ready or not. A quiet writer gives `EAGAIN`, a gone writer gives 0, which ends the stream. One extra failed `read` per 100 ms when idle; none per packet
- Tests: `fileHandleSourceEndsWhenFifoWriterCloses` (a real FIFO, writer closes; fails without the fix) and `launcherSeesLinkLossInTheScriptLog`, which reads the stream inline again with a 10 s bound (`endsWithin`) so a regression fails instead of hanging the suite

## Diagnostic capture

- Off by default. A Settings switch
- When on: also writes the raw PCAPNG stream to disk, shown in the capture bar
- App: files go in `<app support>/Watch/diagnostics/` (0700), named `diagnostic-<ISO 8601 time, ":" as "-">.pcapng` (0600). A second file in the same second gets a `-2`, `-3` suffix (`DiagnosticFiles`, never overwrites)
- App: files older than 24 hours are deleted at app start (only regular files named `diagnostic-*.pcapng`; a symlink with that name is removed, never followed). "Delete all" removes every one
- The files contain raw packets, including any plain-HTTP bodies
- CLI: `--diagnostic <file>` writes where you say and prints "The file is not deleted automatically". Nothing purges it
- Only for debugging the reader and decoder on real traffic

## Running under sudo

- `sudo` sets `SUDO_USER`, `SUDO_UID`, `SUDO_GID`. `capture` uses them only when it runs as root and all three are valid
- The home folder comes from the password database (`getpwnam(SUDO_USER)`), never from `HOME`
- `HOME` under sudo: not yet checked on this Mac. Owner to run `sudo env | grep HOME` and record the result here
- A quoted `"~/x"` reaches the tool unexpanded; under sudo a leading `~/` in `--db` and `--diagnostic` is expanded to the user's home
- After the store opens, the database, `-wal` and `-shm` files are handed back with `lchown` (symlinks are not followed). Again after the final stop, because WAL files can appear later
- Directories that `Store.init` or the diagnostic file created are handed back too
- The diagnostic file is created with `O_CREAT | O_EXCL | O_NOFOLLOW`: it refuses an existing file or a symlink
- The database refuses a path that is a symlink (see [STORAGE.md](STORAGE.md))
- If any hand-back fails, one line is printed: `Could not give <n> file(s) back to the user` (no paths)
- Code: `Sources/Capture/FileOwnership.swift`

## Implementation spec (sudo mode)

Target `Capture`, depends on `PCAPNG` and `Pipeline`. The CLI gains `capture`. Runs as root (`sudo .build/release/WatchCapture capture ...`); the Developer ID helper comes later with the same protocol.

### Types

```swift
public struct CaptureTools: Sendable {           // paths, overridable for tests
    public var rvictl = URL(fileURLWithPath: "/Library/Apple/usr/bin/rvictl")
    public var tcpdump = URL(fileURLWithPath: "/usr/sbin/tcpdump")
    public var ifconfig = URL(fileURLWithPath: "/sbin/ifconfig")   // link check, see "Stall watchdog and link health"
    public var extraTcpdumpArguments: [String] = []
}

public final class ProcessPacketSource: PacketSource, @unchecked Sendable {
    public init(process: Process)                // reads process.standardOutput through PCAPNGStreamParser in 64 KB chunks
    public var terminationStatus: Int32?          // set once the process has exited
    public var lastByteAt: Date                   // when bytes were last read; read by the stall watchdog
}

public actor CaptureController {
    public init(tools: CaptureTools = .init())
    /// starts rvi for the udid, then tcpdump on it. returns the interface name (rvi0) and the source
    public func start(udid: String) async throws -> (interface: String, source: ProcessPacketSource)
    /// SIGINT tcpdump, wait up to 2 s, SIGKILL; then rvictl -x
    public func stop() async
    public static func cleanupStaleInterfaces(udid: String, tools: CaptureTools) async    // rvictl -x if rvictl -l lists it; used on launch
    public func kernelDropped(timeout: TimeInterval = 1) async -> Int?                    // after the process ended; see "Kernel drop summary"
    public func linkLostByTcpdump(timeout: TimeInterval = 1) async -> Bool                // stderr has "The interface disappeared"
    public static func droppedByKernel(in lines: [String]) -> Int?
}
```

- `rvictl -s <udid>` output must contain `[SUCCEEDED]` and `with interface <name>`; parse the name. Anything else → `CaptureError.rviStartFailed(output)` with the udid redacted from the message
- tcpdump arguments: `-i <rvi> -n -p -s 0 -U -w -` plus `extraTcpdumpArguments`. stderr goes to a pipe; keep the last 20 lines for error reporting. The "doesn't support promiscuous mode" warning is suppressed by `-p`
- `start` is idempotent-safe: calling it twice throws `alreadyRunning`
- `stop` must work even if `start` failed halfway (rvi up, tcpdump not): always attempt `rvictl -x`
- Signals: the CLI installs a SIGINT/SIGTERM handler (DispatchSource) that calls `stop` and `pipeline.stop(reason: .captureStopped)`, then exits 0

### Kernel drop summary (6.4)

- On a clean exit tcpdump prints three lines on stderr: `N packets captured`, `N packets received by filter`, `N packets dropped by kernel`. `CaptureController.droppedByKernel(in:)` reads the last line that matches `^\d+ packets? dropped by kernel` (after trimming spaces) and returns the number. Anything else, including `dropped by interface` and a line with text before the number, is ignored
- Unknown is `nil`, never 0. When tcpdump is ended with KILL (the app path: it ignores INT while blocked on rvi) the summary is not printed, so the count stays unknown
- CLI path: after `controller.stop()`, `controller.kernelDropped()` waits up to 1 s for the end of the stderr pipe and parses the 20-line tail, then `pipeline.setKernelDropped` is called before `pipeline.stop`, so `SessionStats` is written once with the count. The summary prints `Kernel dropped: N packets` only when known; a nonzero count adds a warning
- App path: tcpdump's stderr is the run directory's `log`. `PrototypeCaptureLauncher.stop()` parses the whole log before it moves it, and keeps the result in `lastKernelDropped`; `AppModel` passes it to the pipeline before the final stop. The session detail shows a warning only for a known nonzero count
- A nonzero count is a measurement gap: the Mac dropped packets, so totals are too low

### Stale run directories (6.4)

- A crashed app can leave `~/Library/Application Support/Watch/run/<uuid>/` behind, with a root tcpdump still writing to it. The app is not root and cannot signal it, but the script exits when its directory gets a `stop` file or disappears
- On launch `PrototypeCaptureLauncher.cleanStaleRunDirectories(runRoot:ownDirectory:grace:)` creates `stop` in each stale directory, waits 10 s, then removes its files and the directory
- A directory is ours only if all of these hold: it is a real directory (checked with `lstat`, a symlink never qualifies) directly under the run root; its name is exactly a canonical uppercase `UUID().uuidString`; it is owned by this user; it holds only `script.sh`, `stream`, `log`, `osascript.err`, `stop`. Anything else is left alone, untouched and unreported. The directory of a capture in progress is never touched
- The stop file is created with `O_EXCL | O_NOFOLLOW`; files are removed with `unlink` (a link is removed, not its target); there is no recursive delete. The `logs` directory is never opened
- No root needed. A directory that cannot be cleared (for example root-owned files) is returned in `failed` and the app reports it once; it is not a startup failure
- The old log is deleted with the directory; it was not moved to `logs`. Only `stop()` moves logs

### CLI `capture`

```
sudo .build/release/WatchCapture capture (--udid <udid> | --device <name>) [--db <path>] [--duration <seconds>] [--diagnostic <file.pcapng>] [--metrics <file.csv>]
```

- `--device`: resolve the udid through `devicectl list devices --json-output` (wired devices only); `--udid` skips that. Never print the udid; print the device name only
    - Match: case-insensitive exact name first (curly and straight apostrophes are equal), else a unique case-insensitive substring
    - No match, or more than one match: exit 3, the message lists device names only. `DeviceLookup.select(name:from:)`
- Runs `cleanupStaleInterfaces`, `start`, builds the pipeline (store at `--db` or none), prints a `Capturing on rvi0 ... Ctrl-C to stop` line, then a stats line every 2 s (packets, flows open, DNS, SNI). On stop prints the same summary as `flows`, then `Kernel dropped: N packets` when tcpdump reported it
- `--duration`: stop automatically after that many seconds (for scripted tests)
- `--diagnostic`: also tee the raw stream to that file (the opt-in diagnostic capture); print a warning line that raw packets are being written
- `--metrics`: append one csv row every 2 seconds (`MetricsLog`, plan 6.6): header first, then elapsed seconds, packets, open and peak open flows, pending domains, handshake states, every cap counter, gap count, longest gap (ms), kernel drops and resident memory in bytes. Numbers only. Kernel drops is empty until tcpdump has ended (the count is unknown, never 0), so only the last row has it. The rows come from their own task, never from the packet path. Row k is due k x 2 s after the first row (fixed slots), and the task sleeps until the next slot; a wake-up that is late delays one row, not the ones after it. A slot missed completely is not back-filled, and every row has its real elapsed time, so a gap shows in the file. The first 30-minute run wrote 873 rows instead of 900 because the old timer waited 2 s after each actual write: with a 1.03 s wake-up the period became 2.06 s (1,800 / 873), a drift and not skipped samples; a last row is written after the pipeline stops. The file is created like the diagnostic file (`O_CREAT | O_EXCL | O_NOFOLLOW`, 0600, handed back to the user under sudo): an existing file or symlink is refused (exit 1) and a missing parent directory is not created
- `WatchCapture metrics <file.csv>` reads such a file back: duration, rows, min, max and last resident memory, the least-squares slope over the last two thirds of the run (bytes per minute), peak open flows, gaps, and a verdict. "memory flat" means a slope under 1 MB per 10 minutes (our threshold; the plan names none). Exit 0, or 1 when the file is unreadable or not a metrics file
- Exit codes: 0 stopped by user or duration, 1 rvi failed, 2 tcpdump failed (print its last stderr lines), 3 device not found

### Tests (no phone needed)

- `FakeTcpdump`: `CaptureTools.tcpdump` pointed at a shell script in the test's temp dir that `cat`s a fixture file in 4 KB chunks with a short sleep, and `rvictl` at a script that prints `Starting device [SUCCEEDED] with interface rvi9` for `-s` and nothing for `-x`/`-l`
- `start` returns `rvi9`; the source yields the fixture's packet count and `.end(.pcapTrailer)` when the script finishes
- `stop` while the script is still running: returns within 3 s, the script is gone, `rvictl -x` was called (the fake script appends its argv to a log file the test reads)
- rvictl printing `[FAILED]` → `rviStartFailed`, no tcpdump started
- tcpdump exiting non-zero immediately → the source's stream throws and `terminationStatus` is set
- Fixture (`WATCH_FIXTURES`): full `capture`-style run through the fake tools into a temp `Store`, flows count equals the `flows` command's count for the same file

### Acceptance

- `swift test` green; `capture --help` prints usage without root
- Live run on the phone (user): streams, stats update, Ctrl-C stops cleanly, `rvictl -l` shows nothing afterwards. Note whether the stream ended with `.pcapTrailer` or `.cleanEnd`

## Open questions

- Does tcpdump write the 24-byte trailer when writing to stdout?
- How long can RVI run before it drops? Needs a long capture
- Helper signing and notarization while developing in VS Code / SwiftPM

## See also

[DEVICE.md](DEVICE.md) · [PCAPNG.md](PCAPNG.md) · [APP.md](APP.md)
