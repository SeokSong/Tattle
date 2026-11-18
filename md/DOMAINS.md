# Domains

**Status:** Done (2026-11-16). `Sources/Domains`, 27 tests. QUIC SNI works: key derivation and header-protection mask match RFC 9001 A.1/A.2 values; the full A.2 packet was not reproduced, so the remaining QUIC tests are round-trips. The fixtures are the real check:

| Capture | DNS answers | Distinct hostnames | SNI found | Buffers that gave up |
|---|---|---|---|---|
| watch-clean-test | 20 | 16 | 17 | 0 |
| watch-safari-test | 24 | 14 | 6 | 0 |
| watch-test | 164 | 99 | 109 | 1 |
| watch-youtube-test | 128 | 58 | 170 | 0 |
| multi-app-test | 99 | 71 | 75 | 0 |

- Implementation notes: DNS responses without an A/AAAA answer are dropped; ECH without plain SNI is reported as `.noSNI` and the ECH flag is lost (that flow lands in `noHandshakeUDP` / `noDNSMatch`); `DomainExtractor` is the convenience the pipeline uses (`observe(packet)`, `flowClosed(key)`)
- The RFC 9001 A.2 ClientHello's SNI is `example.com` (an earlier draft of this doc said otherwise)

## Purpose

- Find out which hostnames traffic went to, without decrypting anything
- Two sources, kept apart because they prove different things

| Source | Where | Proves |
|---|---|---|
| DNS answer | UDP 53 responses | An app looked up a name and got these IPs. Not that it connected (I3) |
| SNI | TLS ClientHello, QUIC Initial | This connection asked for this hostname |

## DNS (F9)

- Parse responses: question name, CNAME chain, A and AAAA answers, TTL
- Lookups are made by `mDNSResponder`; the app is in `eproc` (e.g. `proc mDNSResponder:212, eproc TikTok:18954`)
- Example chain seen in the clean capture: `frontier-ttp2.tiktokv.us` → `...edgesuite.net` → `shared-usttp-api-spread.bytewlb.akadns.net` → Akamai IPs

## SNI (F5a)

- TLS: server name extension in the ClientHello, sent unencrypted
- QUIC: the same ClientHello inside the Initial packet. Encrypted with keys anyone can derive from the connection id, so readable
- Stored on the flow as its server name

## Handshake buffer

- ClientHellos now often span 2–3 packets (post-quantum key shares make them larger)
- Hold the first packets of each new connection until the server name is read, then drop them
- Cap: 16 KB or 5 packets per connection, whichever comes first
- The only raw bytes kept beyond decoding, and only in memory

## Linking DNS to flows

- Proposed rule: a DNS answer supports a flow when
    - the flow's remote IP is in the answer, and
    - the lookup was for the same app (`eproc`) as the flow's process, and
    - the flow started after the answer, within its TTL
- Always labelled as "from DNS", never as observed
- Implemented as `HostnameIndex` in `Sources/Attribution/Hostnames.swift`; sources are `sni` and `dns`, TTL default 300 s, inclusive. Details in [ATTRIBUTION.md](ATTRIBUTION.md)
- SNI wins over DNS when both exist

## What we never do

- Store or show content (F12). Plain HTTP (port 80) is rare but fully readable: we read only its IP and TCP headers
- Treat a CDN address as the company's location

## Implementation spec

Target `Domains`, depends on `PacketDecoder` and `Flows` (for `FlowKey`). Three parsers, each a pure function over bytes, plus the per-connection buffer. Built in this order: DNS, TLS, buffer, QUIC. QUIC is the hard one and may land in a second pass.

### Types

```swift
public struct DomainObservation: Sendable {
    public enum Source: String, Sendable { case dns, sni }
    public let time: Date
    public let source: Source
    public let hostname: String                 // lowercased, no trailing dot
    public let cnameChain: [String]             // dns only, in order
    public let addresses: [IPAddress]           // dns only
    public let ttl: UInt32?                     // dns only, smallest in the chain
    public let flowKey: FlowKey?                // sni only
    public let process: PCAPNGProcess?
    public let effectiveProcess: PCAPNGProcess?
}
```

### DNS (`DNSParser`)

- Input: UDP payload where remote port is 53 and the packet is inbound (a response). Skip queries, skip TCP 53 in V1
- Parse header (12 bytes), QR bit must be 1, RCODE 0 only. Questions: skip names. Answers: `A` (1), `AAAA` (28), `CNAME` (5); other types skipped by their RDLENGTH
- Name decoding: labels, compression pointers (`0xC0`), at most 128 pointer jumps, total name ≤ 253 chars, else give up on the message
- Output: one `DomainObservation` per message: hostname = question name; chain = CNAMEs in answer order; addresses = all A/AAAA
- mDNS (port 5353) is ignored

### TLS ClientHello (`TLSClientHello`)

```swift
public struct ServerNameResult: Sendable, Equatable { public var name: String; public var echPresent: Bool }
public enum SNIResult: Sendable, Equatable { case found(ServerNameResult), needMore, notHandshake, noSNI }
public static func serverName(inRecords bytes: ArraySlice<UInt8>) -> SNIResult   // tls record layer in front
public static func serverName(inHandshake bytes: ArraySlice<UInt8>) -> SNIResult // bare handshake message (quic)
```

- Record: type 22, version `0x03xx`, length. Concatenate the fragments of consecutive handshake records before parsing (a ClientHello can span records)
- Handshake type 1, length. If the bytes present are fewer than the length → `.needMore`
- Skip: version 2, random 32, session id (1-byte length), cipher suites (2-byte length), compression (1-byte length). Extensions: 2-byte length, then type/length pairs. Type 0 = server_name: list length, name type 0, name length, name
- Validate the name: ASCII, no control characters, ≤ 253 chars; else `.noSNI`
- Extension type `0xFE0D` (ECH) is detected by presence only, wherever it sits in the extension list. A GREASE ECH looks the same, so the flag means "extension sent", not "ECH used"
- ECH with a plain SNI → `.found` with `echPresent == true`. The name is the public outer name, not the real host; do not use it as the hostname
- ECH without a plain SNI → `.noSNI`, and the ECH state is lost (accepted limit)
- The flag flows `TLSClientHello` / `QUICInitial` → `HandshakeBuffer.add` (returns `ServerNameResult?`) → `DomainExtractor` → `DomainObservation.echPresent` (sni only) → pipeline: `FlowTable.markECH(for:)` and `stats.echSeen += 1`

### Handshake buffer (`HandshakeBuffer`)

```swift
public struct HandshakeBuffer {
    public init(maxPackets: Int = 5, maxBytes: Int = 16_384)
    /// feeds the payload of an outbound packet. returns a server name once, then nothing more for that key
    public mutating func add(key: FlowKey, payload: ArraySlice<UInt8>, isQUIC: Bool) -> String?
    public mutating func forget(_ key: FlowKey)        // called when the flow closes
    public var pendingCount: Int
}
```

- First outbound payload decides: TCP and byte 0 == `0x16` → TLS pending; UDP remote port 443 and `byte0 & 0xC0 == 0xC0` → QUIC pending; anything else → done (never buffered)
- Append payloads in arrival order (V1 assumes in-order; out-of-order just fails to parse and hits the cap)
- After each append run the parser; `.found` → done, return it; `.needMore` → keep; `.notHandshake`/`.noSNI` → done
- Over `maxPackets` or `maxBytes` → done, drop. A `done` key holds no bytes
- Memory bound: at most `pendingCount × 16 KB`; entries forgotten on flow close

### QUIC Initial (`QUICInitial`)

- Recognise: long header, version `0x00000001` (type bits `0b00` = Initial) or `0x6b3343cf` (v2, type `0b01`)
- Initial secret: HKDF-SHA256 with the version's salt (v1 `38762cf7f55934b34d179ae6a4c80cadccbb7f0a`, v2 `0dede3def700a6db819381be6e269dcbf9bd2ed9`) over the Destination Connection ID; `client in` label → key, iv, hp (RFC 9001 §5)
- Header protection: AES-128-ECB over the sample via CommonCrypto (`CCCrypt`, `kCCAlgorithmAES`, `kCCOptionECBMode`); CryptoKit has no ECB. Payload: AES-128-GCM via CryptoKit
- Decrypt, walk frames: PADDING (0), PING (1), ACK (2–3, skip), CRYPTO (6: offset, length, data). Reassemble CRYPTO data by offset; when contiguous from 0 and the handshake length is satisfied → `TLSClientHello.serverName(inHandshake:)`
- Coalesced packets: an Initial datagram may carry more than one QUIC packet; after the Initial, stop (later ones are Handshake/1-RTT)
- Test vector: RFC 9001 Appendix A.2 (client Initial, SNI `example.com`)

### Linking DNS to flows

- Not done in this target. Storage keeps both; the rule in "Linking DNS to flows" above runs at read time ([ATTRIBUTION.md](ATTRIBUTION.md) owns it)

### Privacy

- Parsers never return anything but hostnames and addresses. No HTTP parsing exists in this target
- The buffer holds handshake bytes only; `done` entries hold nothing

### Tests

- DNS: single A; A + AAAA; CNAME chain of 3 then A (built with compression pointers); pointer loop → nil; truncated → nil; a query (QR = 0) → nil
- TLS: one-record ClientHello with SNI; split across two records; split across two TCP payloads (needMore then found); no SNI extension → `.noSNI`; not a handshake → `.notHandshake`
- Buffer: found on the second packet; cap by packets; cap by bytes; non-TLS first byte never buffers; `forget` frees
- QUIC: the RFC 9001 vector decrypts and yields the name; wrong DCID fails cleanly (bad GCM tag → nil, no crash)
- Fixture (`WATCH_FIXTURES`, through decoder + flows): watch-clean-test yields DNS names containing `tiktokv.us`; count SNI names found; print how many flows on 443 ended with no name

### Acceptance

- `swift test` green; the fixture test prints DNS and SNI counts for all five files

## Found in live captures (2026-11-16)

- With iCloud Private Relay on, DNS answers dropped to 0: the phone resolves through encrypted DNS over HTTPS (`mDNSResponder` talking to an Apple address on 443). SNI still gave 21 hostnames. DNS evidence is optional; SNI is the dependable source
- Two new Google QUIC flows had no hostname and never engaged the handshake buffer: their first outbound packet was not a recognised QUIC long header. Needs a diagnostic capture of the first packets to explain (older Google QUIC variant or a migrated connection are the candidates)

## Open questions

- Encrypted Client Hello (ECH) hides SNI. How often does it show up in fixtures?
- DNS over HTTPS or over TLS bypasses port 53. Do iOS apps use it?

## See also

[DECODER.md](DECODER.md) · [FLOWS.md](FLOWS.md) · [ATTRIBUTION.md](ATTRIBUTION.md)
