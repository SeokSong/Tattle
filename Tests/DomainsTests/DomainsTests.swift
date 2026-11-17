import Flows
import Foundation
import PCAPNG
import PacketDecoder
import Testing
@testable import Domains

private func parseDNS(_ m: [UInt8]) -> DomainObservation? {
    DNSParser.parse(m[...], time: Date(timeIntervalSince1970: 0))
}

// MARK: dns

@Test func dnsSingleA() throws {
    let m = dnsResponse(question: "Example.COM", records: [DNSRecord(type: 1, ttl: 60, rdata: [1, 2, 3, 4])])
    let o = try #require(parseDNS(m))
    #expect(o.hostname == "example.com")
    #expect(o.source == .dns)
    #expect(o.addresses == [.v4(0x0102_0304)])
    #expect(o.ttl == 60)
    #expect(o.cnameChain.isEmpty)
    #expect(o.flowKey == nil)
}

@Test func dnsAAndAAAA() throws {
    let v6: [UInt8] = [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]
    let m = dnsResponse(question: "a.test", records: [
        DNSRecord(type: 1, ttl: 300, rdata: [10, 0, 0, 1]),
        DNSRecord(type: 28, ttl: 120, rdata: v6),
    ])
    let o = try #require(parseDNS(m))
    #expect(o.addresses == [.v4(0x0A00_0001), .v6(hi: 0x2001_0db8_0000_0000, lo: 1)])
    #expect(o.ttl == 120)
}

@Test func dnsCnameChainWithCompression() throws {
    // chain of 3 cnames then an A. rdata names use pointers into the question and earlier names
    var m: [UInt8] = be16(1) + be16(0x8180) + be16(1) + be16(4) + be16(0) + be16(0)
    m += dnsName("www.example.com") + be16(1) + be16(1)
    func record(owner: [UInt8], type: Int, ttl: UInt32, rdata: [UInt8]) -> [UInt8] {
        owner + be16(type) + be16(1) + be32(ttl) + be16(rdata.count) + rdata
    }
    // cname 1: www.example.com -> edge.cdn.net (label "edge" then pointer to "cdn.net" defined below)
    let cdnOffset = m.count + 2 + 10 + 1 + 4  // owner(2) + fixed(10) + len byte + "edge" -> start of "cdn.net"
    let r1rdata: [UInt8] = [4] + Array("edge".utf8) + [3] + Array("cdn".utf8) + [3] + Array("net".utf8) + [0]
    m += record(owner: [0xC0, 12], type: 5, ttl: 500, rdata: r1rdata)
    _ = cdnOffset
    // cname 2: edge.cdn.net -> shared.cdn.net. owner is a pointer to the rdata of record 1
    let edgeOffset = 12 + dnsName("www.example.com").count + 4 + 2 + 10
    let cdnNetOffset = edgeOffset + 5
    m += record(
        owner: be16(0xC000 | edgeOffset), type: 5, ttl: 400,
        rdata: [6] + Array("shared".utf8) + [0xC0, UInt8(cdnNetOffset)])
    // cname 3: shared.cdn.net -> origin.cdn.net
    let sharedOffset = m.count - ([6] + Array("shared".utf8) + [0xC0, UInt8(cdnNetOffset)]).count
    m += record(
        owner: be16(0xC000 | sharedOffset), type: 5, ttl: 450,
        rdata: [6] + Array("origin".utf8) + [0xC0, UInt8(cdnNetOffset)])
    let originOffset = m.count - ([6] + Array("origin".utf8) + [0xC0, UInt8(cdnNetOffset)]).count
    m += record(owner: be16(0xC000 | originOffset), type: 1, ttl: 30, rdata: [9, 9, 9, 9])

    let o = try #require(parseDNS(m))
    #expect(o.hostname == "www.example.com")
    #expect(o.cnameChain == ["edge.cdn.net", "shared.cdn.net", "origin.cdn.net"])
    #expect(o.addresses == [.v4(0x0909_0909)])
    #expect(o.ttl == 30)
}

@Test func dnsPointerLoopIsNil() {
    // question name is a pointer to itself
    var m: [UInt8] = be16(1) + be16(0x8180) + be16(1) + be16(0) + be16(0) + be16(0)
    m += [0xC0, 12] + be16(1) + be16(1)
    #expect(parseDNS(m) == nil)
}

@Test func dnsTruncatedIsNil() {
    let m = dnsResponse(question: "example.com", records: [DNSRecord(type: 1, ttl: 60, rdata: [1, 2, 3, 4])])
    for cut in [0, 5, 11, 20, m.count - 1, m.count - 5] {
        #expect(parseDNS(Array(m[0..<cut])) == nil)
    }
}

@Test func dnsQueryIsNil() {
    let m = dnsResponse(question: "example.com", records: [DNSRecord(type: 1, ttl: 60, rdata: [1, 2, 3, 4])], flags: 0x0100)
    #expect(parseDNS(m) == nil)
}

@Test func dnsErrorRcodeIsNil() {
    let m = dnsResponse(question: "example.com", records: [DNSRecord(type: 1, ttl: 60, rdata: [1, 2, 3, 4])], flags: 0x8183)
    #expect(parseDNS(m) == nil)
}

@Test func dnsOverlongNameIsNil() {
    let label = String(repeating: "a", count: 60)
    let name = Array(repeating: label, count: 5).joined(separator: ".")
    let m = dnsResponse(question: name, records: [DNSRecord(type: 1, ttl: 60, rdata: [1, 2, 3, 4])])
    #expect(parseDNS(m) == nil)
}

// MARK: tls

@Test func tlsOneRecord() {
    let hello = clientHello(sni: "Example.org")
    #expect(TLSClientHello.serverName(inRecords: tlsRecord(hello)[...]) == .found("example.org"))
    #expect(TLSClientHello.serverName(inHandshake: hello[...]) == .found("example.org"))
}

@Test func tlsSplitAcrossRecords() {
    let hello = clientHello(sni: "split.example.org")
    let cut = 50
    let bytes = tlsRecord(Array(hello[..<cut])) + tlsRecord(Array(hello[cut...]))
    #expect(TLSClientHello.serverName(inRecords: bytes[...]) == .found("split.example.org"))
}

@Test func tlsSplitAcrossPayloads() {
    let bytes = tlsRecord(clientHello(sni: "late.example.org"))
    let cut = 40
    #expect(TLSClientHello.serverName(inRecords: bytes[..<cut]) == .needMore)
    #expect(TLSClientHello.serverName(inRecords: bytes[..<3]) == .needMore)
    #expect(TLSClientHello.serverName(inRecords: bytes[...]) == .found("late.example.org"))
}

@Test func tlsNoSNI() {
    #expect(TLSClientHello.serverName(inRecords: tlsRecord(clientHello(sni: nil))[...]) == .noSNI)
    let ech = clientHello(sni: nil, extraExtensions: [(0xFE0D, [1, 2, 3])])
    #expect(TLSClientHello.serverName(inRecords: tlsRecord(ech)[...]) == .noSNI)
}

@Test func tlsNotHandshake() {
    #expect(TLSClientHello.serverName(inRecords: tlsRecord([1, 2, 3], type: 23)[...]) == .notHandshake)
    #expect(TLSClientHello.serverName(inRecords: Array("GET / HTTP/1.1\r\n".utf8)[...]) == .notHandshake)
    // a handshake record carrying something other than a ClientHello
    #expect(TLSClientHello.serverName(inRecords: tlsRecord([2, 0, 0, 0])[...]) == .notHandshake)
}

@Test func tlsRejectsBadNames() {
    #expect(TLSClientHello.serverName(inHandshake: clientHello(sni: "bad\u{1}name.org")[...]) == .noSNI)
    #expect(TLSClientHello.serverName(inHandshake: clientHello(sni: String(repeating: "a", count: 254))[...]) == .noSNI)
}

// MARK: buffer

private func tcpKey(_ port: UInt16 = 50000) -> FlowKey {
    FlowKey(transport: .tcp, localAddress: .v4(1), localPort: port, remoteAddress: .v4(2), remotePort: 443)
}

@Test func bufferFoundOnSecondPacket() {
    var b = HandshakeBuffer()
    let bytes = tlsRecord(clientHello(sni: "two.example.org"))
    #expect(b.add(key: tcpKey(), payload: bytes[..<30], isQUIC: false) == nil)
    #expect(b.pendingCount == 1)
    #expect(b.add(key: tcpKey(), payload: bytes[30...], isQUIC: false) == "two.example.org")
    #expect(b.pendingCount == 0)
    #expect(b.add(key: tcpKey(), payload: bytes[...], isQUIC: false) == nil)
}

@Test func bufferCapsByPackets() {
    var b = HandshakeBuffer(maxPackets: 3)
    let bytes = tlsRecord(clientHello(sni: "cap.example.org"))
    for i in 0..<3 { #expect(b.add(key: tcpKey(), payload: bytes[i..<(i + 1)], isQUIC: false) == nil) }
    #expect(b.pendingCount == 1)
    #expect(b.add(key: tcpKey(), payload: bytes[3..<4], isQUIC: false) == nil)
    #expect(b.pendingCount == 0)
    #expect(b.tlsGaveUp == 1)
    // done: even the full hello is ignored now
    #expect(b.add(key: tcpKey(), payload: bytes[...], isQUIC: false) == nil)
}

@Test func bufferCapsByBytes() {
    var b = HandshakeBuffer(maxPackets: 100, maxBytes: 50)
    let bytes = tlsRecord(clientHello(sni: "big.example.org"))
    #expect(b.add(key: tcpKey(), payload: bytes[..<30], isQUIC: false) == nil)
    #expect(b.pendingCount == 1)
    #expect(b.add(key: tcpKey(), payload: bytes[30..<60], isQUIC: false) == nil)
    #expect(b.pendingCount == 0)
}

@Test func bufferNeverBuffersNonTLS() {
    var b = HandshakeBuffer()
    #expect(b.add(key: tcpKey(), payload: Array("GET /".utf8)[...], isQUIC: false) == nil)
    #expect(b.pendingCount == 0)
    // udp that is not quic
    let udp = FlowKey(transport: .udp, localAddress: .v4(1), localPort: 5000, remoteAddress: .v4(2), remotePort: 8888)
    #expect(b.add(key: udp, payload: [0xC0, 1, 2][...], isQUIC: false) == nil)
    #expect(b.pendingCount == 0)
    #expect(b.tlsGaveUp == 0)
}

@Test func bufferForgetFrees() {
    var b = HandshakeBuffer()
    let bytes = tlsRecord(clientHello(sni: "forget.example.org"))
    #expect(b.add(key: tcpKey(), payload: bytes[..<30], isQUIC: false) == nil)
    #expect(b.pendingCount == 1)
    b.forget(tcpKey())
    #expect(b.pendingCount == 0)
    // a reused key starts fresh
    #expect(b.add(key: tcpKey(), payload: bytes[...], isQUIC: false) == "forget.example.org")
}

// MARK: quic

private let rfcDCID = hex("8394c8f03e515708")

@Test func quicInitialKeysMatchRFC9001() {
    // RFC 9001 appendix A.1 and A.2 values for dcid 8394c8f03e515708
    let k = QUICInitial.deriveKeys(dcid: rfcDCID, version: 1)
    #expect(k.key.withUnsafeBytes { Array($0) } == hex("1f369613dd76d5467730efcbe3b1a22d"))
    #expect(k.iv == hex("fa044b2f42a3fd3b46fb255c"))
    #expect(k.hp == hex("9f50449e04a0e810283a1e9933adedd2"))
    let mask = QUICInitial.headerMask(hp: k.hp, sample: hex("d1b1c98dd7689fb8ec11d242b123dc9b"))
    #expect(Array(mask!.prefix(5)) == hex("437b9aec36"))
}

@Test func quicRoundTripV1() {
    let hello = clientHello(sni: "quic.example.org")
    let packet = quicInitial(dcid: rfcDCID, frames: cryptoFrame(offset: 0, hello))
    #expect(packet.count == 1200)
    #expect(QUICInitial.serverName(inDatagram: packet[...]) == .found("quic.example.org"))
}

@Test func quicRoundTripV2() {
    let hello = clientHello(sni: "v2.example.org")
    let packet = quicInitial(dcid: rfcDCID, version: 0x6b33_43cf, frames: cryptoFrame(offset: 0, hello))
    #expect(QUICInitial.serverName(inDatagram: packet[...]) == .found("v2.example.org"))
}

@Test func quicSkipsAckAndPingAndReordersCrypto() {
    let hello = clientHello(sni: "frames.example.org")
    let cut = 60
    let ack: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00]
    // later half first, in a second frame of the same packet, behind ping, padding and ack
    let frames = [0x01, 0x00] + ack + cryptoFrame(offset: cut, Array(hello[cut...])) + cryptoFrame(offset: 0, Array(hello[..<cut]))
    let packet = quicInitial(dcid: rfcDCID, frames: frames)
    #expect(QUICInitial.serverName(inDatagram: packet[...]) == .found("frames.example.org"))
}

@Test func quicSplitAcrossDatagrams() {
    let hello = clientHello(sni: "multi.example.org")
    let cut = 70
    let first = quicInitial(dcid: rfcDCID, pn: 0, frames: cryptoFrame(offset: 0, Array(hello[..<cut])))
    let second = quicInitial(dcid: rfcDCID, pn: 1, frames: cryptoFrame(offset: cut, Array(hello[cut...])))
    #expect(QUICInitial.serverName(inDatagrams: [first[...]]) == .needMore)
    #expect(QUICInitial.serverName(inDatagrams: [first[...], second[...]]) == .found("multi.example.org"))

    var b = HandshakeBuffer()
    let key = FlowKey(transport: .udp, localAddress: .v4(1), localPort: 5000, remoteAddress: .v4(2), remotePort: 443)
    #expect(b.add(key: key, payload: first[...], isQUIC: true) == nil)
    #expect(b.pendingCount == 1)
    #expect(b.add(key: key, payload: second[...], isQUIC: true) == "multi.example.org")
}

@Test func quicWrongDCIDFailsCleanly() {
    var packet = quicInitial(dcid: rfcDCID, frames: cryptoFrame(offset: 0, clientHello(sni: "x.example.org")))
    packet[7] ^= 0xFF  // dcid byte: keys no longer match, gcm tag fails
    #expect(QUICInitial.serverName(inDatagram: packet[...]) == .notHandshake)
    // garbage and short inputs never crash
    #expect(QUICInitial.serverName(inDatagram: [0xC0, 0, 0, 0, 1][...]) == .notHandshake)
    #expect(QUICInitial.serverName(inDatagram: [UInt8](repeating: 0xC3, count: 1200)[...]) == .notHandshake)
    #expect(QUICInitial.serverName(inDatagram: [][...]) == .notHandshake)
}

@Test func quicIgnoresNonInitial() {
    var packet = quicInitial(dcid: rfcDCID, frames: cryptoFrame(offset: 0, clientHello(sni: "x.example.org")))
    packet[0] |= 0x20  // handshake type bits
    #expect(QUICInitial.serverName(inDatagram: packet[...]) == .notHandshake)
}
