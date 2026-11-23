import Companies
import Foundation
import Pipeline
import TestSupport
import Testing

// local only: skipped without TATTLE_FIXTURES. prints numbers, never an app id or a process name

/// the share of the local report's bundle ids the app table must join (owner decision 2026-11-23).
/// just under the rate measured then, so a drop fails; raise it as the table grows
let reportJoinRateFloor = 0.65

@Test func appTableCoverageIsPrintedForTheLocalReport() throws {
    guard let url = Fixtures.privacyReport() else { return }
    let ids = try ReportImporter.appIds(file: url)
    let rate = AppTable.bundled.joinRate(bundleIds: ids)
    print("app table coverage (local): report bundle ids joined \(rate.joined) of \(rate.total), table rows \(AppTable.bundled.count)")
    #expect(rate.total > 0)
    #expect(rate.joined + rate.notJoined.count == rate.total)
    let share = Double(rate.joined) / Double(rate.total)
    #expect(share >= reportJoinRateFloor, "report join rate \(String(format: "%.3f", share)) is under the floor \(reportJoinRateFloor)")
}
