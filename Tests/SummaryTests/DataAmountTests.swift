import Companies
import Foundation
import Summary
import Testing

// 5.2 "Show data amounts" (owner, 2026-11-24): each company's share of the app's captured traffic, captures only

@Test func dataShareText() {
    #expect(SummaryScreenBuilder.dataShare(bytes: 123, of: 1000) == "12.3% of data")
    #expect(SummaryScreenBuilder.dataShare(bytes: 10, of: 1000) == "1.0% of data")
    #expect(SummaryScreenBuilder.dataShare(bytes: 5, of: 1000) == "under 1% of data")
    // a company seen in captures with no bytes still says so; one not seen in captures has no share
    #expect(SummaryScreenBuilder.dataShare(bytes: 0, of: 1000) == "under 1% of data")
    #expect(SummaryScreenBuilder.dataShare(bytes: 500, of: 1000, inCaptures: false) == nil)
    #expect(SummaryScreenBuilder.dataShare(bytes: 10, of: 0) == nil)
}

@Test func dataSharesAreCapturesOnlyAndNeverExceedTheTracedPart() throws {
    let screen = SummaryDemo.screen()
    let pinwheel = try #require(screen.rows.first { $0.title == "Pinwheel" })
    let lines = pinwheel.trackingCompanies + pinwheel.otherCompanies
    // Cloudway is seen only in the App Privacy Report: no data amount
    #expect(lines.first { $0.parent == "Cloudway" }?.dataShare == nil)
    #expect(lines.filter { $0.parent != "Cloudway" }.allSatisfy { $0.dataShare != nil })
    // a report-only app has no data amounts at all
    let lantern = try #require(screen.rows.first { $0.title == "com.example.lantern" })
    #expect((lantern.trackingCompanies + lantern.otherCompanies).allSatisfy { $0.dataShare == nil })
    // the shares add up to no more than the traced part. every share is read: an "under 1%" counts as 1
    let shares = lines.compactMap(\.dataShare)
    let values = shares.map { $0.hasPrefix("under 1%") ? 1.0 : Double($0.split(separator: "%").first ?? "") }
    #expect(values.allSatisfy { $0 != nil }, "unreadable share in \(shares)")
    let traced = try #require(pinwheel.traced.first?.text.split(separator: " ").dropFirst().first.flatMap { Double($0.dropLast()) })
    #expect(values.compactMap { $0 }.reduce(0, +) <= traced + 1)
}

@Test func dataToggleOnlyWithCaptures() {
    #expect(SummaryDemo.screen().hasCaptures)
    #expect(!SummaryScreenBuilder.build(CombinedSummaryBuilder.build(capture: nil, report: nil)).hasCaptures)
    #expect(SummaryScreen.dataAmountsToggle == "Show data amounts")
}

@Test func dataSharesAddUpCompaniesThatDifferOnlyInCase() {
    // review of PR #14: two capture parents that differ only in case are one company, and their bytes add up
    let entry = { (parent: String, bytes: Int) in
        CompanyEntry(parent: parent, brands: [parent], categories: [.advertising], relation: .other,
                     traffic: TrafficCount(connections: 1, bytes: bytes))
    }
    let app = CaptureAppSummary(
        key: "test.case", name: "Case", company: nil, companies: [entry("Adco", 4000), entry("ADCO", 1000)],
        possibleCompanies: [], typeKnownDestinations: [:], untracedDestinations: [],
        identified: TrafficCount(connections: 2, bytes: 5000), notIdentified: TrafficCount(connections: 0, bytes: 5000),
        hinted: TrafficCount(), unseen: [:], coverage: CoverageRatio(numerator: 5000, denominator: 10000),
        windowStart: Date(), windowEnd: Date(), members: [])
    let capture = CaptureSummary(apps: [app], system: nil, appleApps: nil, noProcess: TrafficCount(),
                                 excluded: [:], curatedVersion: "", trackerListVersion: "")
    let card = CombinedSummaryBuilder.build(capture: capture, report: nil).cards.first
    #expect(card?.companies.count == 1)
    #expect(card?.companies.first?.captureTraffic.bytes == 5000)
}
