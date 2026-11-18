import Foundation
import PCAPNG
import PacketDecoder
import Testing
import TestSupport

@testable import Flows

private let t0 = Date(timeIntervalSince1970: 1_763_000_000)
private let phone: [UInt8] = [10, 0, 0, 2]

private enum Dir: UInt32 { case unknown = 0, inbound = 1, outbound = 2 }

private struct Spec {
    var dir: Dir = .outbound
    var at: TimeInterval = 0
    var proto: UInt8 = 6
    var flags: UInt8 = 0
    var remote: UInt8 = 34
    var remotePort: Int = 443
    var process: UInt32?
    var effective: UInt32?
    var payload = 60
}

// builds a one-interface capture with two TikTok processes (index 0 pid 1, index 1 pid 2), decodes it for real
private func decode(_ specs: [Spec]) async throws -> [DecodedPacket] {
    var bytes = PCAPNGBuilder.sectionHeader() + PCAPNGBuilder.interface("en0")
    bytes += PCAPNGBuilder.process(pid: 1, name: "TikTok") + PCAPNGBuilder.process(pid: 2, name: "TikTok")
    for s in specs {
        let remote: [UInt8] = [93, 184, 216, s.remote]
        let out = s.dir != .inbound
        let (src, dst) = out ? (phone, remote) : (remote, phone)
        let (sp, dp) = out ? (50000, s.remotePort) : (s.remotePort, 50000)
        var l4: [UInt8]
        if s.proto == 6 {
            l4 = be16(sp) + be16(dp) + [0, 0, 0, 0, 0, 0, 0, 0, 0x50, s.flags, 0, 0, 0, 0, 0, 0]
        } else if s.proto == 17 {
            l4 = be16(sp) + be16(dp) + be16(8 + s.payload) + [0, 0]
        } else {
            l4 = [8, 0, 0, 0]
        }
        l4 += Array(repeating: 7, count: s.payload)
        let ip: [UInt8] = [0x45, 0] + be16(20 + l4.count) + [0, 0, 0, 0, 64, s.proto, 0, 0] + src + dst + l4
        let frame = [UInt8](repeating: 0, count: 12) + [8, 0] + ip
        bytes += PCAPNGBuilder.packet(
            interface: 0, microseconds: UInt64((1_763_000_000 + s.at) * 1_000_000),
            process: s.process, effective: s.effective, flags: s.dir.rawValue, payload: frame)
    }
    var decoder = PacketDecoder()
    var out: [DecodedPacket] = []
    for try await event in DataPacketSource(bytes).events() {
        guard case .packet(let raw) = event, case .success(let d) = decoder.decode(raw) else { continue }
        out.append(d)
    }
    return out
}

private func closeAll(_ table: inout FlowTable) -> [Flow] { table.closeAll(reason: .captureStopped) }

@Test func requestAndReplyShareOneFlow() async throws {
    let p = try await decode([Spec(), Spec(dir: .inbound, at: 1, payload: 150), Spec(dir: .inbound, at: 2)])
    var table = FlowTable()
    guard case .opened = table.add(p[0]) else { Issue.record("expected opened"); return }
    #expect(table.add(p[1]) == nil)
    #expect(table.add(p[2]) == nil)
    #expect(table.openCount == 1)
    let flow = closeAll(&table)[0]
    #expect(flow.packetsOut == 1 && flow.packetsIn == 2)
    #expect(flow.ipBytesOut == p[0].headers.ipBytes)
    #expect(flow.ipBytesIn == p[1].headers.ipBytes + p[2].headers.ipBytes)
    #expect(flow.payloadBytesOut == 60 && flow.payloadBytesIn == 210)
    #expect(flow.endReason == .captureStopped)
    #expect(flow.unknownDirectionPackets == 0)
    #expect(flow.interface == "en0")
}

@Test func unknownDirectionCountsAsOut() async throws {
    let p = try await decode([Spec(dir: .unknown)])
    #expect(p[0].direction == .unknown)
    var table = FlowTable()
    _ = table.add(p[0])
    let flow = closeAll(&table)[0]
    #expect(flow.packetsOut == 1 && flow.unknownDirectionPackets == 1)
}

@Test func inferredDirectionsCountLikePlainOnes() async throws {
    let p = try await decode([Spec(), Spec(dir: .unknown, at: 1), Spec(dir: .unknown, at: 2)])
    // second packet has the learned phone address as source, so it is inferred outbound
    #expect(p[1].direction == .inferredOutbound)
    var table = FlowTable()
    for x in p { _ = table.add(x) }
    let flow = closeAll(&table)[0]
    #expect(flow.packetsOut == 3 && flow.unknownDirectionPackets == 0)
}

@Test func unsupportedPacketsReturnNil() async throws {
    let p = try await decode([Spec(proto: 1)])
    var table = FlowTable()
    #expect(table.add(p[0]) == nil)
    #expect(table.openCount == 0)
}

@Test func finBothSidesThenGraceClosesAsFin() async throws {
    let p = try await decode([
        Spec(flags: 2), Spec(at: 1, flags: 0x11), Spec(dir: .inbound, at: 2, flags: 0x11),
        Spec(at: 3, flags: 0x10), Spec(at: 10, flags: 2),
    ])
    var table = FlowTable()
    _ = table.add(p[0])
    _ = table.add(p[1])
    #expect(table.expire(at: t0.addingTimeInterval(2)).isEmpty)
    _ = table.add(p[2])
    // inside the grace: the final ack counts on the same flow
    _ = table.add(p[3])
    #expect(table.expire(at: t0.addingTimeInterval(7)).isEmpty)
    let closed = table.expire(at: t0.addingTimeInterval(7.5))
    #expect(closed.count == 1)
    #expect(closed[0].endReason == .fin)
    #expect(closed[0].packetsOut == 3 && closed[0].packetsIn == 1)
    #expect(table.openCount == 0)
    // a packet after the close starts a new flow
    guard case .opened(let fresh) = table.add(p[4]) else { Issue.record("expected opened"); return }
    #expect(fresh.id != closed[0].id)
}

@Test func singleFinDoesNotClose() async throws {
    let p = try await decode([Spec(flags: 0x11)])
    var table = FlowTable()
    _ = table.add(p[0])
    #expect(table.expire(at: t0.addingTimeInterval(60)).isEmpty)
    #expect(table.openCount == 1)
}

@Test func rstClosesImmediately() async throws {
    let p = try await decode([Spec(), Spec(dir: .inbound, at: 1, flags: 4)])
    var table = FlowTable()
    _ = table.add(p[0])
    guard case .closed(let flow) = table.add(p[1]) else { Issue.record("expected closed"); return }
    #expect(flow.endReason == .rst)
    #expect(flow.packetsIn == 1)
    #expect(table.openCount == 0)
    let drained = table.drainDirty()
    #expect(drained.count == 1 && drained[0].endReason == .rst)
}

@Test func rstOnNewKeyIsOpenedThenDrained() async throws {
    let p = try await decode([Spec(dir: .inbound, flags: 4)])
    var table = FlowTable()
    guard case .opened = table.add(p[0]) else { Issue.record("expected opened"); return }
    #expect(table.openCount == 0)
    let drained = table.drainDirty()
    #expect(drained.count == 1 && drained[0].endReason == .rst)
}

@Test func idleClosesAtExactlyTimeout() async throws {
    let p = try await decode([Spec(proto: 17), Spec(dir: .inbound, at: 10, proto: 17)])
    var table = FlowTable()
    _ = table.add(p[0])
    _ = table.add(p[1])
    #expect(table.expire(at: t0.addingTimeInterval(129.9)).isEmpty)
    let closed = table.expire(at: t0.addingTimeInterval(130))
    #expect(closed.count == 1 && closed[0].endReason == .idle)
    #expect(closed[0].lastSeen == t0.addingTimeInterval(10))
}

@Test func untaggedPacketsStayInFlowAsNoneRow() async throws {
    let p = try await decode([
        Spec(process: 0, effective: 0), Spec(dir: .inbound, at: 1), Spec(dir: .inbound, at: 2, process: 0, effective: 0),
    ])
    var table = FlowTable()
    for x in p { _ = table.add(x) }
    #expect(table.openCount == 1)
    let flow = closeAll(&table)[0]
    #expect(flow.tally.count == 2)
    #expect(flow.tally[.none] == 1)
    #expect(flow.tally[ProcessPair("TikTok", 1, "TikTok", 1)] == 2)
}

@Test func twoPIDsMakeTwoTallyRows() async throws {
    let p = try await decode([Spec(process: 0), Spec(at: 1, process: 1), Spec(at: 2, process: 1)])
    var table = FlowTable()
    for x in p { _ = table.add(x) }
    #expect(table.openCount == 1)
    let flow = closeAll(&table)[0]
    #expect(flow.tally.count == 2)
    #expect(flow.tally[ProcessPair("TikTok", 2, nil, nil)] == 2)
}

@Test func differentKeysAreDifferentFlows() async throws {
    let p = try await decode([Spec(), Spec(remote: 35), Spec(proto: 17), Spec(remotePort: 80)])
    var table = FlowTable()
    for x in p { _ = table.add(x) }
    #expect(table.openCount == 4)
}

@Test func drainDirtyReturnsEachChangeOnce() async throws {
    let p = try await decode([Spec(), Spec(remote: 35), Spec(dir: .inbound, at: 1), Spec(at: 2)])
    var table = FlowTable()
    _ = table.add(p[0])
    _ = table.add(p[1])
    #expect(table.drainDirty().count == 2)
    #expect(table.drainDirty().isEmpty)
    _ = table.add(p[2])
    let one = table.drainDirty()
    #expect(one.count == 1 && one[0].packetsIn == 1)

    // closed flows appear in exactly one drain
    _ = table.add(p[3])
    let closed = table.expire(at: t0.addingTimeInterval(500))
    #expect(closed.count == 2)
    let drained = table.drainDirty()
    #expect(drained.count == 2 && drained.allSatisfy { $0.endReason == .idle })
    #expect(table.drainDirty().isEmpty)
}

@Test func setServerNameMarksDirty() async throws {
    let p = try await decode([Spec()])
    var table = FlowTable()
    _ = table.add(p[0])
    _ = table.drainDirty()
    let key = FlowKey(
        transport: .tcp, localAddress: p[0].localAddress, localPort: 50000,
        remoteAddress: p[0].remoteAddress, remotePort: 443)
    table.setServerName("example.com", for: key)
    let drained = table.drainDirty()
    #expect(drained.count == 1 && drained[0].serverName == "example.com")
}

// MARK: fixtures

private struct FixtureResult {
    var decoded = 0
    var dropped = 0
    var droppedIPBytes = 0
    var decodedIPBytes = 0
    var flows: [Flow] = []
}

private func runFixture(_ url: URL) async throws -> FixtureResult {
    var decoder = PacketDecoder()
    var table = FlowTable()
    var result = FixtureResult()
    for try await event in FilePacketSource(url: url).events() {
        guard case .packet(let raw) = event, case .success(let decoded) = decoder.decode(raw) else { continue }
        result.decoded += 1
        result.decodedIPBytes += decoded.headers.ipBytes
        let t = decoded.headers.transport
        if !(t == .tcp || t == .udp) || decoded.localPort == nil || decoded.remotePort == nil {
            result.dropped += 1
            result.droppedIPBytes += decoded.headers.ipBytes
        }
        _ = table.add(decoded)
        _ = table.expire(at: decoded.timestamp)
        result.flows += table.drainDirty().filter { $0.endReason != nil }
    }
    _ = table.closeAll(reason: .captureStopped)
    result.flows += table.drainDirty()
    return result
}

@Test(arguments: Fixtures.all)
func fixtureInvariants(_ name: String) async throws {
    guard let url = Fixtures.url(name) else { return }
    let clock = ContinuousClock()
    var result = FixtureResult()
    let elapsed = try await clock.measure { result = try await runFixture(url) }
    let flows = result.flows

    #expect(Set(flows.map(\.id)).count == flows.count)
    #expect(flows.allSatisfy { $0.endReason != nil })
    let packets = flows.reduce(0) { $0 + $1.packetsIn + $1.packetsOut }
    #expect(packets + result.dropped == result.decoded)
    let ipBytes = flows.reduce(0) { $0 + $1.ipBytesIn + $1.ipBytesOut }
    #expect(ipBytes + result.droppedIPBytes == result.decodedIPBytes)
    #expect(flows.allSatisfy { $0.tally.values.reduce(0, +) == $0.packetsIn + $0.packetsOut })
    #expect(flows.allSatisfy { $0.firstSeen <= $0.lastSeen })

    let multiTally = flows.filter { $0.tally.keys.filter { $0 != .none }.count > 1 }.count
    let multiApp = flows.filter { flow in
        Set(flow.tally.keys.compactMap { $0.effectiveName ?? $0.processName }).count > 1
    }.count
    var reasons: [FlowEndReason: Int] = [:]
    for f in flows { reasons[f.endReason!, default: 0] += 1 }
    print(
        "flows[\(name)]: flows=\(flows.count) multiTally=\(multiTally) multiApp=\(multiApp)",
        "decoded=\(result.decoded) dropped=\(result.dropped) packetsInFlows=\(packets)",
        "reasons=\(reasons.map { "\($0.key.rawValue):\($0.value)" }.sorted())",
        "time=\(elapsed)")
}

@Test func requeueClosedFlowAppearsOnce() async throws {
    var table = FlowTable()
    let packets = try await decode([Spec(flags: 0x04, process: 0)])
    for p in packets { _ = table.add(p) }
    let first = table.drainDirty()
    #expect(first.count == 1 && first[0].endReason == .rst)
    table.requeue(first)
    let second = table.drainDirty()
    #expect(second.count == 1 && second[0].id == first[0].id)
    #expect(table.drainDirty().isEmpty)
}

@Test func requeueOpenFlowKeepsLatestData() async throws {
    var table = FlowTable()
    let packets = try await decode([Spec(process: 0), Spec(at: 1, process: 0)])
    _ = table.add(packets[0])
    let old = table.drainDirty()
    #expect(old.count == 1 && old[0].packetsOut == 1)
    _ = table.add(packets[1])
    table.requeue(old)
    let out = table.drainDirty()
    #expect(out.count == 1 && out[0].packetsOut == 2)
    #expect(table.drainDirty().isEmpty)
    // an open flow that left the table is ignored
    _ = table.closeAll(reason: .captureStopped)
    _ = table.drainDirty()
    table.requeue(old)
    #expect(table.drainDirty().isEmpty)
}

// tcp flag bits: fin 0x01, syn 0x02, rst 0x04, psh 0x08, ack 0x10
private func firstFlow(_ spec: Spec) async throws -> Flow {
    let p = try await decode([spec])
    var table = FlowTable()
    _ = table.add(p[0])
    let drained = table.drainDirty()
    return drained[0]
}

@Test func synFirstIsNotMidstream() async throws {
    #expect(try await firstFlow(Spec(flags: 0x02)).startedMidstream == false)
}

@Test func ackPshFirstIsMidstream() async throws {
    #expect(try await firstFlow(Spec(flags: 0x18)).startedMidstream)
}

@Test func synAckFirstIsNotMidstream() async throws {
    #expect(try await firstFlow(Spec(dir: .inbound, flags: 0x12)).startedMidstream == false)
}

@Test func rstFirstIsMidstream() async throws {
    let p = try await decode([Spec(flags: 0x04)])
    var table = FlowTable()
    guard case .opened(let opened) = table.add(p[0]) else { Issue.record("expected opened"); return }
    #expect(opened.startedMidstream)
    let drained = table.drainDirty()
    #expect(drained.count == 1 && drained[0].endReason == .rst && drained[0].startedMidstream)
}

@Test func udpIsNeverMidstream() async throws {
    #expect(try await firstFlow(Spec(proto: 17)).startedMidstream == false)
    #expect(try await firstFlow(Spec(proto: 17, flags: 0x10)).startedMidstream == false)
}

@Test func reappearAfterIdleIsMidstream() async throws {
    let p = try await decode([Spec(flags: 0x02), Spec(at: 200, flags: 0x10)])
    var table = FlowTable()
    _ = table.add(p[0])
    let closed = table.expire(at: t0.addingTimeInterval(120))
    #expect(closed.count == 1 && closed[0].endReason == .idle && closed[0].startedMidstream == false)
    guard case .opened(let again) = table.add(p[1]) else { Issue.record("expected opened"); return }
    #expect(again.startedMidstream)
}

@Test func flagSurvivesDrain() async throws {
    let p = try await decode([Spec(flags: 0x10), Spec(dir: .inbound, at: 1, flags: 0x10)])
    var table = FlowTable()
    _ = table.add(p[0])
    _ = table.add(p[1])
    let drained = table.drainDirty()
    #expect(drained.count == 1 && drained[0].startedMidstream)
}
