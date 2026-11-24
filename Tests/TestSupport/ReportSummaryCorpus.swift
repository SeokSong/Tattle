import Foundation

// a hand-built App Privacy Report scenario for the report summary (problem 3.2). rows are what the store holds
// (one per import, app and domain), given as plain values so TestSupport needs no Storage or Summary import.
// names are fictional (.test, plus someone.pages.dev for a hosted site); addresses are documentation ranges.
// every number in `ReportSummaryCorpus.Expected` is worked out by hand.
//
// apps (app table text below):
//   test.zappy.app        exact row, Zappy, company Zappy Inc
//   com.apple.mobilesafari exact row, Safari, company Apple
//   com.apple.weatherx    only the com.apple. prefix row: an Apple app with no name, so it is titled by its id
//   com.example.unjoined  not in the table: its own entry titled by its id, no company
//
// rows (import, app, domain, Apple's owner, hits):
//   imp1 zappy   a.ads.test                     5   curated AdCo Holdings, advertising (brand AdCo)
//   imp1 zappy   ads.test                       3   the same parent, a second domain
//   imp1 zappy   b.adsalt.test                  2   AdCo Holdings, analytics (brand AdCo Two)
//   imp1 zappy   www.video.test                10   Zappy Inc, the app's own company
//   imp2 zappy   www.video.test                 7   a second import: hits are summed, the domain counts once
//   imp1 zappy   unlisted-o.test  Wexford Systems Corp  1   Apple's owner, aliased to Wexford; no category
//   imp1 zappy   203.0.113.9      Wexford Systems Corp  2   a bare address Apple names: identified, never shown
//   imp1 zappy   noco-ads.test                  4   not identified; AdGuard advertising, no company
//   imp1 zappy   unknown-r.test                 2   not identified
//   imp1 zappy   192.0.2.55                     6   a bare address nobody names: not identified
//   imp1 unjoined cdn.test                      3   CdnCo (relation unknown: no app company)
//   imp1 unjoined 2001:db8::1                   1   bare IPv6 address: not identified
//   imp1 unjoined someone.pages.dev             1   a site on a hosting platform: not identified
//   imp1 safari  push.apple-sys.test            4   Apple, the app's own company
//   imp1 safari  ads.test                       1   AdCo Holdings
//   imp1 weatherx push.apple-sys.test           2   Apple
//   imp1 weatherx 198.51.100.7                  1   bare address: not identified
public enum ReportSummaryCorpus {
    public struct Row: Sendable {
        public let importId: String
        public let appId: String
        public let domain: String
        public let domainOwner: String?
        public let hits: Int
        public let firstSeen: Date
        public let lastSeen: Date

        public init(importId: String, appId: String, domain: String, domainOwner: String?, hits: Int, firstSeen: Date, lastSeen: Date) {
            self.importId = importId
            self.appId = appId
            self.domain = domain
            self.domainOwner = domainOwner
            self.hits = hits
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
        }
    }

    public static let curatedTSV = [
        "domain\tcompany\tparent\tcategory\tnote",
        "ads.test\tAdCo\tAdCo Holdings\tadvertising\tfictional",
        "adsalt.test\tAdCo Two\tAdCo Holdings\tanalytics\tfictional",
        "video.test\tZappy Video\tZappy Inc\tonlineService\tfictional",
        "cdn.test\tCdnCo\tCdnCo\tcontentDelivery\tfictional",
        "apple-sys.test\tApple Push\tApple\tappleSystem\tfictional",
    ].joined(separator: "\n") + "\n"
    public static let appleOwnersTSV = "appleOwner\tkind\tparent\tnote\nWexford Systems Corp\talias\tWexford\tfictional\n"
    public static let trackerTSV = "domain\tcompany\tadguardCategory\nnoco-ads.test\t\tads\n"
    public static let trackerCategoriesTSV =
        "adguardCategory\tcategory\tnote\nads\tadvertising\tn\nstats\tanalytics\tn\nmisc\tunclassified\tn\n"
    public static let trackerAliasesTSV = "adguardCompany\tparent\tnote\n"
    public static let appsTSV = [
        "bundleId\tdisplayName\tprocessName\tcompany\tnote",
        "com.apple.\tApple app or service\t\tApple\tfictional prefix row",
        "com.apple.mobilesafari\tSafari\t\tApple\tfictional",
        "test.zappy.app\tZappy\t\tZappy Inc\tfictional",
    ].joined(separator: "\n") + "\n"

    public static let t0 = Date(timeIntervalSince1970: 1_763_000_000)

    private static func row(_ importId: String, _ app: String, _ domain: String, _ owner: String? = nil, _ hits: Int,
                            first: TimeInterval = 0, last: TimeInterval = 60) -> Row {
        Row(importId: importId, appId: app, domain: domain, domainOwner: owner, hits: hits,
            firstSeen: t0.addingTimeInterval(first), lastSeen: t0.addingTimeInterval(last))
    }

    public static let zappy = "test.zappy.app"
    public static let unjoined = "com.example.unjoined"
    public static let safari = "com.apple.mobilesafari"
    public static let weatherx = "com.apple.weatherx"

    public static func rows() -> [Row] {
        [
            row("imp1", zappy, "a.ads.test", nil, 5),
            row("imp1", zappy, "ads.test", nil, 3),
            row("imp1", zappy, "b.adsalt.test", nil, 2),
            row("imp1", zappy, "www.video.test", nil, 10, first: -3600),
            row("imp2", zappy, "www.video.test", nil, 7, last: 7200),
            row("imp1", zappy, "unlisted-o.test", "Wexford Systems Corp", 1),
            row("imp1", zappy, "203.0.113.9", "Wexford Systems Corp", 2),
            row("imp1", zappy, "noco-ads.test", nil, 4),
            row("imp1", zappy, "unknown-r.test", nil, 2),
            row("imp1", zappy, "192.0.2.55", nil, 6),
            row("imp1", unjoined, "cdn.test", nil, 3),
            row("imp1", unjoined, "2001:db8::1", nil, 1),
            row("imp1", unjoined, "someone.pages.dev", nil, 1),
            row("imp1", safari, "push.apple-sys.test", nil, 4),
            row("imp1", safari, "ads.test", nil, 1),
            row("imp1", weatherx, "push.apple-sys.test", nil, 2),
            row("imp1", weatherx, "198.51.100.7", nil, 1),
        ]
    }

    /// the hand-worked answers: domains are distinct per entry; contacts are Apple's hit counts, summed
    public enum Expected {
        /// non-Apple apps, sorted by name (non-localized, case-insensitive): "com.example.unjoined" before "Zappy"
        public static let appKeys = [unjoined, zappy]

        public enum Zappy {
            public static let name = "Zappy"
            public static let company = "Zappy Inc"
            public static let identified = (domains: 6, contacts: 30)
            public static let notIdentified = (domains: 3, contacts: 12)
            public static let companyOrder = ["Zappy Inc", "AdCo Holdings", "Wexford"]
            public static let namedCompanies = 3
            public static let adTrackCompanies = 1
            public static let unnamedAdvertising = 1
            public static let adCoBrands = ["AdCo", "AdCo Two"]
            public static let adCo = (domains: 3, contacts: 10)
            public static let zappyInc = (domains: 1, contacts: 17)
            /// Apple's owner string is the brand; the alias gives the parent
            public static let wexfordBrands = ["Wexford Systems Corp"]
            public static let wexford = (domains: 2, contacts: 3)
            /// earliest firstSeen and latest lastSeen of Zappy's rows
            public static let windowSeconds: TimeInterval = 3600 + 7200
        }

        public enum Unjoined {
            /// titled by its bundle id (owner, 2026-11-24)
            public static let name = unjoined
            public static let identified = (domains: 1, contacts: 3)
            public static let notIdentified = (domains: 2, contacts: 2)
            public static let companyOrder = ["CdnCo"]
        }

        public enum AppleApps {
            public static let key = "apple"
            public static let name = "Apple apps"
            public static let company = "Apple"
            /// distinct over both members: push.apple-sys.test counts once
            public static let identified = (domains: 2, contacts: 7)
            public static let notIdentified = (domains: 1, contacts: 1)
            public static let companyOrder = ["Apple", "AdCo Holdings"]
            /// members sorted by name: the id "com.apple.weatherx" before "Safari"
            public static let memberKeys = [ReportSummaryCorpus.weatherx, ReportSummaryCorpus.safari]
            public static let memberNames = [ReportSummaryCorpus.weatherx, "Safari"]
            public static let safariCounts = (identifiedDomains: 2, notIdentifiedDomains: 0, contacts: 5)
            public static let weatherxCounts = (identifiedDomains: 1, notIdentifiedDomains: 1, contacts: 3)
        }
    }
}
