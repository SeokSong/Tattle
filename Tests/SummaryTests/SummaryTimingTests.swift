import Attribution
import Companies
import Foundation
import Summary
import Testing
import TestSupport

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
    let system = summary.system
    #expect(system != nil)
    let total = flows.reduce(0) { $0 + $1.ipBytesIn + $1.ipBytesOut }
    #expect(summary.apps.reduce(0) { $0 + $1.coverage.denominator } + (system?.coverage.denominator ?? 0) == total)
}
