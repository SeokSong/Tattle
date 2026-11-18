import Domains
import Flows
import Foundation
import PCAPNG
import PacketDecoder
import Testing

@testable import Attribution

private let t0 = Date(timeIntervalSince1970: 1_763_000_000)
private let v4 = IPAddress.v4(0xC000_0201)  // 192.0.2.1
private let v4b = IPAddress.v4(0xC633_6401)  // 198.51.100.1
private let v6 = IPAddress.v6(hi: 0x2001_0DB8_0000_0000, lo: 1)

private func flowKey(_ remote: IPAddress, port: UInt16 = 50000) -> FlowKey {
    FlowKey(
        transport: .tcp, localAddress: .v4(0xCB00_7102), localPort: port, remoteAddress: remote, remotePort: 443)
}

private func flow(_ remote: IPAddress = v4, app: String? = "Instagram", port: UInt16 = 50000) -> Flow {
    var f = Flow(key: flowKey(remote, port: port), interface: "en0", at: t0)
    if let app { f.tally[ProcessPair(app, 1, nil, nil)] = 3 }
    return f
}

private func dns(
    _ ago: TimeInterval, _ host: String, addr: IPAddress = v4, ttl: UInt32? = nil, app: String? = "Instagram"
) -> DomainObservation {
    DomainObservation(
        time: t0.addingTimeInterval(-ago), source: .dns, hostname: host, addresses: [addr], ttl: ttl,
        process: app.map { PCAPNGProcess(pid: 1, name: $0) })
}

private func resolve(_ f: Flow, _ obs: [DomainObservation]) -> ResolvedHostname? {
    HostnameIndex(obs).resolve(f)
}

@Test func sniWinsOverDns() {
    var f = flow()
    f.serverName = "a.example"
    let r = resolve(f, [dns(5, "b.example")])
    #expect(r == ResolvedHostname(name: "a.example", source: .sni, dnsAgeSeconds: nil, echPresent: false))
}

@Test func sniFromObservationAndEch() {
    let f = flow()
    let sni = DomainObservation(
        time: t0, source: .sni, hostname: "outer.example", flowKey: f.key, echPresent: true)
    let r = resolve(f, [sni, dns(5, "b.example")])
    #expect(r?.name == "outer.example" && r?.source == .sni && r?.echPresent == true)
}

@Test func dnsMatchesAddressAppAndTtl() {
    let r = resolve(flow(), [dns(10, "a.example", ttl: 60), dns(10, "other.example", addr: v4b, ttl: 60)])
    #expect(r == ResolvedHostname(name: "a.example", source: .dns, dnsAgeSeconds: 10, echPresent: false))
}

@Test func dnsTtlBoundaryInclusive() {
    #expect(resolve(flow(), [dns(60, "a.example", ttl: 60)])?.name == "a.example")
    #expect(resolve(flow(), [dns(60.001, "a.example", ttl: 60)]) == nil)
}

@Test func dnsAfterFlowStartIsIgnored() {
    #expect(resolve(flow(), [dns(-1, "late.example")]) == nil)
    #expect(resolve(flow(), [dns(0, "same.example")])?.name == "same.example")
}

@Test func dnsOtherAppIsIgnored() {
    #expect(resolve(flow(app: "Instagram"), [dns(5, "a.example", app: "TikTok")]) == nil)
}

@Test func dnsWithoutProcessMatchesAnyApp() {
    #expect(resolve(flow(app: "Instagram"), [dns(5, "a.example", app: nil)])?.name == "a.example")
    #expect(resolve(flow(app: nil), [dns(5, "a.example", app: nil)])?.name == "a.example")
    #expect(resolve(flow(app: nil), [dns(5, "a.example", app: "TikTok")]) == nil)
}

@Test func defaultTtlIs300WhenNil() {
    #expect(resolve(flow(), [dns(300, "a.example")])?.name == "a.example")
    #expect(resolve(flow(), [dns(301, "a.example")]) == nil)
}

@Test func newestAnswerWins() {
    let r = resolve(flow(), [dns(20, "old.example"), dns(5, "new.example"), dns(50, "older.example")])
    #expect(r?.name == "new.example" && r?.dnsAgeSeconds == 5)
}

@Test func olderAnswerUsedWhenNewestExpired() {
    let r = resolve(flow(), [dns(20, "long.example", ttl: 100), dns(5, "short.example", ttl: 1)])
    #expect(r?.name == "long.example")
}

@Test func tieBreaksByHostname() {
    let obs = [dns(5, "b.example"), dns(5, "a.example"), dns(5, "c.example")]
    #expect(resolve(flow(), obs)?.name == "a.example")
    #expect(resolve(flow(), obs.reversed())?.name == "a.example")
}

@Test func ipv6AddressMatches() {
    #expect(resolve(flow(v6), [dns(5, "six.example", addr: v6)])?.name == "six.example")
    #expect(resolve(flow(v6), [dns(5, "four.example", addr: v4)]) == nil)
}

@Test func resolveWithoutSniIgnoresSni() {
    var f = flow()
    f.serverName = "a.example"
    let index = HostnameIndex([dns(5, "b.example")])
    #expect(index.resolve(f)?.name == "a.example")
    #expect(index.resolveWithoutSNI(f)?.name == "b.example")
    #expect(index.resolveWithoutSNI(f)?.source == .dns)
}

@Test func displayNameNormalisedAppMatch() {
    let r = resolve(flow(app: "appstorecomponen"), [dns(5, "a.example", app: "appstorecomponen")])
    #expect(r?.name == "a.example")
}

// MARK: agreement with supportingDomains

private struct LCG {
    var state: UInt64
    mutating func next(_ n: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(n))
    }
}

@Test func indexMatchesSupportingDomains() {
    var rng = LCG(state: 42)
    let addrs: [IPAddress] = [v4, v4b, v6, .v4(0xCB00_7101)]
    let apps: [String?] = ["Instagram", "TikTok", nil, "locationd"]
    let hosts = (0..<12).map { "h\($0).example" }
    var obs: [DomainObservation] = []
    for _ in 0..<200 {
        obs.append(
            dns(
                Double(rng.next(700) - 100), hosts[rng.next(hosts.count)], addr: addrs[rng.next(addrs.count)],
                ttl: [nil, 30, 120, 600][rng.next(4)], app: apps[rng.next(apps.count)]))
    }
    var flows: [Flow] = []
    for i in 0..<200 {
        flows.append(flow(addrs[rng.next(addrs.count)], app: apps[rng.next(apps.count)], port: UInt16(40000 + i)))
    }
    for f in flows where rng.next(5) == 0 {
        obs.append(DomainObservation(time: t0, source: .sni, hostname: "sni.example", flowKey: f.key))
    }
    let index = HostnameIndex(obs)
    var named = 0
    for f in flows {
        let expected = Attributor.supportingDomains(for: f, in: obs).first
        let got = index.resolve(f)
        #expect(got?.name == expected?.hostname)
        #expect(got?.source.rawValue == expected?.source.rawValue)
        if got != nil { named += 1 }
    }
    #expect(named > 20)
}

@Test func largeIndexIsFast() {
    var rng = LCG(state: 7)
    var obs: [DomainObservation] = []
    for i in 0..<5000 {
        obs.append(dns(Double(rng.next(300)), "h\(i).example", addr: .v4(UInt32(0xC000_0200 + rng.next(2000)))))
    }
    var flows: [Flow] = []
    for i in 0..<10_000 {
        flows.append(flow(.v4(UInt32(0xC000_0200 + rng.next(2000))), port: UInt16(1000 + i % 60000)))
    }
    let start = Date()
    let index = HostnameIndex(obs)
    var named = 0
    for f in flows where index.resolve(f) != nil { named += 1 }
    #expect(named > 0)
    #expect(Date().timeIntervalSince(start) < 5)
}
