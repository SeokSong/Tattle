import Attribution
import Domains
import Flows
import Foundation
import PacketDecoder
import Testing
import Companies
import Summary

private let t0 = Date(timeIntervalSince1970: 1_763_000_000)
private let remote = IPAddress.v4(0xC000_0201)  // 192.0.2.1

private func flow(name: String? = nil, ech: Bool = false, port: UInt16 = 50000) -> Flow {
    let key = FlowKey(
        transport: .tcp, localAddress: .v4(0xCB00_7102), localPort: port, remoteAddress: remote, remotePort: 443)
    var f = Flow(key: key, interface: "en0", at: t0)
    f.serverName = name
    f.echSeen = ech
    return f
}

private func dnsAnswer(_ host: String) -> DomainObservation {
    DomainObservation(time: t0.addingTimeInterval(-5), source: .dns, hostname: host, addresses: [remote])
}

private func label(_ f: Flow, _ observations: [DomainObservation] = []) -> FlowLabel? {
    var cache = LabelCache()
    return FlowLabels.label(for: f, index: HostnameIndex(observations, flows: [f]), cache: &cache)
}

@Test func sniNameIsConfirmed() {
    let result = label(flow(name: "securepubads.g.doubleclick.net"))
    #expect(result?.evidence == .captureName)
    #expect(result?.isPossible == false)
    #expect(result?.label.category == .advertising)
}

@Test func dnsNameIsPossibleNotCounted() {
    let result = label(flow(), [dnsAnswer("securepubads.g.doubleclick.net")])
    #expect(result?.evidence == .captureHint)
    #expect(result?.isPossible == true)
}

@Test func unnamedFlowKeepsItsReason() {
    let f = flow()
    #expect(label(f) == nil)
    #expect(HostnameIndex([], flows: [f]).unnamedReason(for: f) == .noDNSMatch)
}

@Test func echHiddenNeverLabelled() {
    #expect(label(flow(name: "securepubads.g.doubleclick.net", ech: true)) == nil)
    // the hello's own observation can carry the ech flag too
    let f = flow()
    let sni = DomainObservation(
        time: t0, source: .sni, hostname: "securepubads.g.doubleclick.net", flowKey: f.key, echPresent: true)
    #expect(label(f, [sni]) == nil)
}

@Test func unmatchedNameStaysUnknown() {
    let result = label(flow(name: "host.invalid"))
    #expect(result?.label.isMatched == false)
    #expect(result?.label.company == nil)
    #expect(result?.label.category == .unclassified)
}

@Test func cacheComputesOncePerHostname() {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    let counter = Counter()
    let real = CompanyClassifier()
    var cache = LabelCache(classify: { counter.bump(); return real.classify(hostname: $0) })
    let flows = [flow(name: "a.doubleclick.net", port: 1), flow(name: "a.doubleclick.net", port: 2), flow(name: "b.example.invalid", port: 3)]
    let index = HostnameIndex([], flows: flows)
    for f in flows { _ = FlowLabels.label(for: f, index: index, cache: &cache) }
    for f in flows { _ = FlowLabels.label(for: f, index: index, cache: &cache) }
    #expect(counter.value == 2)
    #expect(cache.classifications == 2)
}

@Test func labelCacheIgnoresCaseAndTrailingDot() {
    var cache = LabelCache()
    let a = cache.label(for: "Securepubads.G.DoubleClick.net")
    let b = cache.label(for: "securepubads.g.doubleclick.net.")
    let c = cache.label(for: "securepubads.g.doubleclick.net")
    #expect(cache.classifications == 1)
    #expect(a == b && b == c)
}

@Test func hostedSiteLabelCarriesThePlatform() {
    let result = label(flow(name: "someone.pages.dev"))
    #expect(result?.label.isMatched == false)
    #expect(result?.label.hostingPlatform != nil)
}

@Test func flowLabelRelationFollowsTheAppCompany() {
    let f = flow(name: "securepubads.g.doubleclick.net")
    let index = HostnameIndex([], flows: [f])
    var cache = LabelCache()
    // no app company: unknown, as before
    #expect(FlowLabels.label(for: f, index: index, cache: &cache)?.label.relation == .unknown)
    #expect(FlowLabels.label(for: f, index: index, cache: &cache, appCompany: "Alphabet")?.label.relation == .sameCompanyAsApp)
    #expect(FlowLabels.label(for: f, index: index, cache: &cache, appCompany: "Netflix")?.label.relation == .other)
    // the cache keeps the plain label: one classification for all three calls
    #expect(cache.classifications == 1)
}
