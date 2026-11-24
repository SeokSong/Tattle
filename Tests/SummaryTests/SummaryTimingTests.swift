import Attribution
import Companies
import Foundation
import Summary
import Testing
import TestSupport

// the 1 s budget is checked in release builds (`swift test -c release --filter weekOf100kFlowsUnderOneSecond`);
// a debug build only checks a 30 s sanity floor
@Test func weekOf100kFlowsUnderOneSecond() {
    let flows = SummaryWeek.flows(count: 100_000)
    let index = HostnameIndex([], flows: flows)
    _ = CompanyClassifier().classify(hostname: "warm.example.test")
    _ = AppTable.bundled.count
    let start = Date()
    let summary = SummaryBuilder.build(flows: flows, index: index)
    let seconds = Date().timeIntervalSince(start)
    #if DEBUG
    let configuration = "debug"
    let limit = 30.0
    #else
    let configuration = "release"
    let limit = 1.0
    #endif
    print("summary week: 100000 flows in \(Int(seconds * 1000)) ms (\(configuration))")
    #expect(seconds < limit)
    #expect(summary.apps.count == 50)
    // every path is exercised: a confirmed company and an AdGuard category without one
    #expect(summary.apps.allSatisfy { $0.companies.map(\.parent) == ["Alphabet"] })
    #expect(summary.apps.allSatisfy { $0.unnamedCategories[.advertising] == 1 })
    let system = summary.system
    #expect(system != nil)
    let total = flows.reduce(0) { $0 + $1.ipBytesIn + $1.ipBytesOut }
    #expect(summary.apps.reduce(0) { $0 + $1.coverage.denominator } + (system?.coverage.denominator ?? 0) == total)
}
