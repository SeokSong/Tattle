import Companies
import Foundation

// read time only. joins the capture summary and the report summary into one card per app.
// the destination names inside the summaries are only counted here, never copied into a card.

/// one company on a card, from either or both sources
public struct CombinedCompany: Sendable, Equatable {
    public let parent: String
    /// both sources' brands, distinct, sorted with `<`
    public let brands: [String]
    /// both sources' categories, distinct, in `CompanyCategory.allCases` order, never `.unclassified`
    public let categories: [CompanyCategory]
    public let relation: LabelRelation
    public let inCaptures: Bool
    public let inReport: Bool
    /// zero when not seen in captures / in the report
    public let captureTraffic: TrafficCount
    public let reportCount: DomainCount
    public var isAdvertisingOrTracking: Bool { categories.contains { $0.isAdvertisingOrTracking } }

    public init(
        parent: String, brands: [String], categories: [CompanyCategory], relation: LabelRelation,
        inCaptures: Bool, inReport: Bool, captureTraffic: TrafficCount, reportCount: DomainCount
    ) {
        self.parent = parent
        self.brands = brands
        self.categories = categories
        self.relation = relation
        self.inCaptures = inCaptures
        self.inReport = inReport
        self.captureTraffic = captureTraffic
        self.reportCount = reportCount
    }
}

public enum CardKind: String, Sendable, Equatable { case app, appleApps, system }

/// one card: an app from both sources, the merged Apple apps, or iOS system
public struct AppCard: Sendable, Equatable {
    public let key: String
    public let name: String
    public let company: String?
    public let kind: CardKind
    /// own company first, then advertising or tracking, then the rest; ties by parent with `<`
    public let companies: [CombinedCompany]
    /// possible parents from captures, minus every parent in `companies`, sorted
    public let possibleCompanies: [String]
    /// distinct across both sources
    public let untracedDestinations: Int
    /// distinct registrable domains per category across both sources
    public let typeKnown: [CompanyCategory: Int]
    public let capture: CaptureAppSummary?
    public let report: ReportAppSummary?
    /// Apple apps only: one card per Apple app, sorted like the cards; empty otherwise
    public let members: [AppCard]
    public var companyNames: [String] { companies.map(\.parent) }
    public var adTrackNames: [String] { companies.filter(\.isAdvertisingOrTracking).map(\.parent) }

    public init(
        key: String, name: String, company: String?, kind: CardKind, companies: [CombinedCompany],
        possibleCompanies: [String], untracedDestinations: Int, typeKnown: [CompanyCategory: Int],
        capture: CaptureAppSummary?, report: ReportAppSummary?, members: [AppCard]
    ) {
        self.key = key
        self.name = name
        self.company = company
        self.kind = kind
        self.companies = companies
        self.possibleCompanies = possibleCompanies
        self.untracedDestinations = untracedDestinations
        self.typeKnown = typeKnown
        self.capture = capture
        self.report = report
        self.members = members
    }
}

public struct CombinedSummary: Sendable, Equatable {
    /// app cards sorted by name (the same non-localized, case-insensitive compare as the builders, then key),
    /// then the Apple apps card, then the iOS system card
    public let cards: [AppCard]
    public let noProcess: TrafficCount
    public let captureStart: Date?, captureEnd: Date?, reportStart: Date?, reportEnd: Date?
    /// for the overview: apps = the app cards plus the Apple apps card's members (iOS system is not an app);
    /// companies, adTrack and untraced are distinct across every card, iOS system included
    public let apps: Int
    public let companies: Int
    public let adTrack: Int
    public let untraced: Int
    public let curatedVersion: String
    public let trackerListVersion: String

    public init(
        cards: [AppCard], noProcess: TrafficCount, captureStart: Date?, captureEnd: Date?, reportStart: Date?,
        reportEnd: Date?, apps: Int, companies: Int, adTrack: Int, untraced: Int,
        curatedVersion: String, trackerListVersion: String
    ) {
        self.cards = cards
        self.noProcess = noProcess
        self.captureStart = captureStart
        self.captureEnd = captureEnd
        self.reportStart = reportStart
        self.reportEnd = reportEnd
        self.apps = apps
        self.companies = companies
        self.adTrack = adTrack
        self.untraced = untraced
        self.curatedVersion = curatedVersion
        self.trackerListVersion = trackerListVersion
    }
}

public enum CombinedSummaryBuilder {
    private static func before(_ a: AppCard, _ b: AppCard) -> Bool {
        // a non-localized compare: the same order on every Mac
        let order = a.name.compare(b.name, options: [.caseInsensitive, .numeric])
        return order == .orderedSame ? a.key < b.key : order == .orderedAscending
    }

    private struct CompanyAcc {
        var parent: String
        var brands = Set<String>()
        var categories = Set<CompanyCategory>()
        var same = false, other = false
        var inCaptures = false, inReport = false
        var traffic = TrafficCount()
        var count = DomainCount()
    }

    private static func card(
        key: String, kind: CardKind, capture: CaptureAppSummary?, report: ReportAppSummary?, members: [AppCard] = []
    ) -> AppCard {
        var acc: [String: CompanyAcc] = [:]
        func note(_ r: LabelRelation, _ a: inout CompanyAcc) {
            if r == .sameCompanyAsApp { a.same = true } else if r == .other { a.other = true }
        }
        for c in capture?.companies ?? [] {
            var a = acc[c.parent.lowercased()] ?? CompanyAcc(parent: c.parent)
            a.parent = c.parent
            a.brands.formUnion(c.brands)
            a.categories.formUnion(c.categories)
            note(c.relation, &a)
            a.inCaptures = true
            a.traffic = c.traffic
            acc[c.parent.lowercased()] = a
        }
        for c in report?.companies ?? [] {
            var a = acc[c.parent.lowercased()] ?? CompanyAcc(parent: c.parent)
            a.brands.formUnion(c.brands)
            a.categories.formUnion(c.categories)
            note(c.relation, &a)
            a.inReport = true
            a.count = c.count
            acc[c.parent.lowercased()] = a
        }
        let companies = acc.values.map { a in
            CombinedCompany(
                parent: a.parent, brands: a.brands.sorted(),
                categories: CompanyCategory.allCases.filter { $0 != .unclassified && a.categories.contains($0) },
                relation: a.same ? .sameCompanyAsApp : (a.other ? .other : .unknown),
                inCaptures: a.inCaptures, inReport: a.inReport, captureTraffic: a.traffic, reportCount: a.count)
        }.sorted { a, b in
            let ao = a.relation == .sameCompanyAsApp, bo = b.relation == .sameCompanyAsApp
            if ao != bo { return ao }
            if a.isAdvertisingOrTracking != b.isAdvertisingOrTracking { return a.isAdvertisingOrTracking }
            return a.parent < b.parent
        }
        let known = Set(companies.map { $0.parent.lowercased() })
        let possible = (capture?.possibleCompanies ?? []).filter { !known.contains($0.lowercased()) }.sorted()
        var typeKnown: [CompanyCategory: Set<String>] = [:]
        for (category, names) in (capture?.typeKnownDestinations ?? [:]) { typeKnown[category, default: []].formUnion(names) }
        for (category, names) in (report?.typeKnownDestinations ?? [:]) { typeKnown[category, default: []].formUnion(names) }
        let untraced = (capture?.untracedDestinations ?? []).union(report?.untracedDestinations ?? [])
        return AppCard(
            key: key, name: capture?.name ?? report?.name ?? key, company: capture?.company ?? report?.company,
            kind: kind, companies: companies, possibleCompanies: possible, untracedDestinations: untraced.count,
            typeKnown: typeKnown.mapValues(\.count), capture: capture, report: report, members: members)
    }

    /// rule 1: one card per key over both lists
    private static func joined(_ captures: [CaptureAppSummary], _ reports: [ReportAppSummary]) -> [AppCard] {
        var byKey: [String: (CaptureAppSummary?, ReportAppSummary?)] = [:]
        for c in captures { byKey[c.key] = (c, byKey[c.key]?.1) }
        for r in reports { byKey[r.key] = (byKey[r.key]?.0, r) }
        return byKey.map { card(key: $0.key, kind: .app, capture: $0.value.0, report: $0.value.1) }.sorted(by: before)
    }

    public static func build(capture: CaptureSummary?, report: ReportSummary?) -> CombinedSummary {
        var cards = joined(capture?.apps ?? [], report?.apps ?? [])
        let cap = capture?.appleApps, rep = report?.appleApps
        var apple: AppCard?
        if cap != nil || rep != nil {
            let members = joined(cap?.members ?? [], rep?.members ?? [])
            apple = card(key: ReportSummary.appleKey, kind: .appleApps, capture: cap, report: rep, members: members)
            cards.append(apple!)
        }
        var system: AppCard?
        if let s = capture?.system {
            system = card(key: CaptureSummary.systemKey, kind: .system, capture: s, report: nil)
            cards.append(system!)
        }

        // overview: distinct across every card (the Apple members are subsets of the Apple card)
        var companyNames = Set<String>(), adTrackNames = Set<String>(), untraced = Set<String>()
        for c in cards {
            for co in c.companies {
                companyNames.insert(co.parent.lowercased())
                if co.isAdvertisingOrTracking { adTrackNames.insert(co.parent.lowercased()) }
            }
            untraced.formUnion(c.capture?.untracedDestinations ?? [])
            untraced.formUnion(c.report?.untracedDestinations ?? [])
        }
        let appCards = cards.filter { $0.kind == .app }.count
        let captureWindows = (capture?.apps ?? []) + [capture?.appleApps, capture?.system].compactMap { $0 }
        let reportEntries = (report?.apps ?? []) + [report?.appleApps].compactMap { $0 }
        return CombinedSummary(
            cards: cards, noProcess: capture?.noProcess ?? TrafficCount(),
            captureStart: captureWindows.map(\.windowStart).min(), captureEnd: captureWindows.map(\.windowEnd).max(),
            reportStart: reportEntries.compactMap(\.firstSeen).min(), reportEnd: reportEntries.compactMap(\.lastSeen).max(),
            apps: appCards + (apple?.members.count ?? 0), companies: companyNames.count, adTrack: adTrackNames.count,
            untraced: untraced.count,
            curatedVersion: capture?.curatedVersion ?? report?.curatedVersion ?? "",
            trackerListVersion: capture?.trackerListVersion ?? report?.trackerListVersion ?? "")
    }
}
