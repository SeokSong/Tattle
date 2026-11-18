import Flows
import Foundation
import Testing
import TestSupport

@testable import Report

private func report(noProcess: Ratio, coverage: Ratio = Ratio(numerator: 91_000, denominator: 100_000)) -> QualityReport {
    QualityReport(
        reportVersion: 1, watchVersion: "test",
        totals: .init(flows: 1, packets: 1, ipBytes: 1_400_000), byInterface: [:],
        attribution: .init(
            attributedShare: Ratio(numerator: 98, denominator: 100), noProcessShare: noProcess,
            mixedFlowShare: Ratio(numerator: 0, denominator: 100_000)),
        hostnames: .init(hostnameCoverageSniOnly: coverage),
        reconciliation: .init(ok: true, checks: []), detail: nil)
}

private func bands(_ metrics: [String: MetricBand]) -> BandsFile {
    BandsFile(scenario: "s1-safari", baselineLabel: "label", metrics: metrics)
}

@Test func ratchetFlagsDropBelowFloor() {
    let r = report(noProcess: Ratio(numerator: 0, denominator: 100_000), coverage: Ratio(numerator: 89_000, denominator: 100_000))
    let found = Ratchet.check(report: r, bands: bands(["hostnameCoverageSniOnly": MetricBand(baseline: 0.91, floor: 0.905, ceiling: 1)]))
    #expect(found.count == 1)
    #expect(found[0].metric == "hostnameCoverageSniOnly" && found[0].kind == .belowFloor)
    #expect(abs(found[0].points - 1.5) < 1e-9)
    #expect(found[0].description == "hostnameCoverageSniOnly  89.0% is below floor 90.5% by 1.5 points")
}

@Test func ratchetFlagsRiseAboveCeiling() {
    let r = report(noProcess: Ratio(numerator: 3_000, denominator: 100_000))
    let found = Ratchet.check(report: r, bands: bands(["noProcessShare": MetricBand(baseline: 0.012, floor: 0, ceiling: 0.017)]))
    #expect(found.map(\.kind) == [.aboveCeiling])
    #expect(abs(found[0].points - 1.3) < 1e-9)
}

@Test func ratchetAcceptsEdge() {
    let r = report(noProcess: Ratio(numerator: 1_700, denominator: 100_000), coverage: Ratio(numerator: 90_500, denominator: 100_000))
    let b = bands([
        "noProcessShare": MetricBand(baseline: 0.012, floor: 0, ceiling: 0.017),
        "hostnameCoverageSniOnly": MetricBand(baseline: 0.91, floor: 0.905, ceiling: 1),
    ])
    #expect(Ratchet.check(report: r, bands: b).isEmpty)
}

@Test func smallDenominatorIsInformational() {
    // report side: 9,999 bytes is too few to enforce, 10,000 is enough
    let small = report(noProcess: Ratio(numerator: 9_000, denominator: 9_999))
    let b = bands(["noProcessShare": MetricBand(baseline: 0.01, floor: 0, ceiling: 0.015)])
    #expect(Ratchet.check(report: small, bands: b).isEmpty)
    let enough = report(noProcess: Ratio(numerator: 9_000, denominator: 10_000))
    #expect(Ratchet.check(report: enough, bands: b).count == 1)
    // band side: the flag skips it whatever the size
    let flagged = bands(["noProcessShare": MetricBand(baseline: 0.01, floor: 0, ceiling: 0.015, informational: true)])
    #expect(Ratchet.check(report: enough, bands: flagged).isEmpty)
    // writing bands from a small capture marks the metric informational and gives it no limits
    let made = Bands.make(from: small, scenario: "x", baselineLabel: "l")
    #expect(made.metrics["noProcessShare"]?.informational == true)
    #expect(made.metrics["noProcessShare"]?.floor == nil && made.metrics["noProcessShare"]?.ceiling == nil)
}

@Test func toleranceRuleSetsFloorAndCeiling() throws {
    let r = report(noProcess: Ratio(numerator: 1_234, denominator: 100_000))
    let made = Bands.make(from: r, scenario: "s1-safari", baselineLabel: "m1-test")
    // lower is better: floor 0, ceiling = baseline + 0.005
    #expect(made.metrics["noProcessShare"] == MetricBand(baseline: 0.012, floor: 0, ceiling: 0.017))
    // higher is better: floor = baseline - 0.005, ceiling 1
    #expect(made.metrics["hostnameCoverageSniOnly"] == MetricBand(baseline: 0.91, floor: 0.905, ceiling: 1))
    #expect(made.totalsBand == ["ipBytes": "1-2 MB"])
    // the report that made the bands passes them
    #expect(Ratchet.check(report: r, bands: made).isEmpty)
    // notes survive an update
    var old = made
    old.notes = [BandNote(metric: "hostnameCoverageSniOnly", reason: "narrowed")]
    #expect(Bands.make(from: r, scenario: "s1-safari", baselineLabel: "new", previous: old).notes == old.notes)
}

@Test func bandsFileRoundTrips() throws {
    let file = BandsFile(
        scenario: "s1-safari", baselineLabel: "m1-test", totalsBand: ["ipBytes": "1-2 MB"],
        metrics: ["a": MetricBand(baseline: 0.5, floor: 0.4), "b": MetricBand(baseline: 0.1, informational: true)],
        notes: [BandNote(metric: "a", reason: "why")])
    let back = try JSONDecoder().decode(BandsFile.self, from: Data(file.json().utf8))
    #expect(back == file)
    // "informational" is written only when true
    #expect(try file.json().components(separatedBy: "informational").count == 2)
}

@Test func bandFileCarriesNoNames() throws {
    let r = report(noProcess: Ratio(numerator: 1_234, denominator: 100_000))
    let made = Bands.make(from: r, scenario: "s1-safari", baselineLabel: "m1-2026-11-DD")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bands-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("Tests/Expected")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(made.json().utf8).write(to: dir.appendingPathComponent("s1-safari.json"))
    #expect(RepoGuard.scan(root: root).isEmpty)
}
