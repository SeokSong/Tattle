import Attribution
import Companies
import Domains
import Flows
import Foundation
import Testing
import TestSupport

import Summary

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let expected = CompanyCorpus.Expected()

private func classifier(_ tsv: String = CompanyCorpus.curatedTSV) throws -> CompanyClassifier {
    CompanyClassifier(curated: try CuratedList(parsing: tsv, version: "test", sha256: "none"))
}

private func build(
    flows: [Flow] = CompanyCorpus.flows(), observations: [DomainObservation] = CompanyCorpus.observations(),
    tsv: String = CompanyCorpus.curatedTSV
) throws -> CoverageResult {
    Coverage.build(flows: flows, index: HostnameIndex(observations, flows: flows), classifier: try classifier(tsv))
}

private func ratio(_ result: CoverageResult, _ key: String) -> CoverageRatio? { result.report.metrics[key] }

@Test func syntheticCoverageIsExact() throws {
    let r = try build()
    #expect(ratio(r, "companyCoverage") == CoverageRatio(numerator: expected.matchedBytes, denominator: expected.allBytes))
    #expect(ratio(r, "companyCoverageOfNamedBytes") == CoverageRatio(numerator: expected.matchedBytes, denominator: expected.namedBytes))
    #expect(ratio(r, "domainCoverage") == CoverageRatio(numerator: expected.identifiedDomains, denominator: expected.domainCount))
    // one source, so it labels every identified domain
    #expect(ratio(r, "labelSourceShare.curated") == CoverageRatio(numerator: 3, denominator: 3))
    #expect(r.report.counts["namedCompanies"] == expected.namedCompanies)
    #expect(r.report.counts["adTrackCompanies"] == expected.adTrackCompanies)
    #expect(r.report.counts["possibleCompanies"] == expected.possibleCompanies)
    #expect(r.report.counts["unmatched.connections"] == expected.unmatchedConnections)
    #expect(r.report.curatedVersion == "test")
    #expect(r.unmatched.map(\.domain) == expected.unmatchedDomains.map(\.name))
    #expect(r.unmatched.map(\.bytes) == expected.unmatchedDomains.map(\.bytes))
    #expect(r.unmatched.map(\.flows) == expected.unmatchedDomains.map(\.flows))
}

@Test func unmatchedAndEchAreInDenominator() throws {
    // the ech flow (2000), the flow with no name (800) and the hint flow (700) are in the 443 base
    // but in no numerator; the flow to port 80 is in neither
    let r = try build()
    let all = try #require(ratio(r, "companyCoverage"))
    let named = try #require(ratio(r, "companyCoverageOfNamedBytes"))
    #expect(all.denominator - named.denominator == 2000 + 800 + 700)
    // the two unmatched sni names stay in both denominators
    #expect(named.denominator - all.numerator == 1500 + 1000)
    // removing the ech, unnamed and hint flows only shrinks the first denominator
    let flows = CompanyCorpus.flows().filter { $0.key.remotePort == 443 && ($0.serverName != nil && !$0.echSeen) }
    let trimmed = try build(flows: flows, observations: [])
    #expect(ratio(trimmed, "companyCoverage") == ratio(trimmed, "companyCoverageOfNamedBytes"))
}

@Test func hintsAreExcluded() throws {
    let flows = CompanyCorpus.flows()
    let withHint = try build(flows: flows, observations: CompanyCorpus.observations())
    let without = try build(flows: flows, observations: [])
    // a flow named only by a dns answer adds nothing to any ratio or to the confirmed counts
    #expect(withHint.report.metrics == without.report.metrics)
    #expect(withHint.report.counts["namedCompanies"] == without.report.counts["namedCompanies"])
    #expect(withHint.report.counts["adTrackCompanies"] == without.report.counts["adTrackCompanies"])
    #expect(withHint.report.counts["possibleCompanies"] == 1)
    #expect(without.report.counts["possibleCompanies"] == 0)
    // and it is still an unmatched connection either way
    #expect(withHint.report.counts["unmatched.connections"] == without.report.counts["unmatched.connections"])
    // a hint to a company that is also confirmed is not counted as possible
    let cdnHint = DomainObservation(
        time: Date(timeIntervalSince1970: 1_762_999_990), source: .dns, hostname: "cdn.test",
        addresses: [.v4(0xC000_0200 + 10)])
    #expect(try build(flows: flows, observations: [cdnHint]).report.counts["possibleCompanies"] == 0)
}

@Test func outputHasNoHostnames() throws {
    let r = try build()
    for text in [try r.report.json(), r.report.text()] {
        for needle in [".test", "AdCo", "CdnCo", "Social", "MetricCo", "unknown", "ads", "cdn"] {
            #expect(!text.contains(needle), "output contains a name")
        }
    }
    // the same guard the committed band files pass
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cov-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("Tests/Expected")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let bands = CoverageBands.make(from: r.report, scenario: "x", baselineLabel: "y")
    try Data(bands.json().utf8).write(to: folder.appendingPathComponent("a.json"))
    try Data(r.report.json().utf8).write(to: folder.appendingPathComponent("b.json"))
    #expect(RepoGuard.scan(root: dir) == [])
}

@Test func bandRatchetFailsWhenWorse() throws {
    let base = try build()
    let bands = CoverageBands.make(from: base.report, scenario: "x", baselineLabel: "y")
    #expect(CoverageRatchet.check(report: base.report, bands: bands).isEmpty)
    // a list without the content delivery row names less
    let smaller = CompanyCorpus.curatedTSV.split(separator: "\n").filter { !$0.hasPrefix("cdn.test") }.joined(separator: "\n") + "\n"
    let worse = try build(tsv: smaller)
    let found = CoverageRatchet.check(report: worse.report, bands: bands)
    #expect(Set(found.map(\.metric)) == ["companyCoverage", "companyCoverageOfNamedBytes", "domainCoverage"])
    #expect(found.allSatisfy { $0.points > 0 })
    // a better list passes
    let better = CompanyCorpus.curatedTSV + "unknown-one.test\tOneCo\tOneCo\tcloudService\tfictional\n"
    #expect(CoverageRatchet.check(report: try build(tsv: better).report, bands: bands).isEmpty)
    // the share of a source is recorded, never enforced
    #expect(bands.metrics["labelSourceShare.curated"]?.informational == true)
    // a small byte denominator is recorded but not enforced unless asked
    let tiny = try build(flows: Array(CompanyCorpus.flows().prefix(2)), observations: [])
    let small = CoverageBands.make(from: tiny.report, scenario: "x", baselineLabel: "y")
    #expect(small.metrics["companyCoverage"]?.informational == true)
    #expect(small.metrics["domainCoverage"]?.informational != true)
}

@Test func zeroDenominatorHasNoValue() throws {
    let empty = try build(flows: [], observations: [])
    for key in ["companyCoverage", "companyCoverageOfNamedBytes", "domainCoverage"] {
        let r = try #require(ratio(empty, key))
        #expect(r.denominator == 0 && r.value == nil)
    }
    #expect(!(try empty.report.json()).contains("\"value\""))
    // no value, no band and no regression
    let bands = CoverageBands.make(from: empty.report, scenario: "x", baselineLabel: "y")
    #expect(bands.metrics.isEmpty)
    let full = CoverageBands.make(from: try build().report, scenario: "x", baselineLabel: "y")
    #expect(CoverageRatchet.check(report: empty.report, bands: full).isEmpty)
}

@Test func syntheticBandFileMatchesTheCorpus() throws {
    let file = root.appendingPathComponent("Tests/Expected/companies-synthetic.json")
    let committed = try CoverageBands.load(file)
    let made = CoverageBands.make(from: try build().report, scenario: committed.scenario, baselineLabel: committed.baselineLabel, previous: committed)
    #expect(committed == made)
    #expect(try committed.json() == String(contentsOf: file, encoding: .utf8))
    #expect(CoverageRatchet.check(report: try build().report, bands: committed).isEmpty)
}

@Test func bundledListGivesTheSameShapeAsTheCorpusList() throws {
    // the default classifier is the curated-only baseline: the same call, the bundled list
    let flows = CompanyCorpus.flows()
    let r = Coverage.build(flows: flows, index: HostnameIndex(CompanyCorpus.observations(), flows: flows))
    #expect(r.report.sources == ["curated"])
    #expect(r.report.curatedVersion == CuratedList.bundled.version)
    #expect(ratio(r, "companyCoverage")?.denominator == expected.allBytes)
}
