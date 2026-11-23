# Pipeline

**Status:** Done (2026-11-16). `Sources/Pipeline` (actor `CapturePipeline`), 6 tests; CLI has `read`, `flows <file> [--db path]`, `bench <file>`. Bench on multi-app: ~620,000 packets/s release (N1 target was 1,500). Notes: `run` does not close flows, callers call `stop`; the session begins on the first flush; `retainFlows: true` keeps final flows in memory for the CLI; `echSeen` counts flows whose ClientHello carried the ECH extension (presence only, set with the SNI observation; ECH without an outer SNI is not counted).

## Purpose

- One place that turns `PCAPNGEvent`s into stored flows and domains, for both live capture and file replay (F4, I7)
- Owns the only copy of each raw packet and drops it after decoding (N2)

## Implementation spec

Target `Pipeline`, depends on `PCAPNG`, `PacketDecoder`, `Flows`, `Domains`, `Storage`, `Attribution`.

### Actor

```swift
public actor CapturePipeline {
    public init(store: sending (any FlowStore)?, session: CaptureSession, flushInterval: TimeInterval = 2)
    public func run(_ source: some PacketSource) async throws -> PipelineStats
    public func stop(reason: FlowEndReason) async            // closes every flow, final flush, ends the session
    public var stats: PipelineStats { get }
}

public struct PipelineStats: Sendable {
    public var packets, decoded, skipped, malformed, droppedNoPort: Int
    public var flowsOpened, flowsClosed, dnsObservations, sniFound: Int
    public var echSeen: Int                     // flows whose ClientHello had the ECH extension (needs an outer SNI)
    public var interfaces: [String: Int]
    public var elapsed: TimeInterval            // wall time of run()
    public var saveFailures: Int                // saves (and endSession calls) that threw
    public var unsavedFlows: Int                // flows still unsaved after the final flush of stop
}
```

### Per event

1. `.interface` / `.process` / `.sectionStarted`: nothing (the parser tracks them)
2. `.packet`: `PacketDecoder.decode` → on `.decoded`:
    - `transport == .other` or a nil port → `droppedNoPort`, done
    - `FlowTable.add` → on `.opened`, nothing else
    - Outbound with payload: `HandshakeBuffer.add(key, payload, isQUIC: udp && remotePort == 443)` → name → `flowTable.setServerName` and a `DomainObservation(.sni)`
    - Inbound UDP from remote port 53 with payload: `DNSParser.parse` → `DomainObservation(.dns)`
    - Packet time ≥ `lastExpire + 1 s` → `flowTable.expire(at: packetTime)`, closed flows get `handshakeBuffer.forget`
3. The `DecodedPacket.bytes` array goes out of scope here. Nothing retains it except the handshake buffer's copy of a handshake payload

### Flushing

- Live: a timer task every `flushInterval` calls `flush()`: `store.save(flowTable.drainDirty(), pendingDomains, session)`
- File replay: flush every 5,000 packets and at the end (avoids timer nondeterminism in tests)
- `stop`: `flowTable.closeAll(reason)`, final flush (retried once), `store.endSession`
- Save first, clear on success: `flush()` drains the table, calls `store.save`, and on a throw calls `flowTable.requeue(flows)` and counts `saveFailures`. The drained flows come back in the next drain, once
- If the final flush still fails after the retry, `unsavedFlows` holds the number of flows left; `stop` carries on and always tries `endSession` (a failure there also counts in `saveFailures`)
- After `stop`, `process` returns at once and the public flush paths (`run`, timer) do nothing: no packet is counted or saved after the session ends
- The pipeline takes any `FlowStore` (protocol in `Sources/Storage/FlowStore.swift`), so tests can inject a store that fails
- `store == nil` → run without saving (used by the CLI for a quick summary and by tests)
- `retainDomains: true` keeps every flushed `DomainObservation` for `domainsSnapshot()`, as `retainFlows` does for flows. CLI and tests only: unbounded, never set in the app
- `dnsSnapshot() -> [DomainObservation]` returns the recent DNS ring: the last `CapturePipeline.recentDNSCapacity` (5,000) DNS answers, oldest first. Always on, DNS only, fixed size (the oldest is overwritten), so it is safe in the app. The live screen builds its `HostnameIndex` from it; SNI names come from each flow's `serverName`. `PipelineStats.recentDNSCount` is its current size
- Caps (6.1): see [Caps and counters](#caps-and-counters). `retainFlows` is used by the app (live list) and the CLI, so it is capped; `retainDomains` is CLI and tests only and is capped too
- `PipelineStats.handshakeGaveUp: [String: Int]` counts handshake buffers that ended without a name, by `GaveUpReason` raw value (see [DOMAINS.md](DOMAINS.md)). Numbers only. `tattle report` prints it as `Handshake gave up: ...`; a QUIC flow's Initial is decrypted at most 3 times

### Gaps (6.2)

- Every packet read counts for gap time, decoded or not (an ARP frame or an unknown packet closes a silence)
- A gap is a silence strictly greater than 5 s between a packet and the latest earlier packet, in packet time. Exactly 5.000 s is not a gap
- A backwards timestamp is ignored: it is not a gap and does not become the previous time
- The check is one integer compare in interface ticks per packet (no division, no allocation); the length in seconds is only computed when a gap is found
- `PipelineStats.gapCount` and `PipelineStats.maxGap` (seconds). A locked phone is a gap, not an interruption: the session keeps running until `stop`
- `stop` writes `SessionStats(gapCount, maxGapMs, saveFailures, unsavedFlows)` once with `store.recordSessionStats`, after the final flush and `endSession` so their failures are counted. `kernelDropped` is set with `setKernelDropped` after tcpdump has ended (6.4); it stays nil when unknown. A session that never began (nothing was ever saved) has no row to update
- Not covered: wall-clock stalls where the capture stops delivering packets (6.3)

### Caps and counters

Every structure that grows with traffic has a cap, an eviction rule and a counter. Numbers come from the owner's own sessions (a few thousand flows an hour), so the caps sit far above normal use. On the five real captures every drop and eviction counter is 0 (largest peaks: 210 open flows, 135 pending domains, 198 handshake entries).

| Structure | Where | Cap | Eviction rule | Counter | Reported in |
|---|---|---|---|---|---|
| Open flows (`FlowTable.entries`) | Flows | 20,000 | New key at the cap: close the 1,000 least recently seen flows with end reason `evicted`; saved, never dropped | `evictedFlows`, `peakOpenFlows`, `openFlows` | `PipelineStats`, `Caps:` line |
| Closed flows waiting for a drain (`closedPending`) | Flows | 100,000 | Only when saves keep failing: drop the oldest 10,000 | `droppedClosedFlows` | `PipelineStats`, `Caps:` line |
| Process rows per flow (`Flow.tally`) | Flows | 64 rows (+ the no-process row) | New pair on a full tally counts under no-process | `tallyRowsFolded` | `PipelineStats`, `Caps:` line |
| Pending domains (`pendingDomains`) | Pipeline | 20,000 flush early; 40,000 hard | At 20,000 flush now; a failed flush retries every 5,000 more; at 40,000 drop the oldest 20,000 | `peakPendingDomains`, `droppedDomains` | `PipelineStats`, `Caps:` line |
| Handshake states (`HandshakeBuffer.states`) | Domains | 4,096 | Drop all done entries; if still full finish the oldest quarter of pending as `capReached` | `handshakeStatesDropped`, `peakHandshakeStates` | `PipelineStats`, `Caps:` line, `Handshake gave up` |
| Short-header keys (`shortHeaderKeys`) | Domains | 1 per packet | Drained after every packet | none | n/a |
| Retained flows (`retained`, for `flowsSnapshot()`) | Pipeline | 50,000 | Drop the oldest closed flows (by last packet) at each flush; they stay in the database | `retainedDropped` | `PipelineStats`, `Caps:` line, live screen note |
| Retained domains (`retainedDomains`, CLI and tests) | Pipeline | 200,000 | Drop the oldest | `retainedDomainsDropped` | `PipelineStats`, `Caps:` line |
| Recent DNS ring (`recentDNS`) | Pipeline | 5,000 | Overwrite the oldest | `recentDNSCount` | `PipelineStats` |
| Interface counts (`interfaces`) | Pipeline | 64 names | Later names count as `(other)` | `interfacesFolded` | `PipelineStats`, `Caps:` line |
| Local addresses (`PacketDecoder.localAddresses`) | PacketDecoder | 64 (existing) | New addresses are not learned | none | n/a |
| Process table and skipped types (`PCAPNGStreamParser`) | PCAPNG | 100,000 processes; 64 skipped types; 16 MB per block | See [PCAPNG.md](PCAPNG.md) | `processBlocksDropped`, `unresolvedProcessReferences` | Parser properties |
| Tcpdump stderr tail (`StderrTail`) | Capture | 20 lines (existing) | Drop the oldest | none | n/a |
| Live flow table rows | App | 10 shown (500 by default in `flowRows`) | Fold the rest into "N more flows" | `moreFlows` | Live screen |
| Live flows and DNS (`liveFlows`, `liveDNS`) | App | copies of the retained list (50,000) and the DNS ring (5,000) | Replaced every 2 s | `retainedDropped` | Live screen note |
| Session count cache (`countCache`) | App | 1,000 sessions | Cleared when full | none | n/a |

- Evictions never lose saved data: an evicted open flow is closed with end reason `evicted` and goes to the store like any closed flow
- `retainedDropped > 0` means in-memory totals are lower than the saved session. The CLI `report` and `flows` print a warning after the `Caps:` line; the reconciliation check `decodedAccounted` also fails in that case
- Not capped on purpose, because they are batch inputs: `PCAPNGReader.parse` (the whole file, CLI `read` only) and the report and session screens, which read one stored session
- `PipelineStats.anyCapHit` is true when any drop, eviction or fold counter is above 0
- `tattle report` and `flows` print one `Caps:` line with every counter and peak, after `Handshake gave up`
- Early flush runs inside `process`, so a slow store slows packet handling; the live timer flush still runs every 2 s and normally keeps the queue far below 20,000

### Errors

- Parser error → stop with reason `.interrupted`, rethrow with the byte offset. Never skip bad data (F11)
- Store error → stop the capture, rethrow. Losing a batch is worse than stopping

### Speed

- Everything runs on the actor, single-threaded by design: 1,500 packets/s needs ~0.7 ms per packet, and the reader alone does 50k in 0.1 s. Measure before adding threads
- No `Date()` calls per packet; packet timestamps drive expiry

### CLI (`tattle`)

| Command | Does |
|---|---|
| `read <file>` | Existing summary (packets, interfaces, by process) |
| `flows <file> [--db path]` | Runs the pipeline on a file; prints stats, top flows by bytes (each line starts with the category code name, e.g. `app`, `deviceLink`; names are display names), bytes and flows per category with the phone traffic total, DNS and SNI counts; each line ends the name with its source (`name [sni]`, `name [dns, may be another service]`) or the reason it has none (`(Connection started before capture)`); saves when `--db` is given |
| `report <file> [--detail] [--json]`, `report --db <path> --session <id\|latest> [...]` | Quality report (see [REPORT.md](REPORT.md)). Exit 0 all checks pass, 2 a check failed, 1 other error |
| `bench <file>` | Runs the pipeline with no store 3 times; prints packets/s. Target ≥ 1,500 (N1); expected far higher |

- `flows` output sample:
    - flow line: `  app           12:00:01  rvi0  tcp  93.184.34.34:443  in 900 out 100  example.com  -> TikTok (1 pid)`
    - summary block: `Bytes by category (IP bytes, whole flows):` then one line per category, `  deviceLink    700 bytes  1 flows  (USB link to this Mac, not phone traffic)`, then `  Phone traffic total: N bytes`
- Output never prints the device id. Addresses and hostnames print only in `flows` output, which is a local developer command

### Tests

- Replaying a hand-built event list (one DNS answer, one TLS flow with a split ClientHello, one UDP flow) yields the expected flows, server name and domain observation
- Stats add up: `packets == decoded + skipped + malformed`
- Flush on replay writes the same flows a `store.flows(session:)` reads back
- Fixture (`TATTLE_FIXTURES`): all five files run to the trailer; `bench` on multi-app prints its rate

### Acceptance

- `swift test` green; `bench` multi-app ≥ 1,500 packets/s release (record the number in [TESTING.md](TESTING.md))

## Report import

`ReportImporter.run(file:store:)` (in `Sources/Pipeline/ReportImporter.swift`, the only Pipeline file that imports `PrivacyReport`) imports an App Privacy Report export. It opens the file read-only where the user chose it, parses it in a stream, combines records into one row per app and domain, maps them to storage rows and calls `saveImport` once, so a refused import stores nothing. It makes no copy of the file and keeps no path. The result (`ReportImportSummary`) carries the parser counts, the store outcome (stored, duplicate, empty, older than a stored import) and the newer-format warning, and its `lines` are plain-language counts and dates only. The command is `tattle import-report <file> [--db <path>]`. This path is separate from the packet path and `bench` does not touch it.

## See also

[DESIGN.md](DESIGN.md) · [FLOWS.md](FLOWS.md) · [DOMAINS.md](DOMAINS.md) · [STORAGE.md](STORAGE.md)
