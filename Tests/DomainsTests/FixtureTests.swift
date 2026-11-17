import Flows
import Foundation
import PCAPNG
import PacketDecoder
import TestSupport
import Testing
@testable import Domains

private struct DomainCounts {
    var dnsObservations = 0
    var dnsHostnames = Set<String>()
    var sniNames = 0
    var tlsGaveUp = 0
    var quicGaveUp = 0
}

private func runDomains(_ url: URL) async throws -> DomainCounts {
    var decoder = PacketDecoder()
    var extractor = DomainExtractor()
    var counts = DomainCounts()
    for try await event in FilePacketSource(url: url).events() {
        guard case .packet(let raw) = event, case .success(let decoded) = decoder.decode(raw) else { continue }
        for o in extractor.observe(decoded) {
            switch o.source {
            case .dns:
                counts.dnsObservations += 1
                counts.dnsHostnames.insert(o.hostname)
            case .sni:
                counts.sniNames += 1
            }
        }
    }
    counts.tlsGaveUp = extractor.tlsGaveUp
    counts.quicGaveUp = extractor.quicGaveUp
    return counts
}

@Test(arguments: Fixtures.all)
func fixtureDomains(_ name: String) async throws {
    guard let url = Fixtures.url(name) else { return }
    let c = try await runDomains(url)
    print(
        "domains \(name): dns=\(c.dnsObservations) distinctDNSHostnames=\(c.dnsHostnames.count) "
            + "sni=\(c.sniNames) tlsGaveUp=\(c.tlsGaveUp) quicGaveUp=\(c.quicGaveUp)")
    if name == "watch-clean-test.pcap" {
        #expect(c.dnsHostnames.contains { $0.contains("tiktokv.us") })
    }
}
