import Foundation
import PCAPNG
import Testing
import TestSupport
@testable import PacketDecoder

// MARK: builders

private let mac: [UInt8] = Array(repeating: 0xAA, count: 6) + Array(repeating: 0xBB, count: 6)

private func ipv4(
    proto: UInt8, payload: [UInt8], src: [UInt8] = [10, 0, 0, 2], dst: [UInt8] = [93, 184, 216, 34],
    fragField: Int = 0, totalOverride: Int? = nil
) -> [UInt8] {
    [0x45, 0] + be16(totalOverride ?? 20 + payload.count) + [0, 1] + be16(fragField) + [64, proto, 0, 0] + src + dst + payload
}

private func tcp(src: Int, dst: Int, flags: UInt8, data: [UInt8] = []) -> [UInt8] {
    be16(src) + be16(dst) + [0, 0, 0, 1, 0, 0, 0, 0, 0x50, flags] + be16(1000) + [0, 0, 0, 0] + data
}

private func udp(src: Int, dst: Int, data: [UInt8]) -> [UInt8] {
    be16(src) + be16(dst) + be16(8 + data.count) + [0, 0] + data
}

private func ipv6(next: UInt8, payload: [UInt8]) -> [UInt8] {
    let src: [UInt8] = [0x26, 0x06, 0x28, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    let dst: [UInt8] = [0xFE, 0x80] + Array(repeating: 0, count: 13) + [2]
    return [0x60, 0, 0, 0] + be16(payload.count) + [next, 64] + src + dst + payload
}

private func ether(_ type: Int, _ body: [UInt8]) -> [UInt8] { mac + be16(type) + body }
private func nullFrame(family: UInt32, _ body: [UInt8]) -> [UInt8] { PCAPNGBuilder.le32(family) + body }

private func capture(_ frames: [(link: UInt16, flags: UInt32?, bytes: [UInt8])]) -> [UInt8] {
    var out = PCAPNGBuilder.sectionHeader()
    for link in Set(frames.map(\.link)).sorted() {
        out += PCAPNGBuilder.interface("if\(link)", linkType: link)
    }
    let order = Array(Set(frames.map(\.link)).sorted())
    for (i, f) in frames.enumerated() {
        out += PCAPNGBuilder.packet(
            interface: UInt32(order.firstIndex(of: f.link)!), microseconds: 1_763_000_000_000_000 + UInt64(i),
            process: nil, flags: f.flags, payload: f.bytes)
    }
    return out
}

private func packets(_ frames: [(link: UInt16, flags: UInt32?, bytes: [UInt8])]) async throws -> [PCAPNGPacket] {
    var out: [PCAPNGPacket] = []
    for try await event in DataPacketSource(capture(frames)).events() {
        if case .packet(let p) = event { out.append(p) }
    }
    return out
}

private func headers(_ outcome: DecodeOutcome) -> IPHeaders? {
    if case .decoded(let h) = outcome { return h }
    return nil
}

private func parseEther(_ bytes: [UInt8]) -> DecodeOutcome {
    HeaderParser.parse(linkType: 1, bytes: bytes[...])
}

// MARK: parser

@Test func ipv4TCPOnEthernet() throws {
    let data: [UInt8] = [1, 2, 3]
    let h = try #require(headers(parseEther(ether(0x0800, ipv4(proto: 6, payload: tcp(src: 50000, dst: 443, flags: 0x12, data: data))))))
    #expect(h.ipVersion == 4)
    #expect(h.source == .v4(0x0A00_0002))
    #expect(h.destination.description == "93.184.216.34")
    #expect(h.transport == .tcp)
    #expect(h.sourcePort == 50000 && h.destinationPort == 443)
    #expect(h.tcpFlags == [.syn, .ack])
    #expect(h.ipBytes == 43)
    #expect(h.payload == 54..<57)
    #expect(!h.fragmented)
}

@Test func ipv4UDPOnEthernet() throws {
    let h = try #require(headers(parseEther(ether(0x0800, ipv4(proto: 17, payload: udp(src: 5353, dst: 53, data: [9, 9, 9, 9]))))))
    #expect(h.transport == .udp)
    #expect(h.destinationPort == 53)
    #expect(h.tcpFlags == nil)
    #expect(h.ipBytes == 32)
    #expect(h.payload.count == 4)
}

@Test func ipv6TCPOnNull() throws {
    let frame = nullFrame(family: 30, ipv6(next: 6, payload: tcp(src: 1234, dst: 443, flags: 0x02)))
    let h = try #require(headers(HeaderParser.parse(linkType: 0, bytes: frame[...])))
    #expect(h.ipVersion == 6)
    #expect(h.transport == .tcp)
    #expect(h.ipBytes == 40 + 20)
    #expect(h.tcpFlags == .syn)
    #expect(h.source.description == "2606:2800::1")
    #expect(h.destination.description == "fe80::2")
    #expect(h.payload.isEmpty)
}

@Test func nullByteOrders() {
    let v4 = ipv4(proto: 17, payload: udp(src: 1, dst: 2, data: []))
    for family in [[2, 0, 0, 0], [0, 0, 0, 2]] as [[UInt8]] {
        let out = HeaderParser.parse(linkType: 0, bytes: (family + v4)[...])
        #expect(headers(out)?.ipVersion == 4)
    }
    let v6 = ipv6(next: 17, payload: udp(src: 1, dst: 2, data: []))
    for family in [[30, 0, 0, 0], [0, 0, 0, 30]] as [[UInt8]] {
        #expect(headers(HeaderParser.parse(linkType: 0, bytes: (family + v6)[...]))?.ipVersion == 6)
    }
    guard case .skipped(.nonIPFamily) = HeaderParser.parse(linkType: 0, bytes: ([18, 0, 0, 0] + v4)[...]) else {
        Issue.record("expected nonIPFamily"); return
    }
}

@Test func ipv6HopByHopThenUDP() throws {
    let hopByHop: [UInt8] = [17, 0, 1, 4, 0, 0, 0, 0]
    let h = try #require(headers(parseEther(ether(0x86DD, ipv6(next: 0, payload: hopByHop + udp(src: 1, dst: 2, data: [7, 7]))))))
    #expect(h.transport == .udp)
    #expect(h.sourcePort == 1 && h.destinationPort == 2)
    #expect(h.ipBytes == 40 + 8 + 10)
    #expect(h.payload.count == 2)
}

@Test func ipv6FragmentHeader() throws {
    let first: [UInt8] = [17, 0, 0, 1, 0, 0, 0, 1]
    let later: [UInt8] = [17, 0, 0, 8 + 1, 0, 0, 0, 1]
    let a = try #require(headers(parseEther(ether(0x86DD, ipv6(next: 44, payload: first + udp(src: 1, dst: 2, data: []))))))
    #expect(a.fragmented && a.sourcePort == 1)
    let b = try #require(headers(parseEther(ether(0x86DD, ipv6(next: 44, payload: later + [1, 2, 3, 4])))))
    #expect(b.fragmented && b.sourcePort == nil && b.payload.isEmpty)
}

@Test func ipv6NoNextHeaderAndTooManyExtensions() throws {
    let h = try #require(headers(parseEther(ether(0x86DD, ipv6(next: 59, payload: [])))))
    #expect(h.transport == .other(59))
    let chain = Array([UInt8]([60, 0, 0, 0, 0, 0, 0, 0]).repeated(9))
    guard case .malformed = parseEther(ether(0x86DD, ipv6(next: 60, payload: chain))) else {
        Issue.record("expected malformed"); return
    }
}

private extension Array {
    func repeated(_ n: Int) -> [Element] { Array((0..<n).map { _ in self }.joined()) }
}

@Test func vlanTaggedIPv4() throws {
    let inner = ipv4(proto: 17, payload: udp(src: 1, dst: 2, data: [1]))
    let frame = mac + be16(0x8100) + [0, 5] + be16(0x0800) + inner
    let h = try #require(headers(parseEther(frame)))
    #expect(h.transport == .udp && h.ipBytes == 29)
    #expect(h.payload == 18 + 28..<18 + 29)
}

@Test func ethernetPaddingIgnored() throws {
    let datagram = ipv4(proto: 17, payload: [1, 2, 3, 4, 5, 6, 7, 8])
    #expect(datagram.count == 28)
    let frame = ether(0x0800, datagram) + Array(repeating: 0, count: 60 - 14 - 28)
    #expect(frame.count == 60)
    let h = try #require(headers(parseEther(frame)))
    #expect(h.ipBytes == 28)
}

@Test func ipv4Fragments() throws {
    let first = try #require(headers(parseEther(ether(0x0800, ipv4(proto: 17, payload: udp(src: 1, dst: 2, data: [1]), fragField: 0x2000)))))
    #expect(first.fragmented && first.sourcePort == 1)
    let later = try #require(headers(parseEther(ether(0x0800, ipv4(proto: 17, payload: [1, 2, 3, 4, 5, 6, 7, 8, 9], fragField: 0x00B9)))))
    #expect(later.fragmented && later.sourcePort == nil && later.destinationPort == nil)
    #expect(later.payload.isEmpty)
    #expect(later.ipBytes == 29)
}

@Test func otherProtocol() throws {
    let h = try #require(headers(parseEther(ether(0x0800, ipv4(proto: 1, payload: [8, 0, 0, 0])))))
    #expect(h.transport == .other(1) && h.sourcePort == nil && h.payload.isEmpty)
}

@Test func malformedInputs() {
    func isMalformed(_ o: DecodeOutcome) -> Bool { if case .malformed = o { return true }; return false }
    // truncated tcp header (total length matches the cut bytes)
    #expect(isMalformed(parseEther(ether(0x0800, ipv4(proto: 6, payload: Array(tcp(src: 1, dst: 2, flags: 2).prefix(12)))))))
    // total length beyond the bytes
    #expect(isMalformed(parseEther(ether(0x0800, ipv4(proto: 17, payload: udp(src: 1, dst: 2, data: []), totalOverride: 200)))))
    // bad ihl
    var bad = ipv4(proto: 17, payload: udp(src: 1, dst: 2, data: []))
    bad[0] = 0x44
    #expect(isMalformed(parseEther(ether(0x0800, bad))))
    // short frames
    #expect(isMalformed(parseEther([1, 2, 3])))
    #expect(isMalformed(parseEther(ether(0x0800, [0x45, 0, 0]))))
    #expect(isMalformed(parseEther(ether(0x86DD, [0x60, 0, 0, 0]))))
}

@Test func skippedOutcomes() {
    guard case .skipped(.arp) = parseEther(ether(0x0806, Array(repeating: 0, count: 28))) else {
        Issue.record("expected arp"); return
    }
    guard case .skipped(.otherEtherType(0x88CC)) = parseEther(ether(0x88CC, [0, 0])) else {
        Issue.record("expected other ethertype"); return
    }
    guard case .skipped(.unknownLinkType) = HeaderParser.parse(linkType: 113, bytes: [0, 0, 0, 0][...]) else {
        Issue.record("expected unknownLinkType"); return
    }
}

@Test func ipv6Description() {
    #expect(IPAddress.v6(hi: 0, lo: 1).description == "::1")
    #expect(IPAddress.v6(hi: 0x2001_0DB8_0000_0000, lo: 0x0000_0000_0000_0001).description == "2001:db8::1")
    #expect(IPAddress.v6(hi: 0, lo: 0).description == "::")
    #expect(IPAddress.v6(hi: 0x0001_0002_0003_0004, lo: 0x0005_0006_0007_0008).description == "1:2:3:4:5:6:7:8")
}

// MARK: decoder

private let localv4: [UInt8] = [10, 0, 0, 2]
private let remotev4: [UInt8] = [93, 184, 216, 34]

private func outboundFrame() -> [UInt8] {
    ether(0x0800, ipv4(proto: 6, payload: tcp(src: 50000, dst: 443, flags: 0x10), src: localv4, dst: remotev4))
}

private func inboundFrame() -> [UInt8] {
    ether(0x0800, ipv4(proto: 6, payload: tcp(src: 443, dst: 50000, flags: 0x10), src: remotev4, dst: localv4))
}

@Test func directionFromFlags() async throws {
    let ps = try await packets([(1, 2, outboundFrame()), (1, 1, inboundFrame())])
    var decoder = PacketDecoder()
    let out = try decoder.decode(ps[0]).get()
    #expect(out.direction == .outbound)
    #expect(out.localAddress == .v4(0x0A00_0002) && out.localPort == 50000)
    #expect(out.remoteAddress.description == "93.184.216.34" && out.remotePort == 443)
    #expect(out.interface == "if1")
    #expect(out.bytes == ps[0].data)
    let inn = try decoder.decode(ps[1]).get()
    #expect(inn.direction == .inbound)
    #expect(inn.localAddress == .v4(0x0A00_0002) && inn.localPort == 50000)
    #expect(inn.remotePort == 443)
}

@Test func directionInferredFromLearnedAddresses() async throws {
    let ps = try await packets([(1, 1, inboundFrame()), (1, nil, outboundFrame()), (1, nil, inboundFrame())])
    var decoder = PacketDecoder()
    _ = decoder.decode(ps[0])
    let out = try decoder.decode(ps[1]).get()
    #expect(out.direction == .inferredOutbound)
    #expect(out.localAddress == .v4(0x0A00_0002))
    let inn = try decoder.decode(ps[2]).get()
    #expect(inn.direction == .inferredInbound)
    #expect(inn.localPort == 50000)
}

@Test func directionUnknownUsesSourceAsLocal() async throws {
    let ps = try await packets([(1, nil, outboundFrame())])
    var decoder = PacketDecoder()
    let out = try decoder.decode(ps[0]).get()
    #expect(out.direction == .unknown)
    #expect(out.localAddress == .v4(0x0A00_0002) && out.remoteAddress == .v4(0x5DB8_D822))
}

@Test func localAddressSetIsBounded() async throws {
    var frames: [(link: UInt16, flags: UInt32?, bytes: [UInt8])] = []
    for i in 0..<70 {
        frames.append((1, 1, ether(0x0800, ipv4(proto: 17, payload: udp(src: 1, dst: 2, data: []), src: remotev4, dst: [10, 1, 0, UInt8(i)]))))
    }
    frames.append((1, nil, ether(0x0800, ipv4(proto: 17, payload: udp(src: 1, dst: 2, data: []), src: [10, 1, 0, 69], dst: remotev4))))
    frames.append((1, nil, ether(0x0800, ipv4(proto: 17, payload: udp(src: 1, dst: 2, data: []), src: [10, 1, 0, 3], dst: remotev4))))
    let ps = try await packets(frames)
    var decoder = PacketDecoder()
    for p in ps.dropLast(2) { _ = decoder.decode(p) }
    #expect(try decoder.decode(ps[70]).get().direction == .unknown)
    #expect(try decoder.decode(ps[71]).get().direction == .inferredOutbound)
}

@Test func decoderReportsFailures() async throws {
    let ps = try await packets([(1, 1, ether(0x0806, Array(repeating: 0, count: 28))), (1, 1, ether(0x0800, [0x45]))])
    var decoder = PacketDecoder()
    guard case .failure(.skipped(.arp)) = decoder.decode(ps[0]) else { Issue.record("expected arp"); return }
    guard case .failure(.malformed) = decoder.decode(ps[1]) else { Issue.record("expected malformed"); return }
}

// MARK: fixtures

private struct Counts { var decoded = 0, skipped = 0, malformed = 0 }

private func run(_ url: URL) async throws -> (Counts, Double) {
    var decoder = PacketDecoder()
    var counts = Counts()
    let start = ContinuousClock.now
    for try await event in FilePacketSource(url: url).events() {
        guard case .packet(let packet) = event else { continue }
        switch decoder.decode(packet) {
        case .success: counts.decoded += 1
        case .failure(.skipped): counts.skipped += 1
        case .failure(.malformed): counts.malformed += 1
        }
    }
    let d = ContinuousClock.now - start
    return (counts, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
}

@Test func fixtureWatchClean() async throws {
    guard let url = Fixtures.url("watch-clean-test.pcap") else { return }
    let (c, _) = try await run(url)
    print("watch-clean-test: decoded \(c.decoded), skipped \(c.skipped), malformed \(c.malformed)")
    #expect(c.decoded + c.skipped + c.malformed == 1292)
    #expect(c.malformed == 0)
}

@Test func fixtureMultiAppTiming() async throws {
    guard let url = Fixtures.url("multi-app-test.pcap") else { return }
    let (c, seconds) = try await run(url)
    print("multi-app-test: decoded \(c.decoded), skipped \(c.skipped), malformed \(c.malformed) in \(seconds) s")
    #expect(c.decoded + c.skipped + c.malformed == 50766)
}
