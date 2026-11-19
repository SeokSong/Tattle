import Attribution
import Domains
import Flows
import Foundation
import PCAPNG
import PacketDecoder
import Testing

@testable import Report

private let t0 = Date(timeIntervalSince1970: 1_763_000_000)

// documentation ranges: 192.0.2.0/24 and 2001:db8::/32
private func flow(
    bytes: Int, app: String? = "TikTok", port: UInt16 = 443, name: String? = nil,
    iface: String = "en0", v6: Bool = false, packets: Int = 2, remote override: IPAddress? = nil,
    udp: Bool = false, midstream: Bool = false, ech: Bool = false
) -> Flow {
    let remote: IPAddress = override ?? (v6 ? .v6(hi: 0x2001_0DB8_0000_0000, lo: 1) : .v4(0xC000_0201))
    let key = FlowKey(
        transport: udp ? .udp : .tcp, localAddress: .v4(0x0A00_0002), localPort: UInt16.random(in: 40000...60000),
        remoteAddress: remote, remotePort: port)
    var f = Flow(key: key, interface: iface, at: t0)
    f.ipBytesIn = bytes
    f.packetsIn = packets
    f.tally[app.map { ProcessPair($0, 1, nil, nil) } ?? .none] = packets
    f.serverName = name
    f.startedMidstream = midstream
    f.echSeen = ech
    return f
}

private func build(
    _ flows: [Flow], _ p: PipelineSnapshot? = nil, detail: Bool = false, domains: [DomainObservation] = []
) -> QualityReport {
    ReportBuilder.build(flows: flows, domains: domains, pipeline: p, options: ReportOptions(detail: detail))
}

// a dns answer for `address`, `ago` seconds before the flows (which start at t0); no process, so any app matches
private func answer(_ host: String, _ address: IPAddress, ago: TimeInterval = 5) -> DomainObservation {
    DomainObservation(time: t0.addingTimeInterval(-ago), source: .dns, hostname: host, addresses: [address], ttl: 300)
}

private func addr(_ n: UInt32) -> IPAddress { .v4(0xC000_0200 + n) }

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

// MARK: hostnames (5.1)

@Test func coverageSplitsBySource() {
    // 400 bytes with an sni name, 100 named by dns, 500 unnamed (no dns answer, not midstream)
    let flows = [
        flow(bytes: 400, name: "a.example", remote: addr(1)),
        flow(bytes: 100, remote: addr(2)),
        flow(bytes: 500, remote: addr(3)),
    ]
    let r = build(flows, domains: [answer("b.example", addr(2))])
    let h = r.hostnames
    #expect(h.sniShare == Ratio(numerator: 400, denominator: 1000))
    #expect(h.dnsShare == Ratio(numerator: 100, denominator: 1000))
    // coverage counts observed names only: 400 sni of 1000. the 100 dns bytes are a hint
    #expect(h.hostnameCoverage == Ratio(numerator: 400, denominator: 1000))
    #expect(h.hostnameCoverage == h.sniShare)
    #expect(h.hintShare == Ratio(numerator: 100, denominator: 1000))
    #expect(h.unnamedShare["noDNSMatch"] == Ratio(numerator: 500, denominator: 1000))
    // the M1 figure keeps its own definition: any serverName over all 443 flows
    #expect(h.hostnameCoverageSniOnly == Ratio(numerator: 400, denominator: 1000))
}

@Test func reasonsAreFirstMatch() {
    // ech with a dns match is echHidden; a midstream flow with a dns match is dns
    let flows = [
        flow(bytes: 300, remote: addr(1), ech: true),
        flow(bytes: 200, remote: addr(2), midstream: true),
    ]
    let r = build(flows, domains: [answer("a.example", addr(1)), answer("b.example", addr(2))])
    #expect(r.hostnames.unnamedShare["echHidden"] == Ratio(numerator: 300, denominator: 500))
    #expect(r.hostnames.dnsShare == Ratio(numerator: 200, denominator: 500))
    #expect(r.hostnames.unnamedShare["startedBeforeCapture"] == Ratio(numerator: 0, denominator: 500))
    // an ech flow whose outer name was read is still echHidden
    let outer = build([flow(bytes: 100, name: "outer.example", ech: true)])
    #expect(outer.hostnames.sniShare == Ratio(numerator: 0, denominator: 100))
    #expect(outer.hostnames.unnamedShare["echHidden"] == Ratio(numerator: 100, denominator: 100))
    // midstream is a measure of its own: it counts the flow even when dns named it
    #expect(r.hostnames.midstreamShare == Ratio(numerator: 200, denominator: 500))
    #expect(r.hostnames.echShare == Ratio(numerator: 300, denominator: 500))
}

@Test func systemAndLocalFlowsAreNotInDenominator() {
    let base = [flow(bytes: 400, name: "a.example", remote: addr(1)), flow(bytes: 100, remote: addr(2))]
    let before = build(base).hostnames
    let extra = base + [
        flow(bytes: 900, app: "locationd", remote: addr(3)),
        flow(bytes: 700, app: nil, remote: addr(4)),
        flow(bytes: 50, app: "heartbeatd", remote: addr(5)),
        flow(bytes: 60, app: nil, remote: .v4(0xE000_00FB)),
    ]
    let after = build(extra).hostnames
    #expect(after.hostnameCoverage == before.hostnameCoverage)
    #expect(after.unnamedShare == before.unnamedShare)
    #expect(after.hostnameCoverage.denominator == 500)
    // the M1 figure still counts every 443 flow
    #expect(after.hostnameCoverageSniOnly.denominator == 400 + 100 + 900 + 700 + 50 + 60)
}

@Test func nonTlsPortsAreExcluded() {
    let r = build([
        flow(bytes: 100, name: "a.example", remote: addr(1)),
        flow(bytes: 500, port: 80, name: "b.example", remote: addr(2)),
        flow(bytes: 500, port: 5223, remote: addr(3)),
    ])
    #expect(r.hostnames.hostnameCoverage == Ratio(numerator: 100, denominator: 100))
}

@Test func reasonsPlusSourcesAddToOne() {
    let flows = [
        flow(bytes: 100, name: "a.example", remote: addr(1)),
        flow(bytes: 200, remote: addr(2)),
        flow(bytes: 300, remote: addr(3), midstream: true),
        flow(bytes: 400, remote: addr(4), ech: true),
        flow(bytes: 500, remote: addr(5), udp: true),
        flow(bytes: 600, remote: addr(6)),
    ]
    let r = build(flows, domains: [answer("b.example", addr(2))])
    let h = r.hostnames
    let parts = [h.sniShare, h.dnsShare, h.sameAddressShare] + h.unnamedShare.values
    #expect(parts.map(\.numerator).reduce(0, +) == 2100)
    #expect(parts.allSatisfy { $0.denominator == 2100 })
    let check = r.reconciliation.checks.first { $0.name == "hostnameReasons" }
    #expect(check == .init(name: "hostnameReasons", expected: 2100, actual: 2100, ok: true))
    #expect(r.reconciliation.ok)
    // no 443 app traffic: 0 over 0, and the check still passes
    #expect(build([flow(bytes: 10, port: 80)]).reconciliation.ok)
}

@Test func udpFlowWithoutNameIsNoHandshakeUDP() {
    let r = build([
        flow(bytes: 300, remote: addr(1), udp: true),
        flow(bytes: 100, name: "q.example", remote: addr(2), udp: true),
        flow(bytes: 50, remote: addr(3), udp: true, midstream: true),
    ])
    // a udp flow marked midstream (first payload a quic short header) is startedBeforeCapture; the others stay
    #expect(r.hostnames.unnamedShare["noHandshakeUDP"] == Ratio(numerator: 300, denominator: 450))
    #expect(r.hostnames.unnamedShare["startedBeforeCapture"] == Ratio(numerator: 50, denominator: 450))
    #expect(r.hostnames.sniShare == Ratio(numerator: 100, denominator: 450))
    #expect(r.hostnames.midstreamShare == Ratio(numerator: 50, denominator: 450))
}

@Test func midstreamUDPKeepsItsReasonOverNoHandshake() {
    let index = HostnameIndex([])
    #expect(index.unnamedReason(for: flow(bytes: 1, remote: addr(1), udp: true, midstream: true)) == .startedBeforeCapture)
    #expect(index.unnamedReason(for: flow(bytes: 1, remote: addr(1), udp: true)) == .noHandshakeUDP)
    // ech still wins over midstream
    #expect(index.unnamedReason(for: flow(bytes: 1, remote: addr(1), udp: true, midstream: true, ech: true)) == .echHidden)
}

// MARK: same-address hint (5.4)

@Test func sameAddressNamesAFlowWithoutAName() {
    // 200 bytes with an sni name, 100 bytes to the same address and app with none
    let flows = [flow(bytes: 200, name: "a.example", remote: addr(1)), flow(bytes: 100, remote: addr(1))]
    let r = build(flows)
    let h = r.hostnames
    #expect(h.sameAddressShare == Ratio(numerator: 100, denominator: 300))
    #expect(h.sniShare == Ratio(numerator: 200, denominator: 300))
    // a hint is not in the headline figure
    #expect(h.hostnameCoverage == Ratio(numerator: 200, denominator: 300))
    #expect(h.hintShare == Ratio(numerator: 100, denominator: 300))
    #expect(h.unnamedShare.values.allSatisfy { $0.numerator == 0 })
    #expect(r.reconciliation.ok)
    let named = HostnameIndex([], flows: flows).outcome(for: flows[1])
    guard case .named(let n) = named else { Issue.record("not named"); return }
    #expect(n.source == .sameAddress && n.name == "a.example" && n.dnsAgeSeconds == nil)
}

@Test func sameAddressNeedsSameAppAddressAndNoEch() {
    let named = flow(bytes: 100, name: "a.example", remote: addr(1))
    let index = HostnameIndex([], flows: [
        named, flow(bytes: 100, app: "Other", name: "o.example", remote: addr(2)),
        flow(bytes: 100, name: "x.example", remote: addr(3), ech: true),
    ])
    // another app at the same address, another address, an ech name (outer name) and no app: no hint
    #expect(index.resolveSameAddress(flow(bytes: 1, remote: addr(2))) == nil)
    #expect(index.resolveSameAddress(flow(bytes: 1, remote: addr(4))) == nil)
    #expect(index.resolveSameAddress(flow(bytes: 1, remote: addr(3))) == nil)
    #expect(index.resolveSameAddress(flow(bytes: 1, app: nil, remote: addr(1))) == nil)
    #expect(index.resolveSameAddress(flow(bytes: 1, remote: addr(1)))?.name == "a.example")
    // a flow never names itself
    #expect(HostnameIndex([], flows: [named]).resolveSameAddress(named) == nil)
    // an index built without flows offers nothing
    #expect(HostnameIndex([]).resolveSameAddress(flow(bytes: 1, remote: addr(1))) == nil)
}

@Test func sameAddressPicksNearestInTimeThenName() {
    func at(_ seconds: Double, _ name: String?) -> Flow {
        var f = flow(bytes: 1, name: name, remote: addr(1))
        f.firstSeen = t0.addingTimeInterval(seconds)
        return f
    }
    let target = at(10, nil)
    // 4 s before, 5 s after: the earlier one is nearer
    #expect(HostnameIndex([], flows: [at(6, "early.example"), at(15, "late.example")]).resolveSameAddress(target)?.name == "early.example")
    // equal distance: the smaller name
    #expect(HostnameIndex([], flows: [at(5, "b.example"), at(15, "a.example")]).resolveSameAddress(target)?.name == "a.example")
}

@Test func dnsBeatsSameAddressAndSniBeatsBoth() {
    let flows = [flow(bytes: 100, name: "s.example", remote: addr(1)), flow(bytes: 50, remote: addr(1))]
    let index = HostnameIndex([answer("d.example", addr(1))], flows: flows)
    #expect(index.resolve(flows[0])?.source == .sni)
    #expect(index.resolve(flows[1])?.source == .dns && index.resolve(flows[1])?.name == "d.example")
}

@Test func sameAddressPrecisionCountsAgreement() {
    // two flows to one address with different names (600 and 400 bytes), two with the same name (100 each)
    let flows = [
        flow(bytes: 600, name: "a.test", remote: addr(1)), flow(bytes: 400, name: "b.test", remote: addr(1)),
        flow(bytes: 100, name: "c.test", remote: addr(2)), flow(bytes: 100, name: "c.test", remote: addr(2)),
        flow(bytes: 300, name: "d.test", remote: addr(3)),  // alone: no hint, not counted
    ]
    let r = build(flows)
    #expect(r.hostnames.sameAddressPrecision == Ratio(numerator: 200, denominator: 1200))
    #expect(r.metrics["sameAddressPrecision"] != nil)
    #expect(build([flow(bytes: 20_000, name: "a.example", remote: addr(1))]).metrics["sameAddressPrecision"] == nil)
}

@Test func sameAddressIsInformationalInBands() {
    let flows = [
        flow(bytes: 20_000, name: "a.example", remote: addr(1)), flow(bytes: 20_000, name: "b.example", remote: addr(1)),
        flow(bytes: 20_000, remote: addr(1)),
    ]
    let r = build(flows)
    #expect(r.metrics["sameAddressShare"] == Ratio(numerator: 20_000, denominator: 60_000))
    let bands = Bands.make(from: r, scenario: "x", baselineLabel: "t")
    #expect(bands.metrics["sameAddressShare"]?.informational == true)
    #expect(bands.metrics["sameAddressPrecision"]?.informational == true)
}

@Test func dnsPrecisionDetectsDisagreement() {
    // sni a.test but dns says b.test (400 bytes); sni and dns agree on c.test (600 bytes)
    let flows = [
        flow(bytes: 400, name: "a.test", remote: addr(1)),
        flow(bytes: 600, name: "c.test", remote: addr(2)),
    ]
    let r = build(flows, domains: [answer("b.test", addr(1)), answer("c.test", addr(2))])
    #expect(r.hostnames.dnsPrecision == Ratio(numerator: 600, denominator: 1000))
    // the sni name is what is shown, so both flows are sniShare
    #expect(r.hostnames.sniShare == Ratio(numerator: 1000, denominator: 1000))
}

@Test func dnsPrecisionIgnoresFlowsWithoutBothNames() {
    let flows = [
        flow(bytes: 100, name: "a.test", remote: addr(1)),  // sni, no dns answer
        flow(bytes: 200, remote: addr(2)),  // dns only
        flow(bytes: 300, remote: addr(3)),  // neither
        flow(bytes: 400, name: "x.test", remote: addr(4), ech: true),  // ech: the sni is the outer name
        flow(bytes: 500, port: 80, name: "d.test", remote: addr(5)),  // not 443
        flow(bytes: 600, app: "locationd", name: "e.test", remote: addr(6)),  // not app traffic
    ]
    let dns = [
        answer("b.test", addr(2)), answer("x.test", addr(4)), answer("d.test", addr(5)), answer("e.test", addr(6)),
    ]
    let r = build(flows, domains: dns)
    #expect(r.hostnames.dnsPrecision == Ratio(numerator: 0, denominator: 0))
    #expect(r.hostnames.dnsPrecision.value == nil)
}

@Test func topUnnamedOnlyInDetail() throws {
    // 13 unnamed flows (sizes 10...130), one named; the top ten are 130 down to 40
    var flows = (1...13).map { flow(bytes: $0 * 10, remote: addr(UInt32($0))) }
    flows.append(flow(bytes: 999, name: "a.example", remote: addr(50)))
    // two flows with the same size: the order falls back to the flow id
    flows.append(flow(bytes: 130, remote: addr(51), udp: true))
    let plain = try build(flows).json()
    #expect(!plain.contains("topUnnamed"))
    #expect(build(flows).detail == nil)
    let top = try #require(build(flows, detail: true).detail?.topUnnamed)
    #expect(top.count == 10)
    #expect(top.map(\.ipBytes) == [130, 130, 120, 110, 100, 90, 80, 70, 60, 50])
    #expect(Set(top.prefix(2).map(\.transport)) == ["tcp", "udp"])
    #expect(top.allSatisfy { $0.port == 443 && $0.category == "app" && $0.process == "TikTok" })
    #expect(top.first { $0.transport == "udp" }?.reason == "noHandshakeUDP")
    let json = try build(flows, detail: true).json()
    #expect(json.contains("topUnnamed") && !json.contains("192.0.2"))
    // the same input in any order gives the same list
    #expect(try build(flows.shuffled(), detail: true).detail?.topUnnamed.map(\.ipBytes) == top.map(\.ipBytes))
}

@Test func unnamedReasonIsSharedAndFirstMatch() {
    let index = HostnameIndex([answer("a.example", addr(1))])
    #expect(index.unnamedReason(for: flow(bytes: 1, remote: addr(1))) == nil)
    #expect(index.unnamedReason(for: flow(bytes: 1, remote: addr(1), ech: true)) == .echHidden)
    #expect(index.unnamedReason(for: flow(bytes: 1, remote: addr(2), midstream: true)) == .startedBeforeCapture)
    #expect(index.unnamedReason(for: flow(bytes: 1, remote: addr(2), udp: true)) == .noHandshakeUDP)
    #expect(index.unnamedReason(for: flow(bytes: 1, remote: addr(2))) == .noDNSMatch)
}

@Test func unnamedReasonMatchesReport() {
    let domains = [answer("a.example", addr(1))]
    let index = HostnameIndex(domains)
    let flows = [
        flow(bytes: 1_000, remote: addr(1)),
        flow(bytes: 2_000, remote: addr(1), ech: true),
        flow(bytes: 3_000, remote: addr(2), midstream: true),
        flow(bytes: 4_000, remote: addr(2), udp: true),
        flow(bytes: 5_000, remote: addr(2)),
        flow(bytes: 6_000, remote: addr(3), midstream: true),
    ]
    let r = build(flows, domains: domains)
    for reason in UnnamedReason.allCases {
        let expected = flows.filter { index.unnamedReason(for: $0) == reason }.reduce(0) { $0 + $1.ipBytesIn }
        #expect(r.metrics["unnamedShare.\(reason.rawValue)"]?.numerator == expected)
    }
    #expect(r.metrics["unnamedShare.startedBeforeCapture"]?.numerator == 9_000)
}

@Test func hostnameMetricsReachBandsAsInformational() {
    let r = build([flow(bytes: 20_000, name: "a.example", remote: addr(1))])
    #expect(r.metrics["hostnameCoverage"] == Ratio(numerator: 20_000, denominator: 20_000))
    #expect(r.metrics["hintShare"] == Ratio(numerator: 0, denominator: 20_000))
    #expect(Bands.make(from: r, scenario: "x", baselineLabel: "t").metrics["hintShare"]?.informational == true)
    #expect(r.metrics["unnamedShare.echHidden"] != nil)
    #expect(r.metrics["dnsPrecision"] == nil)
    let bands = Bands.make(from: r, scenario: "x", baselineLabel: "t")
    #expect(bands.metrics["hostnameCoverage"]?.informational == true)
    #expect(bands.metrics["hostnameCoverageSniOnly"]?.informational == false)
    #expect(Ratchet.check(report: r, bands: bands).isEmpty)
}
