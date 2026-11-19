import Attribution
import Flows
import Domains
import Foundation
import PacketDecoder
import Testing

@testable import WatchApp

private func flow(
    _ tally: [ProcessPair: Int], bytes: Int, packets: Int? = nil, port: UInt16 = 443, name: String? = nil,
    remote: IPAddress = .v4(0x5DB8_D822)
) -> Flow {
    let key = FlowKey(
        transport: .tcp, localAddress: .v4(0x0A00_0002), localPort: 50_000 + port,
        remoteAddress: remote, remotePort: port)
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
    ]).rows
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
    ]).rows
    #expect(rows.count == 1)
    #expect(rows[0].name == "Unattributed")
    #expect(rows[0].kind == .unattributed)
    #expect(rows[0].packets == 5)
    #expect(rows[0].ipBytes == 400)
}

@Test func systemProcessRowIsLabelled() {
    let rows = groupByProcess(from: [flow([ProcessPair("apsd", 50, nil, nil): 2], bytes: 100)]).rows
    #expect(rows.map(\.name) == ["System: apsd"])
    #expect(rows[0].kind == .system)
}

@Test func lookupsSayWhichAppsTheyWereFor() {
    let rows = groupByProcess(from: [
        flow([ProcessPair("mDNSResponder", 212, "TikTok", 7): 2], bytes: 100),
        flow([ProcessPair("mDNSResponder", 212, "Safari", 9): 1], bytes: 60, port: 53),
    ]).rows
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
    #expect(groupByProcess(from: flows).rows.map(\.name) == ["Big", "Mid", "Small"])

    let withEmpty = groupByProcess(from: flows, withEmptyUnattributed: true).rows
    #expect(withEmpty.map(\.name) == ["Big", "Mid", "Small", "Unattributed"])
    #expect(withEmpty.last?.packets == 0)
    #expect(unattributedShare(withEmpty) == 0)
    #expect(unattributedShare([]) == nil)
}

@Test func unattributedShareCountsPackets() {
    let rows = groupByProcess(from: [
        flow([ProcessPair("A", 1, nil, nil): 3], bytes: 10, port: 1),
        flow([.none: 1], bytes: 10, port: 2),
    ]).rows
    #expect(unattributedShare(rows) == 0.25)
}

@Test func topFlowsKeepTenBiggest() {
    let flows = (0..<15).map { flow([ProcessPair("A", 1, nil, nil): 1], bytes: $0 * 10, port: UInt16($0 + 1)) }
    let top = topFlows(flows)
    #expect(top.count == 10)
    #expect(top.first?.ipBytes == 140)
    #expect(top.last?.ipBytes == 50)
}

// MARK: - categories

private let privateAddress = IPAddress.v4(0xC0A8_0105)

private func mixedFlows() -> [Flow] {
    [
        flow([ProcessPair("TikTok", 100, nil, nil): 5], bytes: 1000, port: 1),
        flow([ProcessPair("mDNSResponder", 212, nil, nil): 2], bytes: 300, port: 2, remote: privateAddress),
        flow([ProcessPair("lockdownd", 9, nil, nil): 4], bytes: 700, port: 3),
        flow([.none: 1], bytes: 50, port: 4),
    ]
}

@Test func groupByProcessSeparatesSetAsideRows() {
    let result = groupByProcess(from: mixedFlows())
    #expect(result.rows.map(\.name) == ["TikTok", "Unattributed"])
    #expect(result.setAside.count == 2)
    let byCategory = Dictionary(uniqueKeysWithValues: result.setAside.map { ($0.category!, $0) })
    #expect(byCategory[.deviceLink]?.ipBytes == 700)
    #expect(byCategory[.localNetwork]?.ipBytes == 300)
    #expect(byCategory[.localNetwork]?.children.map(\.name) == ["System: mDNSResponder"])
    #expect(byCategory[.deviceLink]?.children.map(\.name) == ["lockdownd"])
}

@Test func phoneTrafficTotalExcludesSetAside() {
    let result = groupByProcess(from: mixedFlows())
    #expect(result.phoneBytes == 1050)
    #expect(result.setAsideBytes == 1000)
    #expect(result.phoneBytes + result.setAsideBytes == 2050)
}

@Test func labelsComeFromTrafficCategory() {
    let result = groupByProcess(from: mixedFlows())
    #expect(result.setAside.map(\.name) == [TrafficCategory.deviceLink.label, TrafficCategory.localNetwork.label])
    let lines = topFlows(mixedFlows())
    #expect(lines.compactMap(\.setAsideLabel).sorted() == [TrafficCategory.deviceLink.label, TrafficCategory.localNetwork.label].sorted())
}

@Test func unattributedRowStillPresentWhenEmpty() {
    let result = groupByProcess(from: [] as [TallyInput], withEmptyUnattributed: true)
    #expect(result.rows.map(\.name) == ["Unattributed"])
    #expect(result.rows[0].packets == 0)
    #expect(result.setAside.count == 2)
    #expect(result.setAside.allSatisfy { $0.ipBytes == 0 && $0.children.isEmpty })
}

@Test func sessionDetailInputsCarryFlowCategory() {
    // one flow with two tally rows: both rows land in the flow's category, bytes shared by packets
    let f = flow([ProcessPair("lockdownd", 9, nil, nil): 3, ProcessPair("lockdownd", 10, nil, nil): 1], bytes: 400)
    let result = groupByProcess(from: tallyInputs(from: [f]))
    #expect(result.rows.isEmpty)
    #expect(result.setAside.first { $0.category == .deviceLink }?.ipBytes == 400)
}

@Test func displayNamesReplaceRawNamesAndRawStaysInDetail() {
    let rows = groupByProcess(from: [flow([ProcessPair("appstorecomponen", 5, nil, nil): 2], bytes: 100)]).rows
    #expect(rows[0].name == ProcessNames.displayName("appstorecomponen"))
    #expect(rows[0].name != "appstorecomponen")
    #expect(rows[0].rawNames == ["appstorecomponen"])
    #expect(rows[0].rawNameNote?.contains("appstorecomponen") == true)
    let line = topFlows([flow([ProcessPair("appstorecomponen", 5, nil, nil): 2], bytes: 100)])[0]
    #expect(line.attribution.contains(ProcessNames.displayName("appstorecomponen")))
}

// MARK: - hostname labels

private let t0 = Date(timeIntervalSince1970: 1_763_000_000)

private func dnsAnswer(_ host: String, _ address: IPAddress, ago: TimeInterval = 5) -> DomainObservation {
    DomainObservation(time: t0.addingTimeInterval(-ago), source: .dns, hostname: host, addresses: [address], ttl: 300)
}

@Test func flowLineShowsSourceLabel() {
    let sni = flow([ProcessPair("TikTok", 1, nil, nil): 1], bytes: 500, port: 1, name: "a.example.com")
    let viaDNS = flow([ProcessPair("TikTok", 1, nil, nil): 1], bytes: 400, port: 2, remote: .v4(0xC000_0201))
    var midstream = flow([ProcessPair("TikTok", 1, nil, nil): 1], bytes: 300, port: 3, remote: .v4(0xC000_0202))
    midstream.startedMidstream = true
    var ech = flow([ProcessPair("TikTok", 1, nil, nil): 1], bytes: 200, port: 4, remote: .v4(0xC000_0203))
    ech.echSeen = true
    let plain = flow([ProcessPair("TikTok", 1, nil, nil): 1], bytes: 100, port: 5, remote: .v4(0xC000_0204))

    let lines = topFlows(
        [sni, viaDNS, midstream, ech, plain],
        observations: [dnsAnswer("b.example.net", .v4(0xC000_0201), ago: 2.5)])
    #expect(lines.map(\.ipBytes) == [500, 400, 300, 200, 100])

    #expect(lines[0].hostname == "a.example.com" && lines[0].hostnameSource == .sni)
    #expect(lines[0].hostnameNote == "Seen in connection")

    // a dns name never reads as an observed one, and says so
    #expect(lines[1].hostname == "b.example.net" && lines[1].hostnameSource == .dns)
    #expect(lines[1].hostnameNote != lines[0].hostnameNote)
    #expect(lines[1].hostnameNote.contains("DNS") && lines[1].hostnameNote.contains("may differ"))
    #expect(lines[1].hostnameDetail == "From DNS (may be another service on the same server). The DNS answer came 2.5 s before the connection")
    #expect(lines[1].dnsAgeSeconds == 2.5)

    #expect(lines[2].hostname == nil && lines[2].hostnameNote == "Connection started before capture")
    #expect(lines[3].hostnameNote == "Name hidden by the app (ECH)")
    #expect(lines[4].hostnameNote == "No name found")
}

@Test func flowLineLabelsSameAddressHint() {
    let remote = IPAddress.v4(0xC000_0210)
    let named = flow([ProcessPair("TikTok", 1, nil, nil): 1], bytes: 500, port: 1, name: "a.example.com", remote: remote)
    let unnamed = flow([ProcessPair("TikTok", 1, nil, nil): 1], bytes: 400, port: 2, remote: remote)
    let lines = topFlows([named, unnamed])
    #expect(lines[0].hostnameSource == .sni)
    #expect(lines[1].hostname == "a.example.com" && lines[1].hostnameSource == .sameAddress)
    // it never reads as an observed name
    #expect(lines[1].hostnameNote == "Same server as another connection, may differ")
    #expect(lines[1].hostnameDetail.contains("may be another service"))
}

@Test func indexBuiltOncePerRefresh() {
    let flows = (0..<100).map { flow([ProcessPair("A", 1, nil, nil): 1], bytes: $0, port: UInt16($0 + 1)) }
    var builds = 0
    let lines = topFlows(flows, observations: [], limit: 100) { observations, flows in
        builds += 1
        return HostnameIndex(observations, flows: flows)
    }
    #expect(lines.count == 100)
    #expect(builds == 1)
}

// MARK: - caps

@Test func liveFoldLine() {
    let flows = (0..<600).map { flow([ProcessPair("A", 1, nil, nil): 1], bytes: $0, port: UInt16($0 + 1)) }
    let rows = flowRows(flows)
    #expect(rows.lines.count == 500)
    #expect(rows.moreFlows == 100)
    #expect(rows.foldLine == "100 more flows")
    // the biggest flows are the ones shown
    #expect(rows.lines.first?.ipBytes == 599 && rows.lines.last?.ipBytes == 100)
    // nothing left out, no fold line; one left out is singular
    #expect(flowRows(Array(flows.prefix(500))).foldLine == nil)
    #expect(flowRows(Array(flows.prefix(11)), limit: 10).foldLine == "1 more flow")
}

@Test func gapTextShowsOnlyWhenThereAreGaps() {
    #expect(gapText(count: 0, maxGapMs: 0) == nil)
    #expect(gapText(count: 2, maxGapMs: 41_000) == "Gaps: 2 (longest 41 s)")
    #expect(gapText(count: 1, maxGapMs: 5_001) == "Gaps: 1 (longest 5 s)")
}

@Test func kernelDroppedTextOnlyForKnownNonzero() {
    #expect(kernelDroppedText(nil) == nil)
    #expect(kernelDroppedText(0) == nil)
    #expect(kernelDroppedText(12)?.contains("12 packets") == true)
}
