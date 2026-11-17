# PCAPNG reader

**Status:** Done, including streaming (2026-11-16). `Sources/PCAPNG`, 14 tests, matches tcpdump on all five captures. `PCAPNGEvent` also has a final `.end(PCAPNGEnd)` case so a stream can report the trailer. Multi-app (50,766 packets) streams in 0.05 s release.

## Purpose

- Turn tcpdump's output into packets with interface, timestamp and process info
- Our own reader, so Watch doesn't depend on tcpdump's text output (`-k`)

## Why PCAPNG

- tcpdump on `rvi0` writes PCAPNG, even when the file is named `.pcap` (`file` says `pcapng capture file - version 1.0`)
- Classic pcap has no room for per-packet process info. PCAPNG options do

## Blocks

| Type | Block | What we read |
|---|---|---|
| `0x0A0D0D0A` | Section header | Byte order. Resets interfaces and processes |
| `0x00000001` | Interface description | Link type, snap length, name (opt 2), timestamp resolution (opt 9) |
| `0x00000006` | Enhanced packet | Interface id, timestamp, lengths, data, options |
| `0x80000001` | Apple process info | PID (u32), then name (opt 2) |

- Every block: type (4) + length (4) + body + length again (4). Lengths must match and be a multiple of 4
- Interface and process blocks appear between packets, not only at the start. Interface order differs between captures
- Interfaces and processes are numbered in order of appearance within a section

## Packet options

| Code | Meaning | Used |
|---|---|---|
| `0x0002` | Flags. Bits 0–1: 01 inbound, 10 outbound (PCAPNG spec) | Planned, for direction (F7) |
| `0x8001` | Process index (`proc`) | Yes |
| `0x8002` | Service class | No |
| `0x8003` | Effective process index (`eproc`) | Yes |
| `0x8004` | Unknown Apple option | No |

- `proc` = the process that owns the socket (e.g. `mDNSResponder`)
- `eproc` = the process it acted for (e.g. `TikTok`). Only on some packets (43 of 1,292 in the clean capture)
- Exact meanings still to confirm against Apple's libpcap source

## The 24-byte trailer

- Every capture ends with a classic pcap file header after the PCAPNG data. Cause (confirmed 2026-11-16): Apple's tcpdump writes this header first, then PCAPNG; on stdout it appears at the front. `tcpdump -P` avoids it entirely; the reader keeps tolerating it for files captured without `-P`

| Bytes | Meaning |
|---|---|
| `d4 c3 b2 a1` | pcap magic (little endian, microseconds) |
| `02 00 04 00` | version 2.4 |
| 8 zero bytes | timezone, accuracy |
| `00 00 08 00` | snap length 524,288 |
| `95 00 00 00` | link type 149 (Apple PKTAP) |

- tcpdump reads `d4c3b2a1` as a block type and `02 00 04 00` as a length: 262,146, not a multiple of 4. That is the warning
- Rule (F11): exactly 24 bytes left **and** a pcap magic → stop, keep every packet, `endedWithPcapTrailer = true`
- Anything else that doesn't parse throws (`truncatedBlock`, `trailingLengthMismatch`, ...)

## Results

| Capture | Packets | Matches tcpdump | Time (release) |
|---|---|---|---|
| watch-clean-test | 1,292 | Yes | <0.01 s |
| watch-safari-test | 1,860 | Yes | 0.01 s |
| watch-test | 13,151 | Yes | 0.04 s |
| watch-youtube-test | 30,720 | Yes | 0.06 s |
| multi-app-test | 50,766 | Yes | 0.11 s |

- Per-process counts also match (YouTube 24,497, TikTok 8,909, Instagram 40,273 + 241)
- No process index ever pointed at a missing process block

## Implementation spec

Target `PCAPNG`, no dependencies. Build order: first, everything else reads its output.

### Changes to `PCAPNGPacket`

| Field | Type | Source |
|---|---|---|
| `data` | `[UInt8]` | The captured bytes (`capturedLength` of them). One copy per packet, ~1 KB, cheap |
| `flags` | `UInt32?` | Option `0x0002`, little/big endian per section |
| `direction` | `Direction` (`inbound`, `outbound`, `unknown`) | `flags & 0b11`: 1 inbound, 2 outbound, else unknown |
| `linkType` | via `interface.linkType` | Already there |

### `PCAPNGStreamParser`

One incremental parser; the whole-file reader becomes a wrapper around it so both paths run the same code.

```swift
public struct PCAPNGStreamParser {
    public init()
    /// feeds more bytes. returns every complete event found, in order
    public mutating func append(_ bytes: some Collection<UInt8>) throws -> [PCAPNGEvent]
    /// call at end of stream. checks the held-back tail
    public mutating func finish() throws -> PCAPNGEnd   // .cleanEnd | .pcapTrailer
    public var interfaces: [PCAPNGInterface]              // all sections
    public var skippedBlocks: [UInt32: Int]
    public var unresolvedProcessReferences: Int
}

public enum PCAPNGEvent: Sendable {
    case sectionStarted
    case interface(PCAPNGInterface)
    case process(PCAPNGProcess)
    case packet(PCAPNGPacket)
}
```

- Buffer: `[UInt8]` plus a read offset. After each `append`, parse complete blocks from the offset; when fewer than 12 bytes remain, or a block's length exceeds what's buffered, stop. Compact the buffer (drop consumed bytes) when the offset passes 1 MB, not on every call
- Trailer rule in a stream: if the unparsed tail starts with a pcap magic, don't parse it; wait. `finish()`: tail is exactly 24 bytes with a magic → `.pcapTrailer`; tail empty → `.cleanEnd`; anything else → `truncatedBlock`. If more than 24 bytes arrive after a magic, throw `badBlockLength` (it was never a trailer)
- Section header byte order is read before the block length, as now
- `PCAPNGReader.parse(_:)` = one `append` + `finish`, collecting events into `PCAPNGCapture` (keep this API; the CLI `read` command uses it)
- Everything stays `Sendable`; the parser is a value type owned by whoever feeds it

### `PacketSource`

```swift
public protocol PacketSource {
    /// yields events as they become available; ends on EOF
    func events() -> AsyncThrowingStream<PCAPNGEvent, Error>
}
public struct FilePacketSource: PacketSource   // reads the file in 256 KB chunks through the stream parser
public struct DataPacketSource: PacketSource   // for tests
```

- A `ProcessPacketSource` (tcpdump stdout) is added with [CAPTURE.md](CAPTURE.md), same protocol

### Tests (add to the 6 existing)

- Stream parser fed one byte at a time gives the same events as one shot
- Chunk boundary inside a block header, inside options, inside the trailer
- Trailer followed by more bytes throws
- `finish()` with a half block throws `truncatedBlock`
- `direction` from flags: 1 → inbound, 2 → outbound, missing → unknown
- `data.count == capturedLength`
- Fixture (skipped when `WATCH_FIXTURES` is unset): `FilePacketSource` on `watch-clean-test.pcap` yields 1,292 packets and `.pcapTrailer`

### Acceptance

- `swift test` green; `read` command output unchanged on all five fixtures
- Release build reads multi-app in ≤ 0.2 s through the stream path

## Tests

- Interfaces read in order; packet metadata; process and effective process resolved
- Stops at the trailer; also fine without one
- Truncated block throws; a classic pcap file throws `notPCAPNG`
- Unknown process index counted, not crashed on

## Open questions

- Does the streaming output end with the same trailer?
- Should packet data stay as a slice of the buffer to avoid copying, once streaming?

## See also

[CAPTURE.md](CAPTURE.md) · [DECODER.md](DECODER.md) · [TESTING.md](TESTING.md)
