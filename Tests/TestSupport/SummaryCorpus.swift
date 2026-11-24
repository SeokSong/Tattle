import Domains
import Flows
import Foundation
import PacketDecoder

// a hand-built scenario for the capture summary (problem 3.1). flows and observations are built directly,
// not from packets. names are fictional (.test, plus someone.pages.dev for a hosted site), public addresses
// are 192.0.2.0/24, and the curated rows, tracker rows and app rows are given here as text, so the answers
// never change when the bundled lists grow. every number in `SummaryCorpus.Expected` is worked out by hand.
//
// apps (from the app table text below):
//   Zappy  (test.zappy.app, company Zappy Inc): process names ZappyVideoPlayerApp (the kernel cuts it to
//          ZappyVideoPlayer) and ZappyHelper, so both merge into one entry
//   Quill  (test.quill.app, company Quill Corp): process name Quill
//   Bobber is not in the table: its own entry, no company
//
// flows, all tcp to port 443 unless noted, bytes are ip bytes in + out:
//   Z1  ZappyVideoPlayer  sni a.ads.test           1000  AdCo Holdings, advertising (brand AdCo)
//   Z2  ZappyHelper       sni b.adsalt.test         500  AdCo Holdings, analytics (brand AdCo Two)
//   Z3  ZappyVideoPlayer  sni www.video.test       4000  Zappy Inc, the app's own company; lastSeen t0+120
//   Z4  nsurlsessiond for ZappyHelper, sni cdn.test 2000 CdnCo, content delivery (helper traffic)
//   Z5  ZappyVideoPlayer  sni unknown-z.test        300  not identified
//   Z6  ZappyVideoPlayer  sni noco-ads.test         200  not identified; AdGuard advertising, no company
//   Z7  ZappyHelper       sni x.noco-ads2.test      100  not identified; AdGuard advertising, no company
//   Z8  ZappyVideoPlayer  sni outer.ads.test, ech   700  unseen: echHidden
//   Z9  ZappyVideoPlayer  no name, started midstream 600 unseen: startedBeforeCapture
//   Z10 ZappyVideoPlayer  no sni, dns answer metrics.test  400  hint only: possible MetricCo
//   Z11 ZappyVideoPlayer  tcp port 80, no name     5000  not port 443: outside the summary
//   Q1  Quill             sni ads.test              800  AdCo Holdings, advertising
//   Q2  Quill             udp, no name              300  unseen: noHandshakeUDP
//   Q3  Quill             sni noco-stats.test       150  not identified; AdGuard analytics, no company
//   Q4  Quill             no name                   250  unseen: noDNSMatch
//   B1  Bobber            sni cdn.test              900  CdnCo (relation unknown: no app company)
//   B2  Bobber            sni someone.pages.dev     100  not identified (a site on a hosting platform)
//   S1  apsd              sni push.apple-sys.test  1200  Apple, the system's own company
//   S2  nsurlsessiond     sni ads.test              300  AdCo Holdings, advertising
//   S3  trustd            no name, started midstream 100 unseen: startedBeforeCapture (system)
//   N1  no process info   sni cdn.test              700  the no-process line
//   X1  lockdownd                                   400  excluded: deviceLink
//   X2  no process info, remote 192.168.1.20        500  excluded: localNetwork
public enum SummaryCorpus {
    public static let curatedTSV = [
        "domain\tcompany\tparent\tcategory\tnote",
        "ads.test\tAdCo\tAdCo Holdings\tadvertising\tfictional",
        "adsalt.test\tAdCo Two\tAdCo Holdings\tanalytics\tfictional",
        "video.test\tZappy Video\tZappy Inc\tonlineService\tfictional",
        "cdn.test\tCdnCo\tCdnCo\tcontentDelivery\tfictional",
        "apple-sys.test\tApple Push\tApple\tappleSystem\tfictional",
        "metrics.test\tMetricCo\tMetricCo\tanalytics\tfictional",
    ].joined(separator: "\n") + "\n"

    /// AdGuard-style rows: three domains with a category and no company. sorted by domain
    public static let trackerTSV = [
        "domain\tcompany\tadguardCategory",
        "noco-ads.test\t\tads",
        "noco-ads2.test\t\tads",
        "noco-stats.test\t\tstats",
    ].joined(separator: "\n") + "\n"
    public static let trackerCategoriesTSV =
        "adguardCategory\tcategory\tnote\nads\tadvertising\tn\nstats\tanalytics\tn\nmisc\tunclassified\tn\n"
    public static let trackerAliasesTSV = "adguardCompany\tparent\tnote\n"

    public static let appsTSV = [
        "bundleId\tdisplayName\tprocessName\tcompany\tnote",
        "test.zappy.app\tZappy\tZappyVideoPlayerApp|ZappyHelper\tZappy Inc\tfictional",
        "test.quill.app\tQuill\tQuill\tQuill Corp\tfictional",
    ].joined(separator: "\n") + "\n"

    /// the hand-worked answers. `bytes` are ip bytes in + out; only port 443 traffic is in the summary
    public enum Expected {
        public static let port443Bytes = 15_500  // every flow but Z11
        public static let appTrafficPort443Bytes = 12_300  // Zappy 9800 + Quill 1500 + Bobber 1000

        public enum Zappy {
            public static let key = "test.zappy.app"
            public static let name = "Zappy"
            public static let company = "Zappy Inc"
            public static let totalBytes = 9_800  // Z1 to Z10
            public static let identified = (connections: 4, bytes: 7_500)  // Z1 to Z4
            public static let notIdentified = (connections: 3, bytes: 600)  // Z5, Z6, Z7
            public static let hinted = (connections: 1, bytes: 400)  // Z10
            public static let echHidden = (connections: 1, bytes: 700)  // Z8
            public static let startedBeforeCapture = (connections: 1, bytes: 600)  // Z9
            public static let namedCompanies = 3  // Zappy Inc, AdCo Holdings, CdnCo
            public static let adTrackCompanies = 1  // AdCo Holdings
            public static let possibleCompanies = ["MetricCo"]
            public static let unnamedAdvertising = 2  // noco-ads.test, noco-ads2.test
            /// own company first, then advertising or tracking, then the rest (OD12)
            public static let companyOrder = ["Zappy Inc", "AdCo Holdings", "CdnCo"]
            public static let adCoBrands = ["AdCo", "AdCo Two"]
            public static let adCoConnections = 2
            public static let adCoBytes = 1_500
            public static let windowSeconds: TimeInterval = 120  // Z3 lastSeen is t0 + 120
        }

        public enum Quill {
            public static let key = "test.quill.app"
            public static let company = "Quill Corp"
            public static let totalBytes = 1_500
            public static let identified = (connections: 1, bytes: 800)
            public static let notIdentified = (connections: 1, bytes: 150)
            public static let noHandshakeUDP = (connections: 1, bytes: 300)
            public static let noDNSMatch = (connections: 1, bytes: 250)
            public static let namedCompanies = 1
            public static let adTrackCompanies = 1
            public static let unnamedAnalytics = 1  // noco-stats.test
        }

        public enum Bobber {
            public static let name = "Bobber"
            public static let totalBytes = 1_000
            public static let identified = (connections: 1, bytes: 900)
            public static let notIdentified = (connections: 1, bytes: 100)
            public static let namedCompanies = 1  // CdnCo
            public static let adTrackCompanies = 0
        }

        public enum System {
            public static let name = "iOS system"
            public static let company = "Apple"
            public static let totalBytes = 1_600
            public static let identified = (connections: 2, bytes: 1_500)
            public static let startedBeforeCapture = (connections: 1, bytes: 100)  // S3, not in the quality report's app share
            public static let namedCompanies = 2  // Apple, AdCo Holdings
            public static let adTrackCompanies = 1
            public static let companyOrder = ["Apple", "AdCo Holdings"]
        }

        public static let noProcess = (connections: 1, bytes: 700)  // N1
        public static let deviceLink = (connections: 1, bytes: 400)  // X1
        public static let localNetwork = (connections: 1, bytes: 500)  // X2

        /// the quality report's unnamed bytes for app traffic to port 443 (system traffic is not in it)
        public static let reportUnnamedBytes: [String: Int] = [
            "echHidden": 700, "startedBeforeCapture": 600, "noHandshakeUDP": 300, "noDNSMatch": 250,
        ]
    }

    public static let t0 = Date(timeIntervalSince1970: 1_763_000_000)
    private static let local = IPAddress.v4(0xCB00_7102)
    /// Z10's remote address, the one the dns answer for metrics.test points at
    private static let hintAddress = IPAddress.v4(0xC000_0200 + 110)

    private static func flow(
        _ n: UInt32, process: ProcessPair?, name: String? = nil, ech: Bool = false, midstream: Bool = false,
        transport: Transport = .tcp, port: UInt16 = 443, remote: IPAddress? = nil, bytes: Int,
        lastSeen: TimeInterval = 0
    ) -> Flow {
        let key = FlowKey(
            transport: transport, localAddress: local, localPort: UInt16(50000 + n),
            remoteAddress: remote ?? .v4(0xC000_0200 + n), remotePort: port)
        var f = Flow(key: key, interface: "en0", at: t0)
        f.lastSeen = t0.addingTimeInterval(lastSeen)
        f.serverName = name
        f.echSeen = ech
        f.startedMidstream = midstream
        // split so both directions are used; only the sum matters
        f.ipBytesIn = bytes - bytes / 4
        f.ipBytesOut = bytes / 4
        if let process { f.tally[process] = 3 }
        return f
    }

    private static let zappy = ProcessPair("ZappyVideoPlayer", 101, nil, nil)
    private static let zappyHelper = ProcessPair("ZappyHelper", 102, nil, nil)

    public static func flows() -> [Flow] {
        [
            flow(1, process: zappy, name: "a.ads.test", bytes: 1000),
            flow(2, process: zappyHelper, name: "b.adsalt.test", bytes: 500),
            flow(3, process: zappy, name: "www.video.test", bytes: 4000, lastSeen: 120),
            flow(4, process: ProcessPair("nsurlsessiond", 30, "ZappyHelper", 102), name: "cdn.test", bytes: 2000),
            flow(5, process: zappy, name: "unknown-z.test", bytes: 300),
            flow(6, process: zappy, name: "noco-ads.test", bytes: 200),
            flow(7, process: zappyHelper, name: "x.noco-ads2.test", bytes: 100),
            flow(8, process: zappy, name: "outer.ads.test", ech: true, bytes: 700),
            flow(9, process: zappy, midstream: true, bytes: 600),
            flow(10, process: zappy, remote: hintAddress, bytes: 400),
            flow(11, process: zappy, port: 80, bytes: 5000),
            flow(21, process: ProcessPair("Quill", 201, nil, nil), name: "ads.test", bytes: 800),
            flow(22, process: ProcessPair("Quill", 201, nil, nil), transport: .udp, bytes: 300),
            flow(23, process: ProcessPair("Quill", 201, nil, nil), name: "noco-stats.test", bytes: 150),
            flow(24, process: ProcessPair("Quill", 201, nil, nil), bytes: 250),
            flow(31, process: ProcessPair("Bobber", 301, nil, nil), name: "cdn.test", bytes: 900),
            flow(32, process: ProcessPair("Bobber", 301, nil, nil), name: "someone.pages.dev", bytes: 100),
            flow(41, process: ProcessPair("apsd", 401, nil, nil), name: "push.apple-sys.test", bytes: 1200),
            flow(42, process: ProcessPair("nsurlsessiond", 30, nil, nil), name: "ads.test", bytes: 300),
            flow(43, process: ProcessPair("trustd", 402, nil, nil), midstream: true, bytes: 100),
            flow(51, process: nil, name: "cdn.test", bytes: 700),
            flow(61, process: ProcessPair("lockdownd", 501, nil, nil), bytes: 400),
            flow(62, process: nil, remote: .v4(0xC0A8_0114), bytes: 500),
        ]
    }

    /// the dns answer behind Z10
    public static func observations() -> [DomainObservation] {
        [DomainObservation(time: t0.addingTimeInterval(-5), source: .dns, hostname: "metrics.test", addresses: [hintAddress])]
    }
}
