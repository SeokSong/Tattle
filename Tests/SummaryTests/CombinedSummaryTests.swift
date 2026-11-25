import Attribution
import Companies
import Flows
import Foundation
import Summary
import Testing
import TestSupport

private func captureSummary() throws -> CaptureSummary {
    let curated = try CuratedList(parsing: SummaryCorpus.curatedTSV, version: "")
    let trackers = try TrackerList(parsing: SummaryCorpus.trackerTSV,
        categories: try TrackerCategoryMap(parsing: SummaryCorpus.trackerCategoriesTSV),
        aliases: try TrackerOwnerAliases(parsing: SummaryCorpus.trackerAliasesTSV), version: "")
    let flows = SummaryCorpus.flows()
    return SummaryBuilder.build(flows: flows, index: HostnameIndex(SummaryCorpus.observations(), flows: flows),
        classifier: CompanyClassifier(curated: curated, trackers: trackers), apps: try AppTable(parsing: SummaryCorpus.appsTSV))
}

private func reportSummary() throws -> ReportSummary {
    let trackers = try TrackerList(parsing: ReportSummaryCorpus.trackerTSV,
        categories: try TrackerCategoryMap(parsing: ReportSummaryCorpus.trackerCategoriesTSV),
        aliases: try TrackerOwnerAliases(parsing: ReportSummaryCorpus.trackerAliasesTSV), version: "")
    let classifier = CompanyClassifier(curated: try CuratedList(parsing: ReportSummaryCorpus.curatedTSV, version: ""),
        appleOwners: try AppleOwnerTable(parsing: ReportSummaryCorpus.appleOwnersTSV), trackers: trackers)
    let inputs = ReportSummaryCorpus.rows().map { ReportContactInput(appId: $0.appId, domain: $0.domain, domainOwner: $0.domainOwner,
        hits: $0.hits, firstSeen: $0.firstSeen, lastSeen: $0.lastSeen) }
    return ReportSummaryBuilder.build(contacts: inputs, classifier: classifier, apps: try AppTable(parsing: ReportSummaryCorpus.appsTSV))
}

private func combined() throws -> CombinedSummary {
    CombinedSummaryBuilder.build(capture: try captureSummary(), report: try reportSummary())
}

private func card(_ s: CombinedSummary, _ key: String) throws -> AppCard {
    try #require(s.cards.first { $0.key == key })
}

private func company(_ c: AppCard, _ parent: String) throws -> CombinedCompany {
    try #require(c.companies.first { $0.parent == parent })
}

@Test func appleAppsMergeInCaptures() throws {
    let t0 = SummaryCorpus.t0
    func flow(_ n: UInt32, _ process: String, _ name: String, _ bytes: Int) -> Flow {
        let key = FlowKey(transport: .tcp, localAddress: .v4(0xCB00_7102), localPort: UInt16(40000 + n),
                          remoteAddress: .v4(0xC000_0200 + n), remotePort: 443)
        var f = Flow(key: key, interface: "en0", at: t0)
        f.serverName = name
        f.ipBytesIn = bytes
        f.tally[ProcessPair(process, n, nil, nil)] = 3
        return f
    }
    let flows = [
        flow(1, "MobileSafari", "cdn.test", 100),
        flow(2, "Maps", "push.apple-sys.test", 200),
        flow(3, "Maps", "unknown-m.test", 50),
    ]
    let table = "bundleId\tdisplayName\tprocessName\tcompany\tnote\n"
        + "com.apple.mobilesafari\tSafari\tMobileSafari\tApple\tt\n"
        + "com.apple.Maps\tMaps\tMaps\tApple\tt\n"
    let curated = try CuratedList(parsing: SummaryCorpus.curatedTSV, version: "")
    let s = SummaryBuilder.build(flows: flows, index: HostnameIndex([], flows: flows),
        classifier: CompanyClassifier(curated: curated, trackers: .empty), apps: try AppTable(parsing: table))
    #expect(s.apps.isEmpty)
    let a = try #require(s.appleApps)
    #expect(a.key == "apple")
    #expect(a.name == "Apple apps")
    #expect(a.company == "Apple")
    #expect(a.members.map(\.name) == ["Maps", "Safari"])
    #expect(a.companies.map(\.parent) == ["Apple", "CdnCo"])
    #expect(a.companies.first?.relation == .sameCompanyAsApp)
    #expect(a.identified == TrafficCount(connections: 2, bytes: 300))
    #expect(a.untracedDestinations == ["unknown-m.test"])
    let maps = try #require(a.members.first { $0.name == "Maps" })
    #expect(maps.identified.bytes == 200)
    #expect(maps.notIdentified.bytes == 50)
}

@Test func combinedCardsAreOrderedAndJoinedByKey() throws {
    let s = try combined()
    #expect(s.cards.map(\.key) == ["process:Bobber", "com.example.unjoined", "test.quill.app", "test.zappy.app", "apple", "system"])
    #expect(s.cards.map(\.kind) == [.app, .app, .app, .app, .appleApps, .system])
}

@Test func combinedZappyMatchesTheHandCount() throws {
    let z = try card(try combined(), "test.zappy.app")
    #expect(z.companyNames == ["Zappy Inc", "AdCo Holdings", "CdnCo", "Wexford"])
    let own = try company(z, "Zappy Inc")
    #expect(own.inCaptures && own.inReport)
    #expect(own.relation == .sameCompanyAsApp)
    let ad = try company(z, "AdCo Holdings")
    #expect(ad.inCaptures && ad.inReport)
    #expect(ad.captureTraffic == TrafficCount(connections: 2, bytes: 1500))
    #expect(ad.reportCount == DomainCount(domains: 3, contacts: 10))
    #expect(ad.brands == ["AdCo", "AdCo Two"])
    let cdn = try company(z, "CdnCo")
    #expect(cdn.inCaptures && !cdn.inReport)
    let wex = try company(z, "Wexford")
    #expect(!wex.inCaptures && wex.inReport)
    #expect(wex.brands == ["Wexford Systems Corp"])
    #expect(z.adTrackNames == ["AdCo Holdings"])
    #expect(z.possibleCompanies == ["MetricCo"])
    #expect(z.untracedDestinations == 5)
    #expect(z.typeKnown == [.advertising: 2])
    let bobber = try card(try combined(), "process:Bobber")
    #expect(bobber.report == nil)
    #expect(bobber.untracedDestinations == 1)
    let unjoined = try card(try combined(), "com.example.unjoined")
    #expect(unjoined.capture == nil)
    #expect(unjoined.untracedDestinations == 2)
    let apple = try card(try combined(), "apple")
    #expect(apple.capture == nil)
    #expect(apple.members.map(\.key) == ["com.apple.weatherx", "com.apple.mobilesafari"])
    let system = try card(try combined(), "system")
    #expect(system.kind == .system)
    #expect(system.companyNames == ["Apple", "AdCo Holdings"])
}

@Test func combinedOverviewCountsDistinctAcrossCards() throws {
    let s = try combined()
    #expect(s.apps == 6)
    #expect(s.companies == 5)
    #expect(s.adTrack == 1)
    #expect(s.untraced == 9)
    #expect(s.noProcess == TrafficCount(connections: 1, bytes: 700))
    #expect(s.captureStart != nil && s.captureEnd != nil && s.reportStart != nil && s.reportEnd != nil)
}

@Test func combinedOnlyCaptures() throws {
    let c = try captureSummary()
    let s = CombinedSummaryBuilder.build(capture: c, report: nil)
    #expect(s.cards.map(\.key) == c.apps.map(\.key) + ["system"])
    #expect(s.cards.allSatisfy { $0.companies.allSatisfy { !$0.inReport } })
    #expect(s.reportStart == nil && s.reportEnd == nil)
}

@Test func combinedOnlyReport() throws {
    let s = CombinedSummaryBuilder.build(capture: nil, report: try reportSummary())
    #expect(!s.cards.contains { $0.kind == .system })
    #expect(s.noProcess == TrafficCount())
    #expect(s.captureStart == nil && s.captureEnd == nil)
    #expect(s.cards.allSatisfy { $0.companies.allSatisfy { !$0.inCaptures } })
}

@Test func combinedEmpty() {
    let s = CombinedSummaryBuilder.build(capture: nil, report: nil)
    #expect(s.cards.isEmpty)
    #expect(s.apps == 0 && s.companies == 0 && s.adTrack == 0 && s.untraced == 0)
    #expect(s.noProcess == TrafficCount())
    #expect(s.curatedVersion == "" && s.trackerListVersion == "")
}

@Test func combinedNamesAreNeverInTheCardText() throws {
    let capture = try captureSummary(), report = try reportSummary()
    var names = Set<String>()
    for a in capture.apps + [capture.appleApps, capture.system].compactMap({ $0 }) { names.formUnion(a.untracedDestinations) }
    for a in report.apps + [report.appleApps].compactMap({ $0 }) { names.formUnion(a.untracedDestinations) }
    #expect(!names.isEmpty)
    let s = CombinedSummaryBuilder.build(capture: capture, report: report)
    func visit(_ c: AppCard) {
        for child in Mirror(reflecting: c).children {
            if let text = child.value as? String { #expect(!names.contains(text), "\(child.label ?? "")") }
        }
        c.members.forEach(visit)
    }
    s.cards.forEach(visit)
}
