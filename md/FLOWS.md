# Flows

**Status:** Done (2026-11-16). `Sources/Flows`, 14 unit tests + a fixture test per capture. Invariants hold on all five files. Decode + flows on multi-app: 0.78 s release (~65,000 packets/s).

| Capture | Flows | Flows with >1 process | Flows with >1 app | End reasons |
|---|---|---|---|---|
| watch-clean-test | 70 | 0 | 0 | stopped 67, fin 3 |
| watch-safari-test | 47 | 0 | 0 | stopped 47 |
| watch-test | 471 | 1 | 1 | stopped 400, fin 3, rst 68 |
| watch-youtube-test | 504 | 10 | 0 | stopped 346, fin 85, rst 73 |
| multi-app-test | 249 | 15 | 2 | stopped 221, fin 13, rst 15 |

- Answer to the open question: the only flows with two app names are UDP 53 flows from `mDNSResponder` to the resolver, carrying lookups for both Instagram and TikTok (`eproc`). Expected: one shared DNS socket. Attribution marks them `mixed`; DNS attribution comes from the per-observation `eproc`, not the flow
- Implementation notes: idle closes at exactly `lastSeen + 120 s` (`<=`); an RST on a new key returns `.opened` and the closed flow arrives through `drainDirty`; the table stores an `Entry` (flow + FIN state) per key

## Purpose

- Group packets into connections (F8). A flow, not a packet, is what users see
- Keep enough evidence on each flow to redo attribution later (I4)

## Flow key

- Protocol + local IP:port + remote IP:port
- Written as local/remote, not source/destination, so a request and its reply land in the same flow
- Process is **not** in the key
    - ~1% of packets have no process info. With process in the key, one connection would split into several flows
    - Instead each flow keeps a process tally

## Process tally

- Per flow: `(proc name, proc PID, eproc name, eproc PID) → packets`, including a "none" row
- Example: `TikTok[18963]: 412, none: 3`
- Attribution reads this later (see [ATTRIBUTION.md](ATTRIBUTION.md))

## When a flow ends

| Protocol | Ends when | Fallback |
|---|---|---|
| TCP | FIN from both sides, or RST | 2 min idle |
| UDP / QUIC | — | 2 min idle |
| Any | Capture stops | Closed with end reason `captureStopped` |

- A packet for a closed key starts a new flow
- 2 min is a starting value. Test it against the fixtures once flows exist
- Long history is a retention question ([STORAGE.md](STORAGE.md)), not a timeout question

## Fields (proposed)

| Field | Notes |
|---|---|
| id | |
| session | CaptureSession id |
| protocol | tcp / udp |
| local IP, local port | The phone's side |
| remote IP, remote port | |
| interface | en0, pdp_ip0, utun4, ... |
| first seen, last seen | Packet timestamps |
| packets in, packets out | |
| IP bytes in, IP bytes out | See [DECODER.md](DECODER.md) |
| payload bytes in, out | |
| end reason | fin / rst / idle / captureStopped / interrupted |
| process tally | See above |
| server name | From SNI, if seen ([DOMAINS.md](DOMAINS.md)) |

## Implementation spec

Target `Flows`, depends on `PacketDecoder`. Pure data structure, no I/O, no clock: time comes from packet timestamps so fixture replays are deterministic.

### Types

```swift
public struct FlowKey: Hashable, Sendable {
    public let transport: Transport
    public let localAddress: IPAddress
    public let localPort: UInt16
    public let remoteAddress: IPAddress
    public let remotePort: UInt16
}

public struct ProcessPair: Hashable, Sendable {      // one tally row
    public let processName: String?
    public let processID: UInt32?
    public let effectiveName: String?
    public let effectiveID: UInt32?
    public static let none = ProcessPair(nil, nil, nil, nil)
}

public enum FlowEndReason: String, Sendable { case fin, rst, idle, captureStopped, interrupted }

public struct Flow: Sendable, Identifiable {
    public let id: UUID
    public let key: FlowKey
    public let interface: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var packetsIn, packetsOut: Int
    public var ipBytesIn, ipBytesOut: Int
    public var payloadBytesIn, payloadBytesOut: Int
    public var unknownDirectionPackets: Int
    public var tally: [ProcessPair: Int]
    public var serverName: String?             // set by Domains (SNI)
    public var endReason: FlowEndReason?       // nil while open
}

public enum FlowEvent: Sendable { case opened(Flow), closed(Flow) }

public struct FlowTable {
    public init(idleTimeout: TimeInterval = 120, closingGrace: TimeInterval = 5)
    public mutating func add(_ packet: DecodedPacket) -> FlowEvent?   // .opened on a new key
    public mutating func expire(at now: Date) -> [Flow]                // closes idle and finished flows
    public mutating func closeAll(reason: FlowEndReason) -> [Flow]
    public mutating func setServerName(_ name: String, for key: FlowKey)
    public mutating func drainDirty() -> [Flow]                        // every flow changed since the last drain, open or closed
    public var openCount: Int
}
```

### Algorithm

- `add`: look up `key`. Missing → new flow, `firstSeen = lastSeen = timestamp`, return `.opened`. Packets with `transport == .other` or a nil port are dropped by the caller (counted in the pipeline, not here)
- Update counters by direction. `unknown` direction counts as out (local = source by construction) and increments `unknownDirectionPackets`
- Tally row = `ProcessPair` from the packet's `process` and `effectiveProcess`; increment
- TCP state: `finLocal`, `finRemote`, `rst`. A FIN from each side → state `closing`, `closingSince = timestamp`. RST → close now with `.rst`
- `expire(at:)`: a `closing` flow whose `closingSince + closingGrace < now` closes with `.fin`; any flow whose `lastSeen + idleTimeout < now` closes with `.idle`. Called by the pipeline once per second of packet time (and on every packet when replaying files). Closed flows are removed from the table and marked dirty
- A packet for a key that is `closing` still counts on that flow (the final ACKs). A packet for a key after it closed starts a new flow
- `drainDirty` returns copies and clears the dirty set. Closed flows appear in exactly one drain

### Speed

- `[FlowKey: Flow]` plus `Set<FlowKey>` for dirty. Idle scan walks all open flows: fine at hundreds; if it grows, keep a heap by `lastSeen` (not in V1)
- No allocation per packet beyond dictionary updates

### Tests

- Request and reply (swapped addresses, inbound vs outbound) land in one flow
- FIN both sides + grace → `.fin`; late ACK inside the grace counts on the same flow; packet after close → new flow
- RST → `.rst` immediately
- Idle → `.idle` at exactly `lastSeen + 120 s`
- Untagged packets stay in the same flow as a `.none` tally row
- Two PIDs produce two tally rows
- `drainDirty` returns each change once; a closed flow appears in one drain only
- Fixture (`WATCH_FIXTURES`, via the Decoder): sum of packets over flows + dropped (`other` transport) == decoded packets; sum of `ipBytes` matches the decoder's sum. Print flow count and how many had more than one non-none tally row (answers the open question)

### Acceptance

- `swift test` green; fixture invariants hold on all five files

## Open questions

- Do any connections carry more than one `proc`? Check on the fixtures once the decoder exists
- Is 2 min right for QUIC? Compare idle gaps in the fixtures
- Memory for open flows on a long capture: needs a measurement

## See also

[DECODER.md](DECODER.md) · [ATTRIBUTION.md](ATTRIBUTION.md) · [STORAGE.md](STORAGE.md)
