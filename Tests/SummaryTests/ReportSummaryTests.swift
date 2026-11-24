import Companies
import Foundation
import Summary
import Testing
import TestSupport

private typealias Expected = ReportSummaryCorpus.Expected

private func corpusSummary(_ rows: [ReportSummaryCorpus.Row] = ReportSummaryCorpus.rows(),
                           curatedVersion: String = "", trackerVersion: String = "") throws -> ReportSummary {
    let trackers = try TrackerList(parsing: ReportSummaryCorpus.trackerTSV,
        categories: try TrackerCategoryMap(parsing: ReportSummaryCorpus.trackerCategoriesTSV),
        aliases: try TrackerOwnerAliases(parsing: ReportSummaryCorpus.trackerAliasesTSV), version: trackerVersion)
    let classifier = CompanyClassifier(curated: try CuratedList(parsing: ReportSummaryCorpus.curatedTSV, version: curatedVersion),
        appleOwners: try AppleOwnerTable(parsing: ReportSummaryCorpus.appleOwnersTSV), trackers: trackers)
    let inputs = rows.map { ReportContactInput(appId: $0.appId, domain: $0.domain, domainOwner: $0.domainOwner,
        hits: $0.hits, firstSeen: $0.firstSeen, lastSeen: $0.lastSeen) }
    return ReportSummaryBuilder.build(contacts: inputs, classifier: classifier, apps: try AppTable(parsing: ReportSummaryCorpus.appsTSV))
}

private func app(_ s: ReportSummary, _ key: String) throws -> ReportAppSummary {
    try #require(s.apps.first { $0.key == key })
}

private func entry(_ a: ReportAppSummary, _ parent: String) throws -> ReportCompanyEntry {
    try #require(a.companies.first { $0.parent == parent })
}

private func asCount(_ t: (domains: Int, contacts: Int)) -> DomainCount {
    DomainCount(domains: t.domains, contacts: t.contacts)
}

@Test func appsAreSortedAndAppleIsApart() throws {
    let s = try corpusSummary()
    #expect(s.apps.map(\.key) == Expected.appKeys)
    let apple = try #require(s.appleApps)
    #expect(apple.key == Expected.AppleApps.key)
    #expect(apple.name == Expected.AppleApps.name)
    #expect(apple.company == Expected.AppleApps.company)
}

@Test func zappyMatchesTheHandCount() throws {
    let z = try app(try corpusSummary(), ReportSummaryCorpus.zappy)
    #expect(z.name == Expected.Zappy.name)
    #expect(z.company == Expected.Zappy.company)
    #expect(z.identified == asCount(Expected.Zappy.identified))
    #expect(z.notIdentified == asCount(Expected.Zappy.notIdentified))
    #expect(z.companies.map(\.parent) == Expected.Zappy.companyOrder)
    #expect(z.namedCompanies == Expected.Zappy.namedCompanies)
    #expect(z.adTrackCompanies == Expected.Zappy.adTrackCompanies)
    #expect(z.unnamedCategories == [.advertising: Expected.Zappy.unnamedAdvertising])
    let adCo = try entry(z, "AdCo Holdings")
    #expect(adCo.brands == Expected.Zappy.adCoBrands)
    #expect(adCo.categories == [.advertising, .analytics])
    #expect(adCo.count == asCount(Expected.Zappy.adCo))
    let own = try entry(z, "Zappy Inc")
    #expect(own.count == asCount(Expected.Zappy.zappyInc))
    #expect(own.relation == .sameCompanyAsApp)
    let wex = try entry(z, "Wexford")
    #expect(wex.brands == Expected.Zappy.wexfordBrands)
    #expect(wex.count == asCount(Expected.Zappy.wexford))
    #expect(wex.categories == [])
    let total = Expected.Zappy.identified.domains + Expected.Zappy.notIdentified.domains
    #expect(z.coverage == CoverageRatio(numerator: Expected.Zappy.identified.domains, denominator: total))
    let first = try #require(z.firstSeen), last = try #require(z.lastSeen)
    #expect(last.timeIntervalSince(first) == Expected.Zappy.windowSeconds)
}

@Test func hitsFromTwoImportsAreSummedAndTheDomainCountsOnce() throws {
    let z = try app(try corpusSummary(), ReportSummaryCorpus.zappy)
    #expect(try entry(z, "Zappy Inc").count == asCount(Expected.Zappy.zappyInc))
}

@Test func appleOwnerUsesTheAliasedParent() throws {
    let z = try app(try corpusSummary(), ReportSummaryCorpus.zappy)
    let wex = try entry(z, "Wexford")
    #expect(wex.parent == "Wexford")
    #expect(wex.brands == ["Wexford Systems Corp"])
}

@Test func bareAddressesAreNotIdentifiedUnlessAppleNamesThem() throws {
    let z = try app(try corpusSummary(), ReportSummaryCorpus.zappy)
    // 192.0.2.55 is one of the not identified domains
    #expect(z.notIdentified.domains == Expected.Zappy.notIdentified.domains)
    // 203.0.113.9 and unlisted-o.test are the two Wexford domains
    #expect(try entry(z, "Wexford").count.domains == Expected.Zappy.wexford.domains)
}

@Test func unjoinedAppIsTitledByItsBundleId() throws {
    let u = try app(try corpusSummary(), ReportSummaryCorpus.unjoined)
    #expect(u.name == Expected.Unjoined.name)
    #expect(u.company == nil)
    #expect(try entry(u, "CdnCo").relation == .unknown)
    #expect(u.identified == asCount(Expected.Unjoined.identified))
    #expect(u.notIdentified == asCount(Expected.Unjoined.notIdentified))
    #expect(u.companies.map(\.parent) == Expected.Unjoined.companyOrder)
}

@Test func appleAppsMergeWithAPerAppBreakdown() throws {
    let a = try #require(try corpusSummary().appleApps)
    #expect(a.identified == asCount(Expected.AppleApps.identified))
    #expect(a.notIdentified == asCount(Expected.AppleApps.notIdentified))
    #expect(a.companies.map(\.parent) == Expected.AppleApps.companyOrder)
    #expect(try entry(a, "Apple").relation == .sameCompanyAsApp)
    #expect(a.members.map(\.key) == Expected.AppleApps.memberKeys)
    #expect(a.members.map(\.name) == Expected.AppleApps.memberNames)
    let safari = try #require(a.members.first { $0.key == ReportSummaryCorpus.safari })
    let weather = try #require(a.members.first { $0.key == ReportSummaryCorpus.weatherx })
    let sc = Expected.AppleApps.safariCounts, wc = Expected.AppleApps.weatherxCounts
    #expect(safari.identified.domains == sc.identifiedDomains)
    #expect(safari.notIdentified.domains == sc.notIdentifiedDomains)
    #expect(safari.identified.contacts + safari.notIdentified.contacts == sc.contacts)
    #expect(weather.identified.domains == wc.identifiedDomains)
    #expect(weather.notIdentified.domains == wc.notIdentifiedDomains)
    #expect(weather.identified.contacts + weather.notIdentified.contacts == wc.contacts)
}

@Test func everyDomainIsInExactlyOneBucket() throws {
    let s = try corpusSummary()
    var all = s.apps
    if let apple = s.appleApps { all.append(apple); all += apple.members }
    #expect(!all.isEmpty)
    for a in all {
        #expect(a.identified.domains + a.notIdentified.domains == a.coverage.denominator, "\(a.key)")
        #expect(a.identified.domains == a.coverage.numerator, "\(a.key)")
    }
}

@Test func noBytesAndNoDomainsAnywhere() throws {
    let s = try corpusSummary()
    let a = try app(s, ReportSummaryCorpus.zappy)
    let e = try #require(a.companies.first)
    for subject in [Mirror(reflecting: a), Mirror(reflecting: e)] {
        for child in subject.children {
            let label = child.label ?? ""
            #expect(!label.lowercased().contains("byte"), "\(label)")
            if label == "domain" || label == "domains" {
                #expect(!(child.value is [String]), "\(label) holds a list of domains")
            }
        }
    }
}

@Test func reportDatasetVersionsArePresent() throws {
    let s = try corpusSummary(curatedVersion: "9", trackerVersion: "2026-01-01")
    #expect(s.curatedVersion == "9")
    #expect(s.trackerListVersion == "2026-01-01")
}

@Test func emptyReportGivesEmptySummary() {
    let s = ReportSummaryBuilder.build(contacts: [])
    #expect(s.apps.isEmpty)
    #expect(s.appleApps == nil)
}
