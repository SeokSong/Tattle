import Flows
import Foundation
import PacketDecoder
import Testing

@testable import WatchApp

private func flow(
    _ tally: [ProcessPair: Int], bytes: Int, packets: Int? = nil, port: UInt16 = 443, name: String? = nil
) -> Flow {
    let key = FlowKey(
        transport: .tcp, localAddress: .v4(0x0A00_0002), localPort: 50_000 + port,
        remoteAddress: .v4(0x5DB8_D822), remotePort: port)
    var flow = Flow(key: key, interface: "rvi0", at: Date(timeIntervalSince1970: 1_763_000_000))
    flow.tally = tally
    flow.ipBytesIn = bytes
    flow.packetsIn = packets ?? tally.values.reduce(0, +)
    flow.serverName = name
    return flow
}

@Test func appWithTwoPidsCollapsesToOneRow() {
    let rows = groupByProcess(from: [
        flow([ProcessPair("TikTok", 100, nil, nil): 5], bytes: 1000, port: 443),
        flow([ProcessPair("TikTok", 200, nil, nil): 3], bytes: 500, port: 444),
    ])
    #expect(rows.count == 1)
    #expect(rows[0].name == "TikTok")
    #expect(rows[0].kind == .app)
    #expect(rows[0].pids == [100, 200])
    #expect(rows[0].packets == 8)
    #expect(rows[0].ipBytes == 1500)
}

@Test func noneOnlyTallyIsUnattributed() {
    let rows = groupByProcess(from: [
        flow([.none: 4], bytes: 300),
        flow([:], bytes: 100, packets: 1, port: 80),
    ])
    #expect(rows.count == 1)
    #expect(rows[0].name == "Unattributed")
    #expect(rows[0].kind == .unattributed)
    #expect(rows[0].packets == 5)
    #expect(rows[0].ipBytes == 400)
}

@Test func systemProcessRowIsLabelled() {
    let rows = groupByProcess(from: [flow([ProcessPair("apsd", 50, nil, nil): 2], bytes: 100)])
    #expect(rows.map(\.name) == ["System: apsd"])
    #expect(rows[0].kind == .system)
}

@Test func lookupsSayWhichAppsTheyWereFor() {
    let rows = groupByProcess(from: [
        flow([ProcessPair("mDNSResponder", 212, "TikTok", 7): 2], bytes: 100),
        flow([ProcessPair("mDNSResponder", 212, "Safari", 9): 1], bytes: 60, port: 53),
    ])
    #expect(rows.count == 1)
    #expect(rows[0].name == "System: mDNSResponder")
    #expect(rows[0].forApps == ["Safari", "TikTok"])
}

@Test func rowsSortedByBytesAndUnattributedStaysWhenEmpty() {
    let flows = [
        flow([ProcessPair("Small", 1, nil, nil): 1], bytes: 10, port: 1),
        flow([ProcessPair("Big", 2, nil, nil): 1], bytes: 9000, port: 2),
        flow([ProcessPair("Mid", 3, nil, nil): 1], bytes: 500, port: 3),
    ]
    #expect(groupByProcess(from: flows).map(\.name) == ["Big", "Mid", "Small"])

    let withEmpty = groupByProcess(from: flows, withEmptyUnattributed: true)
    #expect(withEmpty.map(\.name) == ["Big", "Mid", "Small", "Unattributed"])
    #expect(withEmpty.last?.packets == 0)
    #expect(unattributedShare(withEmpty) == 0)
    #expect(unattributedShare([]) == nil)
}

@Test func unattributedShareCountsPackets() {
    let rows = groupByProcess(from: [
        flow([ProcessPair("A", 1, nil, nil): 3], bytes: 10, port: 1),
        flow([.none: 1], bytes: 10, port: 2),
    ])
    #expect(unattributedShare(rows) == 0.25)
}

@Test func topFlowsKeepTenBiggest() {
    let flows = (0..<15).map { flow([ProcessPair("A", 1, nil, nil): 1], bytes: $0 * 10, port: UInt16($0 + 1)) }
    let top = topFlows(flows)
    #expect(top.count == 10)
    #expect(top.first?.ipBytes == 140)
    #expect(top.last?.ipBytes == 50)
}
