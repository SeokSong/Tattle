import Domains
import Flows
import Foundation
import PacketDecoder
import Testing

@testable import TattleApp

// 5.1: the app filter on Live and Sessions, and the connection detail sheet

private let t0 = Date(timeIntervalSince1970: 1_763_000_000)

private func flow(_ n: UInt32, process: String?, name: String?, bytes: Int = 100) -> Flow {
    let key = FlowKey(transport: .tcp, localAddress: .v4(0x0A00_0002), localPort: UInt16(40000 + n),
                      remoteAddress: .v4(0xC000_0200 + n), remotePort: 443)
    var f = Flow(key: key, interface: "en0", at: t0)
    f.serverName = name
    f.ipBytesIn = bytes
    f.packetsIn = 4
    f.packetsOut = 3
    if let process { f.tally[ProcessPair(process, n, nil, nil)] = 3 }
    return f
}

private let flows = [
    flow(1, process: "Zappyx", name: "doubleclick.net", bytes: 500),
    flow(2, process: "Zappyx", name: "unknown-z.test", bytes: 300),
    flow(3, process: "Quillx", name: "doubleclick.net", bytes: 200),
    flow(4, process: "apsd", name: "unknown-s.test", bytes: 100),
    flow(5, process: nil, name: "unknown-n.test", bytes: 50),
]

@Test func filterDefaultsToAllApps() {
    #expect(topFlows(flows).count == 5)
    #expect(filterCaption(app: nil, appCount: 4) == nil)
    #expect(appNames(in: flows) == ["iOS system", "No process info", "Quillx", "Zappyx"])
}

@Test func filterKeepsTotalsLabelled() {
    let zappy = topFlows(flows, app: "Zappyx")
    #expect(zappy.count == 2 && zappy.allSatisfy { $0.appName == "Zappyx" })
    #expect(filterCaption(app: "Zappyx", appCount: 4) == "Showing 1 of 4 apps")
    #expect(filterCaption(app: "Zappyx", appCount: 1) == "Showing 1 of 1 app")
    // the "N more flows" line counts only the filtered app's flows
    #expect(flowRows(flows, limit: 1, app: "Zappyx").moreFlows == 1)
    #expect(flowRows(flows, limit: 1).moreFlows == 4)
}

@Test func filterDoesNotAffectStoredData() {
    let before = flows.map(\.id)
    _ = topFlows(flows, app: "Quillx")
    _ = flowRows(flows, app: "Quillx")
    #expect(flows.map(\.id) == before)
    #expect(topFlows(flows, app: "Quillx").map(\.id) == [flows[2].id])
}

@Test func detailShowsSourceAndVersion() throws {
    let line = try #require(topFlows(flows).first { $0.hostname == "doubleclick.net" })
    let rows = Dictionary(line.detailRows.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
    #expect(rows["Name"] == "doubleclick.net")
    #expect(rows["Where the name came from"] == "Seen in connection")
    #expect(rows["Company"]?.contains("Advertising") == true)
    #expect(rows["Company source"]?.hasPrefix("Company list version") == true)
    #expect(rows["Packets"] == "7")
    #expect(rows["Address"]?.hasSuffix("(TCP)") == true)
    #expect(rows["First seen"] != nil && rows["Last seen"] != nil)
}

@Test func hintDetailSaysMayBeAnotherService() throws {
    // no name in the connection; a DNS answer for its address names doubleclick.net: a hint, never a fact
    let unnamed = flow(9, process: "Zappyx", name: nil)
    let dns = DomainObservation(time: t0.addingTimeInterval(-2), source: .dns, hostname: "doubleclick.net",
                                addresses: [unnamed.key.remoteAddress])
    let line = try #require(topFlows([unnamed], observations: [dns]).first)
    let rows = Dictionary(line.detailRows.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
    #expect(rows["Where the name came from"]?.hasPrefix("From DNS (may be another service on the same server)") == true)
    #expect(rows["Company"]?.hasPrefix("Possible: ") == true)
    #expect(rows["Company source"]?.contains("may belong to another service") == true)
}

@Test func detailOfAnUnnamedConnectionHasNoRepeatedReason() throws {
    // review of PR #13: the reason is the Name row; "Where the name came from" would repeat it
    let unnamed = flow(10, process: "Zappyx", name: nil)
    let line = try #require(topFlows([unnamed]).first)
    #expect(line.detailRows.map(\.label).contains("Where the name came from") == false)
    #expect(line.detailRows.first?.label == "Name")
}

@Test func filteredRowsCountTheRestForEveryScreen() {
    // review of PR #13: the "N more flows" line counts only the filtered app's flows, on Sessions as on Live
    let many = (0..<15).map { flow(UInt32(20 + $0), process: "Zappyx", name: "unknown-\($0).test") } + flows
    let rows = flowRows(many, limit: 10, app: "Zappyx")
    #expect(rows.lines.count == 10)
    #expect(rows.moreFlows == 17 - 10)
}
