import Attribution
import Companies
import Flows
import Foundation
import Summary
import Testing
import TestSupport

private typealias Expected = SummaryCorpus.Expected

private func corpusSummary(curatedVersion: String = "", trackerVersion: String = "") throws -> CaptureSummary {
    let curated = try CuratedList(parsing: SummaryCorpus.curatedTSV, version: curatedVersion)
    let trackers = try TrackerList(parsing: SummaryCorpus.trackerTSV,
        categories: try TrackerCategoryMap(parsing: SummaryCorpus.trackerCategoriesTSV),
        aliases: try TrackerOwnerAliases(parsing: SummaryCorpus.trackerAliasesTSV), version: trackerVersion)
    let flows = SummaryCorpus.flows()
    return SummaryBuilder.build(flows: flows, index: HostnameIndex(SummaryCorpus.observations(), flows: flows),
        classifier: CompanyClassifier(curated: curated, trackers: trackers), apps: try AppTable(parsing: SummaryCorpus.appsTSV))
}

private func app(_ s: CaptureSummary, _ key: String) throws -> CaptureAppSummary {
    try #require(s.apps.first { $0.key == key })
}

private func entry(_ a: CaptureAppSummary, _ parent: String) throws -> CompanyEntry {
    try #require(a.companies.first { $0.parent == parent })
}

private func asTraffic(_ t: (connections: Int, bytes: Int)) -> TrafficCount {
    TrafficCount(connections: t.connections, bytes: t.bytes)
}

@Test func appsMergeThroughTheAppTable() throws {
    let s = try corpusSummary()
    #expect(s.apps.map(\.key) == ["process:Bobber", Expected.Quill.key, Expected.Zappy.key])
    let zappy = try app(s, Expected.Zappy.key)
    #expect(zappy.name == Expected.Zappy.name)
    #expect(zappy.company == Expected.Zappy.company)
    #expect(try app(s, "process:Bobber").company == nil)
}

@Test func zappyEntryMatchesTheHandCount() throws {
    let z = try app(try corpusSummary(), Expected.Zappy.key)
    #expect(z.identified == asTraffic(Expected.Zappy.identified))
    #expect(z.notIdentified == asTraffic(Expected.Zappy.notIdentified))
    #expect(z.hinted == asTraffic(Expected.Zappy.hinted))
    #expect(z.unseen[.echHidden] == asTraffic(Expected.Zappy.echHidden))
    #expect(z.unseen[.startedBeforeCapture] == asTraffic(Expected.Zappy.startedBeforeCapture))
    #expect(z.unseen[.noHandshakeUDP] == TrafficCount())
    #expect(z.unseen[.noDNSMatch] == TrafficCount())
    #expect(z.namedCompanies == Expected.Zappy.namedCompanies)
    #expect(z.adTrackCompanies == Expected.Zappy.adTrackCompanies)
    #expect(z.possibleCompanies == Expected.Zappy.possibleCompanies)
    #expect(z.unnamedCategories == [.advertising: Expected.Zappy.unnamedAdvertising])
    #expect(z.companies.map(\.parent) == Expected.Zappy.companyOrder)
    let adCo = try entry(z, "AdCo Holdings")
    #expect(adCo.brands == Expected.Zappy.adCoBrands)
    #expect(adCo.traffic == TrafficCount(connections: Expected.Zappy.adCoConnections, bytes: Expected.Zappy.adCoBytes))
    #expect(adCo.categories == [.advertising, .analytics])
    #expect(z.coverage == CoverageRatio(numerator: Expected.Zappy.identified.bytes, denominator: Expected.Zappy.totalBytes))
    #expect(z.windowEnd.timeIntervalSince(z.windowStart) == Expected.Zappy.windowSeconds)
}

@Test func everyByteIsInExactlyOneBucket() throws {
    let s = try corpusSummary()
    let totals: [String: Int] = [
        Expected.Zappy.key: Expected.Zappy.totalBytes, Expected.Quill.key: Expected.Quill.totalBytes,
        "process:Bobber": Expected.Bobber.totalBytes, CaptureSummary.systemKey: Expected.System.totalBytes,
    ]
    let all = s.apps + (s.system.map { [$0] } ?? [])
    #expect(all.count == totals.count)
    for a in all {
        let sum = a.identified.bytes + a.notIdentified.bytes + a.hinted.bytes + a.unseen.values.reduce(0) { $0 + $1.bytes }
        #expect(sum == a.coverage.denominator)
        #expect(sum == totals[a.key])
    }
}

@Test func countsUseDistinctParentCompanies() throws {
    let z = try app(try corpusSummary(), Expected.Zappy.key)
    #expect(z.companies.filter { $0.parent == "AdCo Holdings" }.count == 1)
    #expect(try entry(z, "AdCo Holdings").brands.count == 2)
}

@Test func hintsNeverEnterCounts() throws {
    let s = try corpusSummary()
    let z = try app(s, Expected.Zappy.key)
    #expect(z.possibleCompanies.contains("MetricCo"))
    for a in s.apps + (s.system.map { [$0] } ?? []) {
        #expect(!a.companies.contains { $0.parent == "MetricCo" })
    }
}

@Test func ownCompanyIsMarkedAndFirst() throws {
    let s = try corpusSummary()
    let z = try app(s, Expected.Zappy.key)
    #expect(z.companies.first?.parent == Expected.Zappy.company)
    #expect(z.companies.first?.relation == .sameCompanyAsApp)
    #expect(try entry(try app(s, "process:Bobber"), "CdnCo").relation == .unknown)
}

@Test func systemEntryUsesApple() throws {
    let sys = try #require(try corpusSummary().system)
    #expect(sys.key == CaptureSummary.systemKey)
    #expect(sys.name == Expected.System.name)
    #expect(sys.company == Expected.System.company)
    #expect(sys.companies.map(\.parent) == Expected.System.companyOrder)
    #expect(try entry(sys, "Apple").relation == .sameCompanyAsApp)
    #expect(sys.unseen[.startedBeforeCapture] == asTraffic(Expected.System.startedBeforeCapture))
}

@Test func unnamedCategoriesNeverCountAsCompanies() throws {
    let s = try corpusSummary()
    let q = try app(s, Expected.Quill.key)
    #expect(q.unnamedCategories == [.analytics: Expected.Quill.unnamedAnalytics])
    #expect(q.namedCompanies == Expected.Quill.namedCompanies)
    for a in s.apps + (s.system.map { [$0] } ?? []) {
        #expect(!a.companies.contains { $0.parent.contains("noco") })
    }
}

@Test func noProcessAndExcludedTraffic() throws {
    let s = try corpusSummary()
    #expect(s.noProcess == asTraffic(Expected.noProcess))
    #expect(s.excluded[.deviceLink] == asTraffic(Expected.deviceLink))
    #expect(s.excluded[.localNetwork] == asTraffic(Expected.localNetwork))
}

@Test func port443Only() throws {
    let s = try corpusSummary()
    let apps = (s.apps + (s.system.map { [$0] } ?? [])).reduce(0) { $0 + $1.coverage.denominator }
    let excluded = (s.excluded[.deviceLink]?.bytes ?? 0) + (s.excluded[.localNetwork]?.bytes ?? 0)
    #expect(apps + s.noProcess.bytes + excluded == Expected.port443Bytes)
}

@Test func datasetVersionsArePresent() throws {
    let s = try corpusSummary(curatedVersion: "9", trackerVersion: "2026-01-01")
    #expect(s.curatedVersion == "9")
    #expect(s.trackerListVersion == "2026-01-01")
}

@Test func emptyInputGivesEmptySummary() {
    let s = SummaryBuilder.build(flows: [], index: HostnameIndex([]))
    #expect(s.apps.isEmpty)
    #expect(s.system == nil)
    #expect(s.noProcess == TrafficCount())
    #expect(s.excluded[.deviceLink] == TrafficCount())
    #expect(s.excluded[.localNetwork] == TrafficCount())
    #expect(s.excluded.count == 2)
}
