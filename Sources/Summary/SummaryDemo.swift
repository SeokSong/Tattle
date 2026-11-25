import Attribution
import Companies
import Foundation

/// made-up summary values for looking at the screen without any capture or report. every app, company and
/// destination is invented (destinations end in `.test`). the demo only supplies numbers and names; every
/// sentence still comes from `SummaryScreenBuilder`
public enum SummaryDemo {
    private typealias Spec = (parent: String, categories: [CompanyCategory], own: Bool, captures: Bool, report: Bool)

    private static func relation(_ own: Bool, hasCompany: Bool) -> LabelRelation { own ? .sameCompanyAsApp : (hasCompany ? .other : .unknown) }

    private static func captureApp(
        key: String, name: String, company: String?, _ specs: [Spec], untraced: Set<String> = [], typeKnown: [CompanyCategory: Set<String>] = [:],
        identified: Int, total: Int, now: Date, members: [CaptureAppSummary] = []
    ) -> CaptureAppSummary {
        CaptureAppSummary(
            key: key, name: name, company: company,
            companies: specs.filter(\.captures).map {
                CompanyEntry(parent: $0.parent, brands: [$0.parent], categories: $0.categories,
                    relation: relation($0.own, hasCompany: company != nil), traffic: TrafficCount(connections: 3, bytes: 1000))
            },
            possibleCompanies: [], typeKnownDestinations: typeKnown, untracedDestinations: untraced,
            identified: TrafficCount(connections: 3, bytes: identified), notIdentified: TrafficCount(connections: 1, bytes: total - identified),
            hinted: TrafficCount(), unseen: Dictionary(uniqueKeysWithValues: UnnamedReason.allCases.map { ($0, TrafficCount()) }),
            coverage: CoverageRatio(numerator: identified, denominator: total),
            windowStart: now - 3 * 86400, windowEnd: now - 86400, members: members)
    }

    private static func reportApp(
        key: String, name: String, company: String?, _ specs: [Spec], untraced: Set<String> = [], identified: Int, total: Int,
        now: Date, members: [ReportAppSummary] = []
    ) -> ReportAppSummary {
        ReportAppSummary(
            key: key, name: name, company: company,
            companies: specs.filter(\.report).map {
                ReportCompanyEntry(parent: $0.parent, brands: [$0.parent], categories: $0.categories,
                    relation: relation($0.own, hasCompany: company != nil), count: DomainCount(domains: 1, contacts: 5))
            },
            typeKnownDestinations: [:], untracedDestinations: untraced, identified: DomainCount(domains: identified, contacts: 5),
            notIdentified: DomainCount(domains: total - identified, contacts: 1), coverage: CoverageRatio(numerator: identified, denominator: total),
            firstSeen: now - 6 * 86400, lastSeen: now - 86400, members: members)
    }

    public static func combined(now: Date = Date()) -> CombinedSummary {
        let adlantic: Spec = ("Adlantic", [.advertising], false, true, true)
        let pinwheel: [Spec] = [
            ("Pinwheel Labs", [.onlineService], true, true, true), adlantic, ("Metricly", [.analytics], false, true, false),
            ("Cloudway", [.cloudService], false, false, true),
        ]
        let quillnote: [Spec] = [
            ("Quillnote Inc", [.onlineService], true, true, false), ("Adlantic", [.advertising], false, true, false),
            ("Trackwise", [.analytics], false, true, false), ("Pixelbeam", [.advertising], false, true, false),
            ("Cloudway", [.cloudService], false, true, false),
        ]
        let bobbin: [Spec] = [("Cloudway", [.cloudService], false, true, false)]
        let safari: [Spec] = [("Apple", [.appleSystem], true, true, true), adlantic]
        let maps: [Spec] = [("Apple", [.appleSystem], true, true, true)]
        let apple: [Spec] = [("Apple", [.appleSystem], true, true, true), adlantic]
        let system: [Spec] = [("Apple", [.appleSystem], true, true, false), ("Metricly", [.analytics], false, true, false)]

        let capture = CaptureSummary(
            apps: [
                captureApp(key: "test.pinwheel", name: "Pinwheel", company: "Pinwheel Labs", pinwheel,
                    untraced: ["pinwheel-1.test", "pinwheel-2.test"], typeKnown: [.advertising: ["pinwheel-ad.test"]],
                    identified: 412_000, total: 530_000, now: now),
                captureApp(key: "test.quillnote", name: "Quillnote", company: "Quillnote Inc", quillnote,
                    untraced: ["quillnote-1.test", "quillnote-2.test"], identified: 900_000, total: 1_000_000, now: now),
                captureApp(key: "process:Bobbin", name: "Bobbin", company: nil, bobbin, identified: 50_000, total: 50_000, now: now),
            ],
            system: captureApp(key: CaptureSummary.systemKey, name: CaptureSummary.systemName, company: CaptureSummary.systemCompany,
                system, identified: 80_000, total: 100_000, now: now),
            appleApps: captureApp(key: ReportSummary.appleKey, name: "Apple apps", company: "Apple", apple,
                identified: 70_000, total: 90_000, now: now,
                members: [
                    captureApp(key: "com.apple.test.safari", name: "Safari", company: "Apple", safari, identified: 40_000, total: 50_000, now: now),
                    captureApp(key: "com.apple.test.maps", name: "Maps", company: "Apple", maps, identified: 30_000, total: 40_000, now: now),
                ]),
            noProcess: TrafficCount(connections: 3, bytes: 3000), excluded: [:], curatedVersion: "demo", trackerListVersion: "demo")

        let report = ReportSummary(
            apps: [
                reportApp(key: "test.pinwheel", name: "Pinwheel", company: "Pinwheel Labs", pinwheel,
                    untraced: ["pinwheel-2.test", "pinwheel-3.test", "pinwheel-4.test"], identified: 9, total: 12, now: now),
                reportApp(key: "com.example.lantern", name: "com.example.lantern", company: nil, [],
                    untraced: ["lantern-1.test", "lantern-2.test", "lantern-3.test"], identified: 0, total: 3, now: now),
            ],
            appleApps: reportApp(key: ReportSummary.appleKey, name: "Apple apps", company: "Apple", apple, identified: 4, total: 5, now: now,
                members: [
                    reportApp(key: "com.apple.test.safari", name: "Safari", company: "Apple", safari, identified: 3, total: 4, now: now),
                    reportApp(key: "com.apple.test.maps", name: "Maps", company: "Apple", maps, identified: 1, total: 1, now: now),
                ]),
            curatedVersion: "demo", trackerListVersion: "demo")
        return CombinedSummaryBuilder.build(capture: capture, report: report)
    }

    public static func screen(now: Date = Date(), timeZone: TimeZone = .current) -> SummaryScreen {
        SummaryScreenBuilder.build(combined(now: now), timeZone: timeZone, now: now)
    }
}
