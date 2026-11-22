import Companies
import Foundation
import Pipeline
import TestSupport
import Testing

// local only: skipped without TATTLE_FIXTURES. prints numbers, never an app id or a process name

@Test func appTableCoverageIsPrintedForTheLocalReport() throws {
    guard let url = Fixtures.privacyReport() else { return }
    let ids = try ReportImporter.appIds(file: url)
    let rate = AppTable.bundled.joinRate(bundleIds: ids)
    print("app table coverage (local): report bundle ids joined \(rate.joined) of \(rate.total), table rows \(AppTable.bundled.count)")
    #expect(rate.total > 0)
    #expect(rate.joined + rate.notJoined.count == rate.total)
}
