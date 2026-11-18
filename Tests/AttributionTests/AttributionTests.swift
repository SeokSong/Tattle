import Domains
@testable import Flows
import Foundation
@testable import PCAPNG
import PacketDecoder
import Testing

@testable import Attribution

private func tally(_ rows: [(ProcessPair, Int)]) -> [ProcessPair: Int] {
    Dictionary(uniqueKeysWithValues: rows)
}

@Test func appState() {
    let r = Attributor.attribute(tally([(ProcessPair("YouTube", 18940, nil, nil), 100), (.none, 5)]))
    #expect(r.primary == .app(name: "YouTube", pids: [18940]))
    #expect(r.packetsForPrimary == 100 && r.packetsTotal == 105 && !r.mixed)
}

@Test func twoPidsOneApp() {
    let r = Attributor.attribute(tally([
        (ProcessPair("Instagram", 18957, nil, nil), 30), (ProcessPair("Instagram", 18958, nil, nil), 20),
    ]))
    #expect(r.primary == .app(name: "Instagram", pids: [18957, 18958]))
    #expect(r.packetsForPrimary == 50 && !r.mixed)
}

@Test func onBehalfOf() {
    let r = Attributor.attribute(tally([(ProcessPair("mDNSResponder", 212, "TikTok", 19475), 10)]))
    #expect(r.primary == .onBehalfOf(app: "TikTok", via: "mDNSResponder"))
}

@Test func systemState() {
    let r = Attributor.attribute(tally([(ProcessPair("locationd", 50, nil, nil), 10), (.none, 1)]))
    #expect(r.primary == .system(name: "locationd"))
    #expect(!r.mixed)
}

@Test func mixed() {
    let r = Attributor.attribute(tally([
        (ProcessPair("YouTube", 1, nil, nil), 100), (ProcessPair("TikTok", 2, nil, nil), 5),
        (ProcessPair("locationd", 3, nil, nil), 50),
    ]))
    #expect(r.primary == .app(name: "YouTube", pids: [1]))
    #expect(r.mixed)
    #expect(r.packetsTotal == 155)
}

@Test func onlyNoneIsUnknown() {
    #expect(Attributor.attribute([.none: 7]).primary == .unknown)
    #expect(Attributor.attribute([:]).primary == .unknown)
}

@Test func systemListLookup() {
    #expect(Attributor.isSystemProcess("nsurlsessiond"))
    #expect(!Attributor.isSystemProcess("YouTube"))
}

@Test func pure() {
    let t = tally([
        (ProcessPair("A", 1, nil, nil), 5), (ProcessPair("B", 2, nil, nil), 5),
        (ProcessPair("mDNSResponder", 3, "A", 1), 2),
    ])
    let first = Attributor.attribute(t)
    for _ in 0..<20 {
        let again = Attributor.attribute(t)
        #expect(again.primary == first.primary && again.packetsForPrimary == first.packetsForPrimary)
        #expect(again.mixed == first.mixed)
    }
}

// MARK: process names

@Test func cutNameStillMatchesSystemProcess() {
    #expect(Attributor.isSystemProcess("networkservicepr"))
    #expect(Attributor.isSystemProcess("networkserviceproxy"))
}

@Test func everySystemNameMatchesInCutForm() {
    for name in systemProcessNames {
        #expect(Attributor.isSystemProcess(name), "\(name) as written")
        #expect(Attributor.isSystemProcess(ProcessNames.cut(name)), "\(name) cut")
        #expect(ProcessNames.matches(ProcessNames.cut(name), full: name))
    }
}

@Test func unknownNameIsNotSystem() {
    #expect(!Attributor.isSystemProcess("TikTok"))
    #expect(!Attributor.isSystemProcess("apsd2"))
    #expect(!ProcessNames.matches("networkservic", full: "networkserviceproxy"))
}

@Test func displayNameMapsAndFallsBack() {
    #expect(ProcessNames.displayName("appstorecomponen") == "App Store (component)")
    #expect(ProcessNames.displayName("TikTok") == "TikTok")
}

@Test func attributeTreatsCutNameAsSystem() {
    let r = Attributor.attribute(tally([(ProcessPair("networkservicepr", 9, nil, nil), 4)]))
    #expect(r.primary == .system(name: "networkservicepr"))
}

// MARK: supportingDomains

private let t0 = Date(timeIntervalSince1970: 1_763_000_000)
private let remote = IPAddress.v4(0x5DB8_D822)
private let other = IPAddress.v4(0x0101_0101)

private func makeFlow(app: String = "TikTok") -> Flow {
    let key = FlowKey(
        transport: .tcp, localAddress: .v4(0x0A00_0002), localPort: 50000, remoteAddress: remote, remotePort: 443)
    var f = Flow(key: key, interface: "en0", at: t0)
    f.tally[ProcessPair(app, 1, nil, nil)] = 3
    return f
}

private func dns(
    _ ago: TimeInterval, host: String, addrs: [IPAddress] = [remote], ttl: UInt32? = nil, app: String? = "TikTok"
) -> DomainObservation {
    DomainObservation(
        time: t0.addingTimeInterval(-ago), source: .dns, hostname: host, addresses: addrs, ttl: ttl,
        process: app.map { PCAPNGProcess(pid: 1, name: $0) })
}

@Test func supportingDomainsFilters() {
    let flow = makeFlow()
    let sni = DomainObservation(time: t0, source: .sni, hostname: "sni.example", flowKey: flow.key)
    let otherSNI = DomainObservation(
        time: t0, source: .sni, hostname: "x.example",
        flowKey: FlowKey(transport: .tcp, localAddress: .v4(1), localPort: 1, remoteAddress: remote, remotePort: 1))
    let domains = [
        dns(10, host: "old.example"),
        dns(5, host: "new.example"),
        dns(5, host: "wrongaddr.example", addrs: [other]),
        dns(5, host: "wrongapp.example", app: "YouTube"),
        dns(5, host: "noapp.example", app: nil),
        dns(-5, host: "future.example"),
        dns(400, host: "stale.example"),
        dns(400, host: "longttl.example", ttl: 600),
        dns(100, host: "shortttl.example", ttl: 50),
        otherSNI, sni,
    ]
    let hosts = Attributor.supportingDomains(for: flow, in: domains).map(\.hostname)
    #expect(hosts == ["sni.example", "new.example", "noapp.example", "old.example", "longttl.example"])
}
