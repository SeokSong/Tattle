import Domains
import Flows
import Foundation
import PacketDecoder

// a hand-built company scenario for coverage (problem 1.4). flows and observations are built directly,
// not from packets, so the answers do not depend on the pipeline. names are fictional (.test), addresses
// are 192.0.2.0/24, and the curated rows are given here as text, so the answers do not change when the
// bundled list grows. every number below is worked out by hand in `CompanyCorpus.Expected`.
//
// flows (all tcp to port 443 unless noted), by ip bytes in + out:
//   C1 a.ads.test        sni      3000 + 1000 = 4000   advertising, parent AdCo Inc
//   C2 b.ads.test        sni      800 + 200   = 1000   same registrable domain as C1
//   C3 cdn.test          sni      1500 + 500  = 2000   content delivery, parent CdnCo
//   C4 www.social.test   sni      300 + 200   = 500    social, parent SocialParent (domain row)
//   C5 track.social.test sni      300 + 200   = 500    analytics, parent SocialParent (hostname row)
//   C6 unknown-one.test  sni      1000 + 500  = 1500   not in the list
//   C7 unknown-two.test  sni      700 + 300   = 1000   not in the list
//   C8 outer.ads.test    sni, ech 1500 + 500  = 2000   the outer name of an ech flow: never named
//   C9 no name at all             500 + 300   = 800
//   C10 no sni; a dns answer names metrics.test   400 + 300 = 700   a hint: never counted, parent MetricCo
//   C11 a.ads.test, tcp port 80   3000 + 2000 = 5000   not port 443: outside every metric
public enum CompanyCorpus {
    public static let curatedTSV = [
        "domain\tcompany\tparent\tcategory\tnote",
        "ads.test\tAdCo\tAdCo Inc\tadvertising\tfictional",
        "cdn.test\tCdnCo\tCdnCo\tcontentDelivery\tfictional",
        "social.test\tSocialCo\tSocialParent\tsocial\tfictional",
        "track.social.test\tSocialTrack\tSocialParent\tanalytics\tfictional",
        "metrics.test\tMetricCo\tMetricCo\tanalytics\tfictional",
    ].joined(separator: "\n") + "\n"

    public struct Expected: Sendable {
        public init() {}
        public let allBytes = 14_000  // C1 to C10
        public let namedBytes = 10_500  // C1 to C7, confirmed by sni
        public let matchedBytes = 8_000  // C1 to C5
        public let domainCount = 5  // ads, cdn, social, unknown-one, unknown-two
        public let identifiedDomains = 3  // ads, cdn, social
        public let namedCompanies = 3  // AdCo Inc, CdnCo, SocialParent
        public let adTrackCompanies = 2  // AdCo Inc (advertising), SocialParent (analytics host)
        public let possibleCompanies = 1  // MetricCo, from the dns hint only
        public let unmatchedConnections = 5  // C6, C7, C8, C9, C10
        /// most bytes first
        public let unmatchedDomains: [(name: String, flows: Int, bytes: Int)] = [
            ("unknown-one.test", 1, 1500), ("unknown-two.test", 1, 1000),
        ]
    }

    private static let t0 = Date(timeIntervalSince1970: 1_763_000_000)
    private static let local = IPAddress.v4(0xCB00_7102)

    private static func flow(
        _ n: UInt32, name: String? = nil, ech: Bool = false, port: UInt16 = 443, bytesIn: Int, bytesOut: Int
    ) -> Flow {
        let key = FlowKey(
            transport: .tcp, localAddress: local, localPort: UInt16(50000 + n),
            remoteAddress: .v4(0xC000_0200 + n), remotePort: port)
        var f = Flow(key: key, interface: "en0", at: t0)
        f.serverName = name
        f.echSeen = ech
        f.ipBytesIn = bytesIn
        f.ipBytesOut = bytesOut
        return f
    }

    public static func flows() -> [Flow] {
        [
            flow(1, name: "a.ads.test", bytesIn: 3000, bytesOut: 1000),
            flow(2, name: "b.ads.test", bytesIn: 800, bytesOut: 200),
            flow(3, name: "cdn.test", bytesIn: 1500, bytesOut: 500),
            flow(4, name: "www.social.test", bytesIn: 300, bytesOut: 200),
            flow(5, name: "track.social.test", bytesIn: 300, bytesOut: 200),
            flow(6, name: "unknown-one.test", bytesIn: 1000, bytesOut: 500),
            flow(7, name: "unknown-two.test", bytesIn: 700, bytesOut: 300),
            flow(8, name: "outer.ads.test", ech: true, bytesIn: 1500, bytesOut: 500),
            flow(9, bytesIn: 500, bytesOut: 300),
            flow(10, bytesIn: 400, bytesOut: 300),
            flow(11, name: "a.ads.test", port: 80, bytesIn: 3000, bytesOut: 2000),
        ]
    }

    /// the dns answer behind C10
    public static func observations() -> [DomainObservation] {
        [
            DomainObservation(
                time: t0.addingTimeInterval(-5), source: .dns, hostname: "metrics.test",
                addresses: [.v4(0xC000_0200 + 10)])
        ]
    }
}
