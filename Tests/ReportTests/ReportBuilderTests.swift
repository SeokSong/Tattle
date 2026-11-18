import Flows
import Foundation
import PacketDecoder
import Testing

@testable import Report

private let t0 = Date(timeIntervalSince1970: 1_763_000_000)

// documentation ranges: 192.0.2.0/24 and 2001:db8::/32
private func flow(
    bytes: Int, app: String? = "TikTok", port: UInt16 = 443, name: String? = nil,
    iface: String = "en0", v6: Bool = false, packets: Int = 2, remote override: IPAddress? = nil
) -> Flow {
    let remote: IPAddress = override ?? (v6 ? .v6(hi: 0x2001_0DB8_0000_0000, lo: 1) : .v4(0xC000_0201))
    let key = FlowKey(
        transport: .tcp, localAddress: .v4(0x0A00_0002), localPort: UInt16.random(in: 40000...60000),
        remoteAddress: remote, remotePort: port)
    var f = Flow(key: key, interface: iface, at: t0)
    f.ipBytesIn = bytes
    f.packetsIn = packets
    f.tally[app.map { ProcessPair($0, 1, nil, nil) } ?? .none] = packets
    f.serverName = name
    return f
}

private func build(_ flows: [Flow], _ p: PipelineSnapshot? = nil, detail: Bool = false) -> QualityReport {
    ReportBuilder.build(flows: flows, domains: [], pipeline: p, options: ReportOptions(detail: detail))
}

@Test func totalsMatchFlows() {
    let r = build([flow(bytes: 100), flow(bytes: 200), flow(bytes: 300)])
    #expect(r.totals.ipBytes == 600)
    #expect(r.totals.flows == 3)
    #expect(r.byInterface == ["en0": 600])
}

@Test func attributedShareCountsM1Primary() {
    let r = build([flow(bytes: 100, app: nil), flow(bytes: 300)])
    #expect(r.attribution.attributedShare == Ratio(numerator: 300, denominator: 400))
    #expect(r.attribution.noProcessShare == Ratio(numerator: 100, denominator: 400))
}

@Test func mixedFlowShareUsesTwoAppNames() {
    var f = flow(bytes: 100)
    f.tally[ProcessPair("Instagram", 2, nil, nil)] = 1
    let r = build([f, flow(bytes: 100)])
    #expect(r.attribution.mixedFlowShare == Ratio(numerator: 100, denominator: 200))
}

@Test func sniOnlyCoverageUsesPort443() {
    let r = build([
        flow(bytes: 200, name: "a.example"), flow(bytes: 100), flow(bytes: 50, port: 80, name: "b.example"),
    ])
    #expect(r.hostnames.hostnameCoverageSniOnly == Ratio(numerator: 200, denominator: 300))
}

@Test func reconciliationPassesAndFails() {
    let flows = [flow(bytes: 100, packets: 3), flow(bytes: 100, packets: 4)]
    let good = PipelineSnapshot(packets: 10, decoded: 8, skipped: 1, malformed: 1, droppedNoPort: 1)
    #expect(build(flows, good).reconciliation.ok)
    let bad = PipelineSnapshot(packets: 10, decoded: 9, skipped: 0, malformed: 1, droppedNoPort: 1)
    let r = build(flows, bad)
    #expect(!r.reconciliation.ok)
    #expect(r.reconciliation.checks.filter { !$0.ok }.map(\.name) == ["decodedAccounted"])
    // no snapshot: pipeline checks are skipped
    #expect(!build(flows).reconciliation.checks.contains { $0.name == "packetsRead" })
}

@Test func flowTimesCheckFailsOnBackwardsFlow() {
    var f = flow(bytes: 10)
    f.lastSeen = t0.addingTimeInterval(-1)
    let r = build([f])
    #expect(!r.reconciliation.ok)
    #expect(r.reconciliation.checks.first { $0.name == "flowTimes" }?.ok == false)
}

@Test func orderDoesNotMatter() throws {
    let flows = (1...8).map { flow(bytes: $0 * 10, app: $0 % 3 == 0 ? nil : "App\($0 % 2)", name: $0 % 2 == 0 ? "h.example" : nil) }
    let a = try build(flows, detail: true).json()
    let b = try build(flows.shuffled(), detail: true).json()
    let c = try build(flows.shuffled(), detail: true).json()
    #expect(a == b && b == c)
}

@Test func jsonHasNoNamesWithoutDetail() throws {
    let flows = [flow(bytes: 100, name: "secret.example")]
    let plain = try build(flows).json()
    #expect(!plain.contains("TikTok") && !plain.contains("secret.example") && !plain.contains("192.0.2"))
    let detailed = try build(flows, detail: true).json()
    #expect(detailed.contains("TikTok"))
    #expect(!detailed.contains("secret.example"))
}

@Test func zeroDenominatorHasNoValue() throws {
    let r = build([])
    #expect(r.reconciliation.ok)
    #expect(r.attribution.attributedShare.value == nil)
    #expect(r.hostnames.hostnameCoverageSniOnly.value == nil)
    #expect(!(try r.json().contains("\"value\"")))
}

@Test func ipv6AndFragmentedFlowsCount() {
    var odd = flow(bytes: 50, v6: true)
    odd.unknownDirectionPackets = 2
    let r = build([flow(bytes: 100, v6: true), odd])
    #expect(r.totals.ipBytes == 150)
    #expect(r.totals.flows == 2)
    #expect(r.attribution.attributedShare == Ratio(numerator: 150, denominator: 150))
}

@Test func sampleJSON() throws {
    let flows = [flow(bytes: 200, name: "a.example"), flow(bytes: 100, app: nil), flow(bytes: 50, port: 80)]
    let p = PipelineSnapshot(packets: 7, decoded: 6, skipped: 1, malformed: 0, droppedNoPort: 0)
    let json = try build(flows, p).json()
    print(json)
    #expect(json.contains("\"reportVersion\" : 1"))
}

@Test func movedOutOfAppBytesCountsHeartbeatd() {
    // M1 called heartbeatd an app; the classifier moves it to deviceLink
    let r = build([flow(bytes: 100, app: "heartbeatd"), flow(bytes: 300)])
    #expect(r.categories.byCategory["deviceLink"]?.ipBytes == 100)
    #expect(r.categories.movedOutOfAppBytes == ["deviceLink": 100, "localNetwork": 0])
    #expect(r.categories.rules["deviceLink.process"] == 100)
    // M1 numbers are unchanged: heartbeatd still counts as attributed
    #expect(r.attribution.attributedShare == Ratio(numerator: 400, denominator: 400))
}

@Test func appToPrivateAddressNotMoved() {
    // 192.168.1.20 is a LAN address, but the flow is tagged with an app: it stays in app
    let r = build([flow(bytes: 500, app: "Plex", remote: .v4(0xC0A8_0114))])
    #expect(r.categories.byCategory["app"]?.ipBytes == 500)
    #expect(r.categories.byCategory["localNetwork"]?.ipBytes == 0)
    #expect(r.categories.movedOutOfAppBytes == ["deviceLink": 0, "localNetwork": 0])
}

@Test func systemTopProcessShareHidesNames() throws {
    let flows = [flow(bytes: 300, app: "locationd"), flow(bytes: 100, app: "apsd"), flow(bytes: 100, app: "locationd")]
    let plain = build(flows)
    #expect(plain.categories.byCategory["system"]?.ipBytes == 500)
    // locationd 300 + 100 = 400 of 500
    #expect(plain.categories.systemTopProcessShare == Ratio(numerator: 400, denominator: 500))
    let json = try plain.json()
    #expect(json.contains("systemTopProcessShare"))
    #expect(!json.contains("locationd") && !json.contains("apsd"))
    let detailed = build(flows, detail: true)
    #expect(detailed.detail?.systemTopProcess == "locationd")
    #expect(detailed.detail?.systemProcesses.map(\.name) == ["locationd", "apsd"])
}

@Test func deviceLinkProcessesListedInDetail() {
    let r = build([flow(bytes: 100, app: "heartbeatd"), flow(bytes: 50, app: "lockdownd")], detail: true)
    #expect(r.detail?.deviceLinkProcesses.map(\.name) == ["heartbeatd", "lockdownd"])
    #expect(build([flow(bytes: 100, app: "heartbeatd")]).detail == nil)
}

@Test func unknownShareAndNoProcessShareDiffer() {
    // F5 shape: no process, multicast. noProcessShare counts it; the category is localNetwork, not unknown
    let mdns = flow(bytes: 156, app: nil, port: 5353, remote: .v4(0xE000_00FB))
    let r = build([mdns, flow(bytes: 100, app: nil), flow(bytes: 300)])
    #expect(r.attribution.noProcessShare == Ratio(numerator: 256, denominator: 556))
    #expect(r.categories.byCategory["localNetwork"]?.ipBytes == 156)
    #expect(r.categories.unknownShare == Ratio(numerator: 100, denominator: 556))
    #expect(r.categories.movedOutOfAppBytes["localNetwork"] == 0)
    let text = ReportRendering.text(r)
    #expect(text.contains("unknownShare can be lower because rules reclassify"))
}

@Test func categoriesCoverEveryFlowOnce() {
    let flows = [flow(bytes: 10), flow(bytes: 20, app: nil), flow(bytes: 30, app: "mDNSResponder"), flow(bytes: 40, app: "lockdownd")]
    let r = build(flows)
    #expect(r.categories.byCategory.count == 6)
    #expect(r.categories.byCategory.values.map(\.flows).reduce(0, +) == 4)
    #expect(r.categories.rules.values.reduce(0, +) == 100)
    // phone traffic = everything but deviceLink: 60 of 100
    #expect(r.categories.phoneTrafficShare == Ratio(numerator: 60, denominator: 100))
}
