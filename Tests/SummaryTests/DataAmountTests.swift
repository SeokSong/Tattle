import Foundation
import Summary
import Testing

// 5.2 "Show data amounts" (owner, 2026-11-24): each company's share of the app's captured traffic, captures only

@Test func dataShareText() {
    #expect(SummaryScreenBuilder.dataShare(bytes: 123, of: 1000) == "12.3% of data")
    #expect(SummaryScreenBuilder.dataShare(bytes: 10, of: 1000) == "1.0% of data")
    #expect(SummaryScreenBuilder.dataShare(bytes: 5, of: 1000) == "under 1% of data")
    #expect(SummaryScreenBuilder.dataShare(bytes: 0, of: 1000) == nil)
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
    // the shares add up to no more than the traced part (77.7% for Pinwheel's captures)
    let sum = lines.compactMap(\.dataShare).compactMap { Double($0.split(separator: "%").first ?? "") }.reduce(0, +)
    #expect(sum <= 77.7)
}

@Test func dataToggleOnlyWithCaptures() {
    #expect(SummaryDemo.screen().hasCaptures)
    #expect(!SummaryScreenBuilder.build(CombinedSummaryBuilder.build(capture: nil, report: nil)).hasCaptures)
    #expect(SummaryScreen.dataAmountsToggle == "Show data amounts")
}
