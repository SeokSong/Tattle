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

### Errors

- Parser error → stop with reason `.interrupted`, rethrow with the byte offset. Never skip bad data (F11)
- Store error → stop the capture, rethrow. Losing a batch is worse than stopping

### Speed

- Everything runs on the actor, single-threaded by design: 1,500 packets/s needs ~0.7 ms per packet, and the reader alone does 50k in 0.1 s. Measure before adding threads
- No `Date()` calls per packet; packet timestamps drive expiry

### CLI (`WatchCapture`)

| Command | Does |
|---|---|
| `read <file>` | Existing summary (packets, interfaces, by process) |
| `flows <file> [--db path]` | Runs the pipeline on a file; prints stats, top flows by bytes (each line starts with the category code name, e.g. `app`, `deviceLink`; names are display names), bytes and flows per category with the phone traffic total, DNS and SNI counts; saves when `--db` is given |
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
- Fixture (`WATCH_FIXTURES`): all five files run to the trailer; `bench` on multi-app prints its rate

### Acceptance

- `swift test` green; `bench` multi-app ≥ 1,500 packets/s release (record the number in [TESTING.md](TESTING.md))

## See also

[DESIGN.md](DESIGN.md) · [FLOWS.md](FLOWS.md) · [DOMAINS.md](DOMAINS.md) · [STORAGE.md](STORAGE.md)
