# Packet decoder

**Status:** Done (2026-11-16). `Sources/PacketDecoder`, 21 tests. Fixtures: watch-clean-test 1,285 decoded + 7 skipped (ARP and other non-IP), multi-app 50,762 + 4, 0 malformed. Multi-app decodes in 0.067 s release.

## Purpose

- Read the link, IP and TCP/UDP headers of each packet (F5)
- Produce the fields flows are built from, and the byte counts
- After this step the raw packet is dropped (N2)

## Link types

| Link type | Interfaces seen | Header to skip | IP version from |
|---|---|---|---|
| 1 (Ethernet) | en0, en2 | 14 bytes (more with a VLAN tag) | EtherType: `0x0800` IPv4, `0x86DD` IPv6 |
| 0 (DLT_NULL) | utun4, pdp_ip0 | 4 bytes | Address family in those 4 bytes (host byte order) |

- Other EtherTypes (ARP, etc.) are counted and skipped

## IP

- IPv4: header length from IHL, total length field, protocol, addresses
- IPv6: fixed 40-byte header, next header, addresses. Walk extension headers to reach TCP/UDP
- Fragments: count them, don't reassemble in V1

## Transport

- TCP: ports, flags (SYN, FIN, RST), data offset → payload start
- UDP: ports, length → payload start
- Port 443 UDP is treated as QUIC by the domains step; the decoder doesn't decide that

## Bytes

| Measure | Covers | Stored |
|---|---|---|
| On-wire (`originalLength`) | Link header + IP + transport + data | No |
| IP bytes | IP header + transport header + data | Yes, main number |
| Payload bytes | Data after the TCP/UDP header | Yes |

- No link-layer headers: the same traffic counts the same on Wi-Fi (14-byte header) and cellular (4-byte header)
- IPv6: IP bytes = 40 + payload length field
- Use the length fields, not the captured length. Small Ethernet frames are padded to 60 bytes
- Both include encryption overhead and retransmissions. They measure what crossed the interface

## Direction

- From the packet's flags option (F7), not from addresses
- Fallback when missing: match against the phone's own addresses seen in inbound packets. Mark it as inferred

## Implementation spec

Target `PacketDecoder`, depends on `PCAPNG` (for `PCAPNGPacket`, `PCAPNGProcess`, `Direction`). Two layers: a pure header parser over bytes, and a step that orients it as local/remote.

### Types

```swift
public enum IPAddress: Hashable, Sendable {
    case v4(UInt32)                 // network byte order packed big-endian into the UInt32
    case v6(hi: UInt64, lo: UInt64)
    public var description: String  // "93.184.216.34", "2606:2800::1"
}

public enum Transport: Hashable, Sendable { case tcp, udp, other(UInt8) }

public struct TCPFlags: OptionSet, Sendable { fin = 1, syn = 2, rst = 4, psh = 8, ack = 16 }

public struct IPHeaders: Sendable {
    public let ipVersion: UInt8
    public let source: IPAddress
    public let destination: IPAddress
    public let transport: Transport
    public let sourcePort: UInt16?        // nil for .other or a non-first fragment
    public let destinationPort: UInt16?
    public let tcpFlags: TCPFlags?
    public let ipBytes: Int               // from the length fields, see Bytes above
    public let payload: Range<Int>        // into the packet bytes; empty when no transport header
    public let fragmented: Bool
}

public enum DecodeOutcome: Sendable {
    case decoded(IPHeaders)
    case skipped(SkipReason)              // arp, ipx, unknownLinkType, nonIPFamily, ...
    case malformed(String)                // short header, bad IHL, length field beyond the bytes
}

public enum HeaderParser {
    public static func parse(linkType: UInt16, bytes: ArraySlice<UInt8>) -> DecodeOutcome
}
```

```swift
public struct DecodedPacket: Sendable {
    public let timestamp: Date
    public let interface: String
    public let direction: Direction           // inbound | outbound | inferred(...) | unknown
    public let headers: IPHeaders
    public let localAddress: IPAddress
    public let localPort: UInt16?
    public let remoteAddress: IPAddress
    public let remotePort: UInt16?
    public let process: PCAPNGProcess?
    public let effectiveProcess: PCAPNGProcess?
    public let bytes: [UInt8]                 // the raw packet, dropped once flows and domains have seen it
}

public struct PacketDecoder {
    public init()
    /// decodes and orients. keeps a set of addresses seen as "local" to infer direction when flags are missing
    public mutating func decode(_ packet: PCAPNGPacket) -> Result<DecodedPacket, DecodeOutcome>
}
```

### Link layer

| Link type | Steps |
|---|---|
| 1 Ethernet | bytes 12–13 = EtherType. `0x8100` → skip 4, read again. `0x0800` → IPv4 at 14 (18). `0x86DD` → IPv6. Else `.skipped` |
| 0 DLT_NULL | first 4 bytes, host byte order (little endian on this Mac; accept both: 2 or `0x02000000` → IPv4, 30 or `0x1E000000` → IPv6). Else `.skipped(nonIPFamily)` |
| other | `.skipped(unknownLinkType)` |

### IPv4

- IHL × 4 ≥ 20, total length ≥ IHL×4 and ≤ bytes left else `.malformed`
- `fragmented` = MF bit or fragment offset ≠ 0. Transport header only parsed when offset == 0
- protocol 6 → TCP, 17 → UDP, else `.other(n)`
- `ipBytes` = total length

### IPv6

- Fixed 40 bytes. `ipBytes` = 40 + payload length field
- Walk next headers: 0 hop-by-hop, 43 routing, 60 destination options: length = (hdr[1] + 1) × 8. 51 AH: (hdr[1] + 2) × 4. 44 fragment: 8 bytes, set `fragmented`, parse transport only when the offset field is 0. 59 no next header → `.other(59)`. Anything else → `.other(n)`, stop
- Guard: at most 8 extension headers

### Transport

- TCP: data offset × 4 ≥ 20; flags from byte 13; payload starts at offset
- UDP: 8-byte header; payload = `min(udpLength, remaining) - 8`
- Payload range is clamped to the bytes present (snaplen can cut it)

### Direction and local/remote

- `inbound` → local = destination, remote = source. `outbound` → the reverse
- Flags missing: if source ∈ localAddresses → outbound(inferred); if destination ∈ localAddresses → inbound(inferred); else `unknown`, local = source (so flows still form), and the pipeline counts it
- `localAddresses`: every destination of an `inbound` packet and every source of an `outbound` packet, learned as they go. Bounded set (cap 64, phones have few addresses)

### Privacy and speed

- No logging of addresses anywhere in this target
- No allocation on the hot path except the `DecodedPacket` itself; parse with index arithmetic over `ArraySlice<UInt8>`, no `Data`

### Tests

- Hand-built packets: IPv4/TCP and UDP on Ethernet; IPv6/TCP on DLT_NULL; IPv6 with hop-by-hop then UDP; VLAN-tagged IPv4
- Ethernet padding (60-byte frame carrying a 28-byte IPv4 datagram) → `ipBytes == 28`
- IPv4 first fragment and non-first fragment
- Truncated TCP header → `.malformed`; ARP → `.skipped`
- Direction: flags inbound/outbound, missing with learned local address, missing and unknown
- Fixture (`WATCH_FIXTURES`): every packet of watch-clean-test is decoded, skipped or malformed; decoded + skipped + malformed == 1,292; malformed == 0; print the counts per outcome

### Acceptance

- `swift test` green
- Fixture run on multi-app: 50,766 packets through parse + orient in ≤ 0.3 s release (part of N1)

## Open questions

- VPN / utun: the same traffic may show inside utun and again, encrypted, on en0 or pdp_ip0. Needs a capture with a real VPN on. iCloud Private Relay was tested (2026-11-16) and is not a tunnel (utun4 carried 8 packets of 10,962), so it does not answer this. Until then, totals don't add utun and physical interfaces together
- Do outbound packets ever show up larger than the MTU (segmentation offload)? Check on fixtures

## See also

[PCAPNG.md](PCAPNG.md) · [FLOWS.md](FLOWS.md) · [DOMAINS.md](DOMAINS.md)
