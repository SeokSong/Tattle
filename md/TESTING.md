# Testing

**Status:** 389 tests, green with and without fixtures (2026-11-18; Milestone 2 done). By target: Attribution 57, Capture 79, Domains 43, Flows 28, PacketDecoder 21, Pipeline 23, Report 76, Storage 20, TattleApp 19, TattleCLI (includes the PCAPNG reader) 23. Four scripted captures are the fixture set; the baseline is frozen in `Tests/Expected/`.

## Approach

- Unit tests build bytes by hand, so they never depend on capture files
- The synthetic corpus is the CI truth set for whole-pipeline checks: it is generated in code, has hand-computed answers and runs on any machine
- Fixture captures are the local truth set on real traffic
- Every new stage must keep the fixture totals consistent with the stage before it

## Fixture captures

Private folder `~/dev/tattle-fixtures` (override with `TATTLE_FIXTURES`; `WATCH_FIXTURES` and the old folder name `~/dev/watch-fixtures` still work as deprecated fallbacks), outside git and outside iCloud. Real captures hold personal traffic, so nothing in it is committed or shared.

- Layout: `captures/` (PCAPNG), `scenarios/` (scenario JSON), `reports/` (report JSON, local), `db/`; all mode 0700
- `scripts/fixtures.sh init` creates it; `scripts/fixtures.sh check` fails if the folder is inside a git work tree, under `Mobile Documents`, `/Desktop` or `/Documents`, or group/world readable, then lists files with sizes and writes `MANIFEST.sha256`
- Scenario captures: `Fixtures.scenarios` (`s0-idle` to `s4-link-failures`, `.pcapng`)
- Repo guard: `RepoGuard.scan(root:)` (Tests/TestSupport) and the `repoIsClean` test fail on capture or database files, iPhone UDIDs or 40-hex words in text files, and IP addresses or hostnames under `Tests/Expected/`. Skips `.build`, `.git`, `img`. Exceptions: a 40-hex value on a line mentioning "salt" (public QUIC salts), and the placeholder UDID quoted in the plan. Violations print path and rule only, never the matched text

Scripted captures, recorded 2026-11-18 with `capture --diagnostic` (scenario scripts in the milestone plan; scenario JSON in `scenarios/`):

| File | Size | Packets | Flows | Scenario |
|---|---|---|---|---|
| s0-idle.pcapng | 7.0 MB | 8,832 | 243 | Phone on the Home Screen, then locked. An email notification arrived during it |
| s1-safari.pcapng | 2.3 MB | 2,975 | 57 | One private Safari tab: two sites |
| s2-two-apps.pcapng | 49.4 MB | 40,665 | 191 | Two social apps one after the other |
| s3-youtube-quic.pcapng | 106.5 MB | 82,895 | 223 | A video app playing, mostly QUIC |

- Scenario windows follow what was actually done, not the script: the timing was not exact. Each scenario file says why in `notes`
- The five Milestone 1 captures (`watch-test`, `watch-safari-test`, `watch-youtube-test`, `multi-app-test`, `watch-clean-test`) were lost from the Desktop on 2026-11-16 and are not part of the set
- They contain real traffic metadata: keep them out of git

## Long run: metrics log (plan 6.6)

One optional 30-minute capture shows whether memory is flat. Needs the phone; the owner runs it.

- Capture: `sudo .build/release/tattle capture --device "<name>" --db ~/dev/tattle-fixtures/db/s5-long.sqlite --metrics ~/dev/tattle-fixtures/reports/s5-metrics.csv --duration 1800` (no `--diagnostic`: raw packets are not needed). Use the phone normally: browse, a video for 10 minutes, then locked for 10 minutes. Note the time of each step
- Read: `.build/release/tattle metrics ~/dev/tattle-fixtures/reports/s5-metrics.csv`

| Output line | Meaning |
|---|---|
| Duration, rows | length of the run; one row per 2 s, so about 900 for 30 minutes |
| Resident memory | min, max and last process resident size (mach `resident_size`) |
| Slope | least-squares fit of resident bytes against time over the last two thirds of the run, so the warm-up is left out; bytes per minute and MB per hour |
| Peak open flows, Gaps | most flows open at once; gap count and longest gap (the locked phone shows as a gap) |
| Verdict | "memory flat" when the slope is under 1 MB per 10 minutes (100,000 bytes per minute). That threshold is ours; the plan gives none. Information, not a test |

- Resident size includes freed pages the allocator keeps, so a small upward drift early on is normal; judge the slope, not the max
- Also check the cap columns: all zero means no cap was hit. A non-zero one explains why memory stopped growing
- Record the slope, peak open flows and caps reached here, and in the README results. Until then the result is "not measured"
- Tests: `MetricsLogTests` (csv format and cadence with a fake clock, resident size is positive, file safety, slope on synthetic flat and growing runs)


### Result (2026-11-18, 30 minutes on the phone)

| Measure | Value |
|---|---|
| Duration | 1,800 s, ended by `--duration` (session end reason `captureStopped`) |
| Packets / connections | 551,475 / 1,286, all saved, 0 save failures |
| Kernel drops | 0 |
| Resident memory | min 8.5 MB, max 13.3 MB; slope over the last two thirds 602 bytes/min (0.03 MB/hour): flat |
| Peak open flows | 241 (cap 20,000) |
| Gaps | 1, longest 5.6 s (phone locked) |
| Metrics rows | 873 of an expected 900. Cause: timer drift, not lost samples. The old writer waited 2 s after each actual write, and the wake-up was about 1.03 s late each tick, so the period was 2.06 s (1,800 / 873). Fixed with fixed time slots (see [CAPTURE.md](CAPTURE.md)); tests `writerKeepsItsSlotsWhenWakeUpsAreLate` and `writerCountsASlotMissedCompletely`. The memory result is unaffected |

Use: browsing, social apps, about 10 minutes of video, then the phone locked; the phone was used again near the end

## Synthetic corpus

`SyntheticCorpus.mixed()` (Tests/TestSupport) returns PCAPNG bytes built from hand-made frames plus an `Expected` value with every answer worked out by hand. `GoldenReportTests` runs the bytes through `CapturePipeline` and `ReportBuilder` and checks exact equality. Nothing is read from disk, so the tests need no `TATTLE_FIXTURES` and no golden file is committed (so nothing under `Tests/Expected/` to guard). Output is deterministic: fixed timestamps, ports and addresses, and the report JSON has sorted keys.

- Names are fictional (`.test`, `.example`); addresses come from 192.0.2.0/24 and 2001:db8::/32, plus the phone's private 10.0.0.2, the mDNS group and a private `fd5d::` address
- `SyntheticCorpus.withTrailer()` is the same capture followed by the 24-byte pcap trailer (a VPN corpus is deferred)
- Builders: `PacketBuilder` (Ethernet, IPv4/IPv6, TCP/UDP, IPv4 fragments, ARP, utun frames) and `ProtocolBuilders.swift` (DNS, TLS ClientHello, QUIC Initial)

| Flow | Process (eproc) | Interface | Content | IP bytes | Packets |
|---|---|---|---|---|---|
| D1 | mDNSResponder (TikTok) | en2 | DNS answer `video.tiktok.test` to 192.0.2.10 | 79 | 1 |
| F1 | TikTok | en2 | TCP 443, SYN, ClientHello SNI `video.tiktok.test`, 4 data | 3,559 | 6 |
| F2 | Instagram | en2 | TCP 443, first packet ACK (midstream), no name | 1,420 | 3 |
| F3 | TikTok | en2 | UDP 443, QUIC Initial SNI `cdn.tiktok.test`, 2 data | 2,684 | 3 |
| F4 | heartbeatd | en0 | IPv6 TCP to `fd5d::1` port 62078 | 180 | 3 |
| F5 | none | en0 | mDNS to 224.0.0.251:5353, no process | 156 | 2 |
| F6 | Safari | en0 | IPv6 TCP 443 to 2001:db8::5, no hello | 1,240 | 4 |
| D6 | mDNSResponder (Safari) | en0 | AAAA answer `site.example` to 2001:db8::5, 30 s before F6, TTL 300 | 106 | 1 |
| F7 | Safari | en0 | TCP 443, ClientHello SNI `outer.example` plus ECH extension | 842 | 3 |
| F8 | Safari | en0 | UDP datagram split in two IPv4 fragments | 124 | 1 |
| F9 | appstorecomponen | pdp_ip0 | TCP 443, SYN, SYN-ACK, 200 bytes, no SNI | 320 | 3 |

- Totals: 11 flows, 30 packets in flows, 10,710 IP bytes. Pipeline counters: 32 read, 31 decoded, 1 skipped (an ARP frame), 0 malformed, 1 dropped for no port (the second fragment of F8)
- Fragments: the decoder parses the transport header of a first fragment (offset 0), so it is counted in a flow like any packet; a later fragment has no ports and is dropped (`droppedNoPort`). Nothing is reassembled
- Out of scope for now: categories (problem 4.2) and hostname metrics (5.1) add their numbers to the same corpus and test

### Adding a flow

- Add its frames to `mixed()` with a time offset; times must be distinct so the order is fixed
- Add a comment with the byte arithmetic next to the frames, and an `ExpectedFlow` plus the new totals in `expected()`, each with the sum in a comment
- Use the existing formulas: TCP packet = 20 + 20 + payload, UDP = 20 + 8 + payload, ClientHello record = 102 + name length (109 + with ECH)
- A new process or interface goes at the end of the block lists so existing indexes stay valid
- Run `scripts/test.sh 300`; if a total changes, recompute it by hand rather than copying the actual value

## Checks per stage

| Stage | Check |
|---|---|
| Reader | Packet and per-process counts equal tcpdump's (done) |
| Decoder | Packets decoded + skipped = packets read |
| Flows | Packets and bytes summed over flows = summed over packets |
| Domains | DNS names include the ones seen in tcpdump output (TikTok, Instagram chains) |
| Storage | Reloaded session gives the same totals as in memory |

## Regression ratchet

- Band files in `Tests/Expected/<scenario>.json` hold a floor and a ceiling per metric, measured on a real capture (format and tolerance rule: `md/REPORT.md`). They hold numbers only; `RepoGuardTests` fails the suite if a hostname, address or device id appears in that folder
- `FixtureBandsTests` runs the pipeline and report on `TATTLE_FIXTURES/captures/<scenario>.pcapng` for each band file and asserts no regression. It skips when the variable is unset or the capture is missing
- Band files are written from a real capture: `tattle report <capture> --write-bands Tests/Expected/<id>.json --label <label>`. Scenario files stay in `~/dev/tattle-fixtures/scenarios`
- Who updates a band: the author of the change that moves a metric. Re-run `--write-bands` on the fixtures and add an entry to `notes` with the metric and the reason (for example a narrowed denominator). A band is never loosened without a note
- A metric whose denominator is under 10,000 bytes is informational and never fails
- Company coverage has its own bands: `Tests/Expected/companies-synthetic.json` (checked by `CoverageTests`, hand-built `CompanyCorpus`, no fixtures needed) and `Tests/Expected/companies/<scenario>.json` (checked by `curatedOnlyCoverageBaselinesHold` against `TATTLE_FIXTURES`, curated list only). The floor is the baseline rounded down, with no tolerance, and a later source must not lower it (`md/COMPANIES.md`). The folder is scanned by the repo guard like the rest of `Tests/Expected/`

- `quietShare` (deviceLink + localNetwork + system) is only meaningful for the idle scenario. `--write-bands` writes it into every band file: after regenerating, remove it from all band files except `s0-idle.json`

## Benchmarks

| What | Target | Result |
|---|---|---|
| Reader, multi-app (50,766 packets) | — | 0.11 s release, Mac |
| Full pipeline (`bench`, multi-app, release) | ≥1,500 packets/s (N1) | ~620,000 packets/s (best of 3, 2026-11-16) |
| Throughput baseline (`bench`, s3-youtube-quic, 83,047 packets, release) | No more than 10% below this after M2 changes | 662,830 packets/s (best of 3, 2026-11-18) |
| After 5.4 + 6.1 (back to back with the baseline tool, same machine) | Within 10% of the baseline tool | ~598k vs ~655k packets/s: about 9% slower (2026-11-18). After 5.3 the two were level, so 5.4 and 6.1 cost about 9%. Less than 1% budget left: later problems must bench back to back |
| After 1.3 (company labels at read time; `bench`, s3-youtube-quic, release, 3 back-to-back pairs, 2026-11-22) | Within 1 percentage point of the M2 build | new 648k, 645k, 650k vs pre-M2 baseline tool 654k, 670k, 668k packets/s; new 660k, 624k, 653k vs M2 build 641k, 632k, 613k packets/s. Labels are built at view time, off the packet path |
| Synthetic pipeline throughput (`syntheticThroughput`, 200,000 hand-built UDP packets, `store: nil`) | ≥50,000 packets/s (sanity floor) | ~200,000 packets/s (debug test build, 2026-11-17) |
| Capture summary (`weekOf100kFlowsUnderOneSecond`, 100,000 synthetic flows, 50 apps and the system, 2026-11-24) | under 1 s release (3.1) | 289 ms release, about 2.6 s debug, with curated and AdGuard-only names in the week so every path is timed. The SQL rollup in Deferred is not needed |
| Memory, open flows | — | Not measured |
| Live capture (phone, YouTube), 2026-11-16 | Streams, stops on Ctrl-C | 26,916 packets / 177 s, 0 malformed, 91 flows, 25 SNI, 30 DNS, exit 0 |

- Rust only comes up if the full pipeline misses N1 by a clear margin

## Fixture tests

- Run long test runs under `caffeinate -i` (`TATTLE_FIXTURES=~/dev/tattle-fixtures caffeinate -i scripts/test.sh 600`): a Mac that sleeps during a run makes the wall-clock tests fail with impossible times
- Tests that need a capture read the directory from `TATTLE_FIXTURES` and skip when it's unset, so `swift test` is green on any machine
- Shared helper in `Tests/TestSupport` (a plain target, not a test target): `fixtureURL("watch-clean-test.pcap") -> URL?`, plus the byte builders (PCAPNG blocks, `PacketBuilder` frames, DNS, TLS and QUIC messages, the synthetic corpus) so every test target can build captures by hand
- Fixture tests print their counts, so a run doubles as a report
- `CaptureTests` run as one `@Suite(.serialized)`: they spawn processes, send signals and install process-wide handlers, so parallel runs raced (pid files written before stream data, EOF before exit). Fakes write their pid after the data. If a run ever hangs, `pkill -9 -f swiftpm-testing-helper` clears stale runners; swift-testing buffers output when not on a tty, so a killed run shows nothing
- `Tests/TestSupport` is an ordinary target, so it is built by `swift build -c release` too: it must never use `@testable import`. Anything a builder needs from a module has to be public (2026-11-17: QUIC `deriveKeys`/`headerMask` made public for this)


## Commands

```
swift test
scripts/fixtures.sh check
TATTLE_FIXTURES=~/dev/tattle-fixtures swift test
swift build -c release && .build/release/tattle read ~/dev/tattle-fixtures/captures/watch-clean-test.pcap
```

## Open questions

- A VPN capture and a long (30+ min) capture to add to the set

## See also

[PCAPNG.md](PCAPNG.md) · [DECODER.md](DECODER.md) · [FLOWS.md](FLOWS.md)
