# Testing

**Status:** 169 tests across 10 targets, green (2026-11-17). Fixture captures went missing from ~/Desktop on 2026-11-16, so fixture tests currently skip.

## Approach

- Unit tests build bytes by hand, so they never depend on capture files
- Fixture captures are the truth set for whole-pipeline checks
- Every new stage must keep the fixture totals consistent with the stage before it

## Fixture captures

Private folder `~/dev/watch-fixtures` (override with `WATCH_FIXTURES`), outside git and outside iCloud. Real captures hold personal traffic, so nothing in it is committed or shared. The five captures below were lost from the Desktop on 2026-11-16 (recovery: PH-0, or recapture as `legacy-*`).

- Layout: `captures/` (PCAPNG), `scenarios/` (scenario JSON), `reports/` (report JSON, local), `db/`; all mode 0700
- `scripts/fixtures.sh init` creates it; `scripts/fixtures.sh check` fails if the folder is inside a git work tree, under `Mobile Documents`, `/Desktop` or `/Documents`, or group/world readable, then lists files with sizes and writes `MANIFEST.sha256`
- Scenario captures: `Fixtures.scenarios` (`s0-idle` to `s4-link-failures`, `.pcapng`)
- Repo guard: `RepoGuard.scan(root:)` (Tests/TestSupport) and the `repoIsClean` test fail on capture or database files, iPhone UDIDs or 40-hex words in text files, and IP addresses or hostnames under `Tests/Expected/`. Skips `.build`, `.git`, `img`. Exceptions: a 40-hex value on a line mentioning "salt" (public QUIC salts), and the placeholder UDID quoted in the plan. Violations print path and rule only, never the matched text

| File | Size | Packets | Interfaces | What it shows |
|---|---|---|---|---|
| watch-test.pcap | 18.9 MB | 13,151 | pdp_ip0, en2, utun4 | First capture, cellular |
| watch-safari-test.pcap | 1.9 MB | 1,860 | utun4, pdp_ip0, en2 | Safari: example.com, iana.org |
| watch-youtube-test.pcap | 34.3 MB | 30,720 | pdp_ip0, utun4, en2, en0 | YouTube, ~50 s |
| multi-app-test.pcap | 62.5 MB | 50,766 | utun4, en0, en2, pdp_ip0 | TikTok then Instagram, ~35 s |
| watch-clean-test.pcap | 0.96 MB | 1,292 | en0, en2, utun4 | Short, ~15 s, TikTok DNS |

- All five are PCAPNG with the same 24-byte trailer
- They contain real traffic metadata: keep them out of git

## Checks per stage

| Stage | Check |
|---|---|
| Reader | Packet and per-process counts equal tcpdump's (done) |
| Decoder | Packets decoded + skipped = packets read |
| Flows | Packets and bytes summed over flows = summed over packets |
| Domains | DNS names include the ones seen in tcpdump output (TikTok, Instagram chains) |
| Storage | Reloaded session gives the same totals as in memory |

## Benchmarks

| What | Target | Result |
|---|---|---|
| Reader, multi-app (50,766 packets) | — | 0.11 s release, Mac |
| Full pipeline (`bench`, multi-app, release) | ≥1,500 packets/s (N1) | ~620,000 packets/s (best of 3, 2026-11-16) |
| Synthetic pipeline throughput (`syntheticThroughput`, 200,000 hand-built UDP packets, `store: nil`) | ≥50,000 packets/s (sanity floor) | ~200,000 packets/s (debug test build, 2026-11-17) |
| Memory, open flows | — | Not measured |
| Live capture (phone, YouTube), 2026-11-16 | Streams, stops on Ctrl-C | 26,916 packets / 177 s, 0 malformed, 91 flows, 25 SNI, 30 DNS, exit 0 |

- Rust only comes up if the full pipeline misses N1 by a clear margin

## Fixture tests

- Tests that need a capture read the directory from `WATCH_FIXTURES` and skip when it's unset, so `swift test` is green on any machine
- Shared helper in `Tests/TestSupport` (a plain target, not a test target): `fixtureURL("watch-clean-test.pcap") -> URL?`, plus the byte builders from the PCAPNG tests (little-endian block, option, packet) so every test target can build captures by hand
- Fixture tests print their counts, so a run doubles as a report
- `CaptureTests` run as one `@Suite(.serialized)`: they spawn processes, send signals and install process-wide handlers, so parallel runs raced (pid files written before stream data, EOF before exit). Fakes write their pid after the data. If a run ever hangs, `pkill -9 -f swiftpm-testing-helper` clears stale runners; swift-testing buffers output when not on a tty, so a killed run shows nothing

## Commands

```
swift test
scripts/fixtures.sh check
WATCH_FIXTURES=~/dev/watch-fixtures swift test
swift build -c release && .build/release/WatchCapture read ~/dev/watch-fixtures/captures/watch-clean-test.pcap
```

## Open questions

- A VPN capture and a long (30+ min) capture to add to the set

## See also

[PCAPNG.md](PCAPNG.md) · [DECODER.md](DECODER.md) · [FLOWS.md](FLOWS.md)
