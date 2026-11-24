import Companies
import Foundation

// read time only. the report has contacts (hits), never bytes, and no type here holds a domain name:
// only counts, parents, brands and categories, so a bare IP address can never be shown.

/// one stored report contact, as the app reads it from the store (Summary does not import Storage)
public struct ReportContactInput: Sendable, Equatable {
    public let appId: String
    public let domain: String
    public let domainOwner: String?
    public let hits: Int
    public let firstSeen: Date?
    public let lastSeen: Date?

    public init(appId: String, domain: String, domainOwner: String?, hits: Int, firstSeen: Date?, lastSeen: Date?) {
        self.appId = appId
        self.domain = domain
        self.domainOwner = domainOwner
        self.hits = hits
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// distinct domains and Apple's contact counts (hits). the report has no bytes
public struct DomainCount: Sendable, Equatable {
    public var domains: Int
    public var contacts: Int

    public init(domains: Int = 0, contacts: Int = 0) {
        self.domains = domains
        self.contacts = contacts
    }
}

public struct ReportCompanyEntry: Sendable, Equatable {
    public let parent: String
    /// distinct, sorted with `<`
    public let brands: [String]
    /// distinct, in `CompanyCategory.allCases` order, never `.unclassified`
    public let categories: [CompanyCategory]
    public let relation: LabelRelation
    public let count: DomainCount
    public var isAdvertisingOrTracking: Bool { categories.contains { $0.isAdvertisingOrTracking } }

    public init(parent: String, brands: [String], categories: [CompanyCategory], relation: LabelRelation, count: DomainCount) {
        self.parent = parent
        self.brands = brands
        self.categories = categories
        self.relation = relation
        self.count = count
    }
}

public struct ReportAppSummary: Sendable, Equatable {
    /// the bundle id, or "apple" for the merged Apple apps entry
    public let key: String
    /// the app table's display name for an exact row; else the bundle id; "Apple apps" for the merged entry
    public let name: String
    /// the app table row's company (an exact or a prefix row); nil when the table does not know the app
    public let company: String?
    /// own company first, then advertising or tracking, then the rest; ties by parent with `<`
    public let companies: [ReportCompanyEntry]
    public var namedCompanies: Int { companies.count }
    public var adTrackCompanies: Int { companies.filter(\.isAdvertisingOrTracking).count }
    /// distinct registrable domains per category for names known to the AdGuard list only by category
    public let unnamedCategories: [CompanyCategory: Int]
    /// every distinct domain of the entry is in exactly one of the two
    public let identified: DomainCount
    public let notIdentified: DomainCount
    /// identified domains over all distinct domains
    public let coverage: CoverageRatio
    public let firstSeen: Date?
    public let lastSeen: Date?
    /// the merged Apple apps entry only: one summary per Apple app, sorted like `apps`; empty otherwise
    public let members: [ReportAppSummary]

    public init(
        key: String, name: String, company: String?, companies: [ReportCompanyEntry],
        unnamedCategories: [CompanyCategory: Int], identified: DomainCount, notIdentified: DomainCount,
        coverage: CoverageRatio, firstSeen: Date?, lastSeen: Date?, members: [ReportAppSummary]
    ) {
        self.key = key
        self.name = name
        self.company = company
        self.companies = companies
        self.unnamedCategories = unnamedCategories
        self.identified = identified
        self.notIdentified = notIdentified
        self.coverage = coverage
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.members = members
    }
}

public struct ReportSummary: Sendable, Equatable {
    /// every app except Apple's own, sorted by name like 3.1's `CaptureSummary.apps` (the same non-localized, case-insensitive compare), then key
    public let apps: [ReportAppSummary]
    /// nil when no Apple app is in the report
    public let appleApps: ReportAppSummary?
    public let curatedVersion: String
    public let trackerListVersion: String
    public static let appleKey = "apple"
    public static let appleName = "Apple apps"
    public static let appleCompany = "Apple"
    public static let applePrefix = "com.apple."

    public init(apps: [ReportAppSummary], appleApps: ReportAppSummary?, curatedVersion: String, trackerListVersion: String) {
        self.apps = apps
        self.appleApps = appleApps
        self.curatedVersion = curatedVersion
        self.trackerListVersion = trackerListVersion
    }
}

public enum ReportSummaryBuilder {
    /// one (app, domain) after the imports are combined
    private struct Combined {
        var domain: String
        var owner: String?
        var hits = 0
        var first: Date?
        var last: Date?

        mutating func add(owner newOwner: String?, hits newHits: Int, first f: Date?, last l: Date?) {
            if owner == nil, let trimmed = newOwner?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                owner = trimmed
            }
            hits += newHits
            if let f { first = first.map { min($0, f) } ?? f }
            if let l { last = last.map { max($0, l) } ?? l }
        }
    }

    private struct ParentAcc {
        /// the spelling shown: a list's spelling wins over an Apple owner string that differs only in case
        var name: String
        var fromList: Bool
        var brands = Set<String>()
        var categories = Set<CompanyCategory>()
        var relation: LabelRelation = .unknown
        var count = DomainCount()
    }

    private struct LabelKey: Hashable {
        var domain: String
        var owner: String?
    }

    public static func build(
        contacts: [ReportContactInput], classifier: CompanyClassifier = CompanyClassifier(), apps: AppTable = .bundled
    ) -> ReportSummary {
        // 1. combine by (app id, domain), keeping input order. the app id is compared lowercased (the app table
        // does the same) and shown as first written; the domain is lowercased without a trailing dot, the form the
        // classifier uses, so "ads.test" and "ads.test." are one domain
        var order: [String] = []
        var spelling: [String: String] = [:]
        var byApp: [String: [String: Combined]] = [:]
        var domainOrder: [String: [String]] = [:]
        for c in contacts {
            let app = c.appId.lowercased()
            if byApp[app] == nil { order.append(app); spelling[app] = c.appId }
            var d = c.domain.lowercased()
            if d.hasSuffix(".") { d.removeLast() }
            var rows = byApp[app] ?? [:]
            if rows[d] == nil { domainOrder[app, default: []].append(d) }
            var row = rows[d] ?? Combined(domain: d)
            row.add(owner: c.domainOwner, hits: c.hits, first: c.firstSeen, last: c.lastSeen)
            rows[d] = row
            byApp[app] = rows
        }

        var cache: [LabelKey: CompanyLabel] = [:]
        func label(_ row: Combined) -> CompanyLabel {
            let key = LabelKey(domain: row.domain, owner: row.owner)
            if let hit = cache[key] { return hit }
            let l = classifier.classify(hostname: row.domain, appleOwner: row.owner)
            cache[key] = l
            return l
        }

        func summarize(key: String, name: String, company: String?, rows: [Combined], members: [ReportAppSummary]) -> ReportAppSummary {
            var identified = DomainCount(), notIdentified = DomainCount()
            var parents: [String: ParentAcc] = [:]
            var unnamed: [CompanyCategory: Set<String>] = [:]
            var first: Date?, last: Date?
            for row in rows {
                if let f = row.first { first = first.map { min($0, f) } ?? f }
                if let l = row.last { last = last.map { max($0, l) } ?? l }
                let l = label(row)
                let parent: String? = l.source == .appleOwner
                    ? l.company.map { classifier.appleOwners.comparableParent(forOwner: $0) }
                    : (l.parent ?? l.company)
                if l.isMatched, let parent {
                    identified.domains += 1
                    identified.contacts += row.hits
                    // one company per parent ignoring case, as `comparableParent` and `AppTable.relation` compare
                    let key = parent.lowercased()
                    let fromList = l.source != .appleOwner
                    var p = parents[key] ?? ParentAcc(name: parent, fromList: fromList)
                    if fromList && !p.fromList { p.name = parent; p.fromList = true }
                    if let brand = l.company { p.brands.insert(brand) }
                    if l.category != .unclassified { p.categories.insert(l.category) }
                    p.relation = AppTable.relation(appCompany: company, labelParent: parent)
                    p.count.domains += 1
                    p.count.contacts += row.hits
                    parents[key] = p
                } else {
                    notIdentified.domains += 1
                    notIdentified.contacts += row.hits
                    if let registrable = l.registrableDomain,
                       let tracker = classifier.trackers.unnamedCategoryRow(l.hostname, registrable: registrable) {
                        unnamed[tracker.category, default: []].insert(registrable)
                    }
                }
            }
            let companies = parents.values.map { p in
                ReportCompanyEntry(
                    parent: p.name, brands: p.brands.sorted(),
                    categories: CompanyCategory.allCases.filter { p.categories.contains($0) },
                    relation: p.relation, count: p.count)
            }.sorted { a, b in
                let ao = a.relation == .sameCompanyAsApp, bo = b.relation == .sameCompanyAsApp
                if ao != bo { return ao }
                if a.isAdvertisingOrTracking != b.isAdvertisingOrTracking { return a.isAdvertisingOrTracking }
                return a.parent < b.parent
            }
            return ReportAppSummary(
                key: key, name: name, company: company, companies: companies,
                unnamedCategories: unnamed.mapValues(\.count), identified: identified, notIdentified: notIdentified,
                coverage: CoverageRatio(numerator: identified.domains, denominator: identified.domains + notIdentified.domains),
                firstSeen: first, lastSeen: last, members: members)
        }

        func sorted(_ list: [ReportAppSummary]) -> [ReportAppSummary] {
            list.sorted {
                // a non-localized compare: the same order on every Mac. (with the en_US_POSIX locale, Foundation ignores .caseInsensitive)
                let order = $0.name.compare($1.name, options: [.caseInsensitive, .numeric])
                return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
            }
        }

        var others: [ReportAppSummary] = []
        var appleMembers: [ReportAppSummary] = []
        var appleRows: [String: Combined] = [:]
        var appleDomainOrder: [String] = []
        for id in order {
            let rows = (domainOrder[id] ?? []).compactMap { byApp[id]?[$0] }
            let shown = spelling[id] ?? id
            let row = apps.row(forBundleId: id)
            let name = row.flatMap { $0.bundleId.hasSuffix(".") ? nil : $0.displayName } ?? shown
            let summary = summarize(key: shown, name: name, company: row?.company, rows: rows, members: [])
            if id.lowercased().hasPrefix(ReportSummary.applePrefix) {
                appleMembers.append(summary)
                for r in rows {
                    if appleRows[r.domain] == nil { appleDomainOrder.append(r.domain) }
                    var merged = appleRows[r.domain] ?? Combined(domain: r.domain)
                    merged.add(owner: r.owner, hits: r.hits, first: r.first, last: r.last)
                    appleRows[r.domain] = merged
                }
            } else {
                others.append(summary)
            }
        }
        let apple: ReportAppSummary? = appleMembers.isEmpty ? nil : summarize(
            key: ReportSummary.appleKey, name: ReportSummary.appleName, company: ReportSummary.appleCompany,
            rows: appleDomainOrder.compactMap { appleRows[$0] }, members: sorted(appleMembers))
        return ReportSummary(
            apps: sorted(others), appleApps: apple,
            curatedVersion: classifier.curated.version, trackerListVersion: classifier.trackers.version)
    }
}
