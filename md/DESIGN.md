# Tattle Design Doc

Requirement IDs (F, I, N) are defined in [OVERVIEW.md](OVERVIEW.md#requirements).

## 1. Goals and non-goals

- Goals
    - Capture an iPhone's traffic over USB without a jailbreak
    - Tie traffic to the process that sent it, using Apple's own metadata
    - Show connections, bytes and hostnames per app, live
    - Never guess: every number traces back to observed packets (I6)
    - Keep the user in control: visible capture, immediate stop, local data, easy delete
- Non-goals (V1)
    - iPhone app, Windows, Linux
    - Decrypting TLS or QUIC
    - Company classification, geolocation, map
    - Website-level filtering (V3)
    - Blocking

## 2. Components

| Component | Doc | Owns |
|---|---|---|
| Device | [DEVICE.md](DEVICE.md) | USB and CoreDevice checks |
| Capture | [CAPTURE.md](CAPTURE.md) | rvictl, tcpdump, admin access, stop and cleanup |
| PCAPNG reader | [PCAPNG.md](PCAPNG.md) | Blocks to packets, Apple process blocks, trailer |
| Packet decoder | [DECODER.md](DECODER.md) | Link, IP and TCP/UDP headers, byte counts |
| Flows | [FLOWS.md](FLOWS.md) | Flow key, timeouts, process tally |
| Domains | [DOMAINS.md](DOMAINS.md) | DNS answers, SNI, the handshake buffer |
| Attribution | [ATTRIBUTION.md](ATTRIBUTION.md) | Process evidence to app identity |
| Storage | [STORAGE.md](STORAGE.md) | Database, schema, retention |
| Pipeline | [PIPELINE.md](PIPELINE.md) | Wiring, flushing, the CLI |
| App | [APP.md](APP.md) | Mac screens and capture controls |
| Testing | [TESTING.md](TESTING.md) | Fixtures, count checks, benchmarks |

## 3. Architecture

```
Device check ──▶ Capture (rvictl + tcpdump) ──stdout──▶ PacketSource
                                                           │ Packet
                                                           ▼
                                                    Packet decoder
                                       ┌──────────────────┼──────────────────┐
                                       ▼                  ▼                  ▼
                                  Flow table        DNS + SNI buffer    raw bytes dropped
                                       │                  │
                                       └──────┬───────────┘
                                              ▼
                                     Storage (every few seconds)
                                              ▼
                                   Attribution (when reading)
                                              ▼
                                             App
```

- One direction only: each stage takes the previous stage's output, nothing calls backwards
- Raw packet bytes exist only between the reader and the decoder (plus the capped handshake buffer, see [DOMAINS.md](DOMAINS.md))
- Attribution runs over stored evidence, so it can be changed and rerun without recapturing (I4)

### PacketSource

- One protocol in front of everything that reads packets
    - `PCAPNGFileSource`: reads a capture file. Used by tests and the `read` command
    - `PCAPNGStreamSource`: reads tcpdump's stdout during a live capture
- Everything after it only sees `Packet` values, so fixture tests run the same code as live captures
- Also leaves room for other capture methods later (for example talking to the iPhone's capture service directly), without changing the rest

## 4. Live capture path

1. App: user presses Start
2. Device: check USB + CoreDevice (F1). Fail → show which check failed, stop
3. Capture: get admin access (asked, or remembered) (N6)
4. Capture: `rvictl -s <udid>`, wait for `rvi0`
5. Capture: start `tcpdump -i rvi0 -n -s 0 -U -w -`
6. Create the capture session record (F10), show the capture bar (F3)
7. PacketSource: read blocks from stdout as they arrive
8. Decoder: decode each packet, hand it to the flow table and the DNS/SNI step, drop the raw bytes
9. Flow table: update flows. Storage saves new and changed flows every few seconds (I7)
10. Stop: stop tcpdump, stop RVI, flush and close every open flow, close the session (F2)

## 5. Data model

Separate entities, never merged into one record (packets, flows, domains and apps are different things).

- **CaptureSession**: id, start, end, source (`rvi`), device (hashed id, name), Tattle version
- **Packet** (memory only, never stored): interface, timestamp, direction, captured and original length, `proc`, `eproc`, raw bytes
- **NetworkFlow**: session, protocol, local IP:port, remote IP:port, interface, first and last seen, packets and bytes in each direction, end reason, process tally
- **ProcessTally** (per flow): `(proc name, proc PID, eproc name, eproc PID) → packet count`, "none" included
- **DomainObservation**: session, time, source (`dns` | `sni`), hostname, CNAME chain, answer IPs, linked flow (for SNI), `proc`/`eproc`
- **AppIdentity**: derived when reading, never stored over the evidence (see [ATTRIBUTION.md](ATTRIBUTION.md))

Detail and field types: [FLOWS.md](FLOWS.md), [DOMAINS.md](DOMAINS.md), [STORAGE.md](STORAGE.md).

## 6. Key decisions

| Decision | Choice | Why | Doc |
|---|---|---|---|
| Unit of analysis | Flow, not packet | Packets are too many to show; a flow is a connection a user can reason about | [FLOWS.md](FLOWS.md) |
| Flow key | Protocol + local IP:port + remote IP:port | One connection = one flow. Process in the key would split connections when ~1% of packets lack it | [FLOWS.md](FLOWS.md) |
| Flow end | TCP: FIN/RST, else idle. UDP/QUIC: 2 min idle | Ports are reused; long timeouts merge unrelated conversations | [FLOWS.md](FLOWS.md) |
| Bytes | IP total length + payload length. No link-layer headers | Same traffic counts the same on Wi-Fi and cellular | [DECODER.md](DECODER.md) |
| Input | Stream tcpdump stdout (`-U -w -`) | Live view, no raw file on disk | [CAPTURE.md](CAPTURE.md) |
| Raw packets | Dropped after decoding. Opt-in diagnostic capture, 24 h | Privacy. Diagnostics only to debug the parser | [CAPTURE.md](CAPTURE.md) |
| Retention | Records 7 days, delete any time, expire whole sessions | Matches the App Privacy Report window; sessions stay consistent | [STORAGE.md](STORAGE.md) |
| Payload | Read DNS and SNI only, never store content | Useful hostnames; nothing readable is kept | [DOMAINS.md](DOMAINS.md) |
| Admin access | Privileged helper via `SMAppService`, macOS 13+ | Ask once or always, revoke from Settings or System Settings | [CAPTURE.md](CAPTURE.md) |
| Language | Swift | Needs macOS APIs anyway; the reader is fast enough. Rust only if benchmarks say so | [TESTING.md](TESTING.md) |

## 6a. Distribution and App Store (priority 1)

- The Mac capture app **cannot** be a Mac App Store app: store apps must use the App Sandbox, which blocks root helpers, `rvictl`, `tcpdump` and `/dev/bpf*`. No entitlement exists for this
- Split
    - iOS app → App Store. Public APIs only (guideline 2.5.1), full data-use disclosure (5.1.1), no Network Extension packet logging (TN3120). Nothing in it captures; it imports the App Privacy Report and, later, records from the Mac
    - Mac companion → Developer ID signed and notarized, distributed from our own site or GitHub, like Wireshark. The privileged helper is allowed there
- Cost: both need the Apple Developer Program, $99/year. Until then everything runs locally and unsigned at no cost; the iOS app can sideload with a free personal team (7-day expiry)
- Everything in sections 2–6 is independent of this choice except the helper in [CAPTURE.md](CAPTURE.md) and the app shell in [APP.md](APP.md)
- Decision (2026-11-16): **stay free for now.** Everything runs locally and unsigned; capture runs with `sudo` from a terminal. The helper keeps the same protocol so Developer ID signing can be added later. The $99 program is deferred until the pipeline works and publishing is wanted

## 6b. Module layout and build order

| Target | Depends on | Doc | Order |
|---|---|---|---|
| `PCAPNG` | — | [PCAPNG.md](PCAPNG.md) | 1 |
| `PacketDecoder` | PCAPNG | [DECODER.md](DECODER.md) | 2 |
| `Flows` | PacketDecoder | [FLOWS.md](FLOWS.md) | 3 |
| `Domains` | PacketDecoder, Flows | [DOMAINS.md](DOMAINS.md) | 4 |
| `Storage` | Flows, Domains | [STORAGE.md](STORAGE.md) | 5 |
| `Attribution` | Flows, Domains | [ATTRIBUTION.md](ATTRIBUTION.md) | 5 |
| `Pipeline` | all above | [PIPELINE.md](PIPELINE.md) | 6 |
| `Report` | Flows, Domains, Attribution, Storage, PacketDecoder | [REPORT.md](REPORT.md) | 7 |
| `tattle` (CLI) | Pipeline | [PIPELINE.md](PIPELINE.md) | 6 |
| Capture, App | Pipeline | [CAPTURE.md](CAPTURE.md), [APP.md](APP.md) | after the distribution decision |

- One test target per module. All targets live in `Package.swift` from the start, with placeholder files, so each step only fills in its own folder
- Each step is built by a separate agent from its doc's "Implementation spec", then reviewed. Steps run one at a time: SwiftPM builds every test target into one bundle, so parallel half-finished targets would break each other's test runs

## 7. Alternatives considered and rejected

- Network Extension / packet tunnel VPN on the iPhone
    - Apple's TN3120 warns against using a packet tunnel as a general packet logger
    - Per-app VPN needs managed devices; content filters need supervision
    - App Store rejection risk
- Wi-Fi proxy
    - Not all traffic goes through it, cellular is missed, apps can bypass it, no per-app attribution
- Rust for packet processing
    - No measured bottleneck yet. The Swift reader already handles 50k packets in 0.11 s
- Reading tcpdump's text output (`-k`)
    - Lines are hard to parse reliably and not every line is one packet. The binary PCAPNG reader matches tcpdump's counts exactly
- Process in the flow key
    - Splits one connection into several flows when some packets lack process info
- Hour-long idle timeout
    - Merges unrelated conversations that reuse a port. Long history is a retention question, not a timeout question
- Talking to the iPhone's capture service (`com.apple.pcapd`) directly
    - Could drop rvictl, tcpdump and root, and could work on Windows/Linux
    - Not Apple-supported, untested on iOS 26. Kept as a possible PacketSource later

## 8. Failure handling

| Failure | Behaviour |
|---|---|
| Cable unplugged mid-capture | Measured on a phone: tcpdump exits in 2 to 3 s with "The interface disappeared". Close open flows, end the session as "interrupted" with the link-lost message, stop RVI. A stall with no exit is caught by the 15 s watchdog and an `ifconfig` check. The app reads tcpdump through a FIFO, whose end of file must be read explicitly (see [CAPTURE.md](CAPTURE.md)) |
| tcpdump exits unexpectedly | Same as above, and show its exit code |
| Tattle crashes during capture | On next launch: stop any RVI device Tattle started, close the unfinished session as "interrupted" |
| Parse error mid-stream | Stop the capture, keep what was saved, report the byte offset. Never skip silently (F11) |
| Admin access revoked | Start is refused with a clear message; nothing runs half-started |

## 9. Testing and benchmarks

See [TESTING.md](TESTING.md).

- The five fixture captures are the fixed truth set; counts must keep matching tcpdump
- Every component has unit tests built from hand-made bytes
- N1 (1,500 packets/s) is checked by replaying fixtures through the full pipeline

## 10. Open questions

- Where users view the data in V1: the Mac app (mockup assumes this) or the iPhone via sync
- Database: SQLite directly, GRDB, or SwiftData ([STORAGE.md](STORAGE.md))
- Does any connection carry more than one `proc` value? Check on fixtures once the decoder exists ([FLOWS.md](FLOWS.md))
- VPN / utun double counting: needs a capture with a VPN on ([DECODER.md](DECODER.md))
- Does tcpdump write the 24-byte trailer when streaming to stdout? ([PCAPNG.md](PCAPNG.md))
- Exact meaning of `proc` vs `eproc`, and option `0x8004` ([PCAPNG.md](PCAPNG.md))
