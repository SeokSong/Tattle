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
    public var extraTcpdumpArguments: [String] = []
}

public final class ProcessPacketSource: PacketSource, @unchecked Sendable {
    public init(process: Process)                // reads process.standardOutput through PCAPNGStreamParser in 64 KB chunks
    public var terminationStatus: Int32?          // set once the process has exited
}

public actor CaptureController {
    public init(tools: CaptureTools = .init())
    /// starts rvi for the udid, then tcpdump on it. returns the interface name (rvi0) and the source
    public func start(udid: String) async throws -> (interface: String, source: ProcessPacketSource)
    /// SIGINT tcpdump, wait up to 2 s, SIGKILL; then rvictl -x
    public func stop() async
    public static func cleanupStaleInterfaces(udid: String, tools: CaptureTools) async    // rvictl -x if rvictl -l lists it; used on launch
}
```

- `rvictl -s <udid>` output must contain `[SUCCEEDED]` and `with interface <name>`; parse the name. Anything else → `CaptureError.rviStartFailed(output)` with the udid redacted from the message
- tcpdump arguments: `-i <rvi> -n -p -s 0 -U -w -` plus `extraTcpdumpArguments`. stderr goes to a pipe; keep the last 20 lines for error reporting. The "doesn't support promiscuous mode" warning is suppressed by `-p`
- `start` is idempotent-safe: calling it twice throws `alreadyRunning`
- `stop` must work even if `start` failed halfway (rvi up, tcpdump not): always attempt `rvictl -x`
- Signals: the CLI installs a SIGINT/SIGTERM handler (DispatchSource) that calls `stop` and `pipeline.stop(reason: .captureStopped)`, then exits 0

### CLI `capture`

```
sudo .build/release/WatchCapture capture (--udid <udid> | --device <name>) [--db <path>] [--duration <seconds>] [--diagnostic <file.pcapng>]
```

- `--device`: resolve the udid through `devicectl list devices --json-output` (wired devices only); `--udid` skips that. Never print the udid; print the device name only
    - Match: case-insensitive exact name first (curly and straight apostrophes are equal), else a unique case-insensitive substring
    - No match, or more than one match: exit 3, the message lists device names only. `DeviceLookup.select(name:from:)`
- Runs `cleanupStaleInterfaces`, `start`, builds the pipeline (store at `--db` or none), prints a `Capturing on rvi0 ... Ctrl-C to stop` line, then a stats line every 2 s (packets, flows open, DNS, SNI). On stop prints the same summary as `flows`
- `--duration`: stop automatically after that many seconds (for scripted tests)
- `--diagnostic`: also tee the raw stream to that file (the opt-in diagnostic capture); print a warning line that raw packets are being written
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
