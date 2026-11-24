import Foundation

/// names the company behind a hostname. immutable and Sendable; callers memoise per distinct
/// hostname with a local dictionary. every answer says which source gave it, and each source can
/// be run on its own so sources can be compared (milestone 3, decision OD2)
public struct CompanyClassifier: Sendable {
    /// the order `classify` tries sources in for the owner field: read from the precedence table, which is
    /// provisional until the agreement experiment decides it. callers that compare sources use
    /// `label(hostname:from:)` instead
    public static var provisionalOrder: [LabelSource] { PrecedenceTable.bundled.order(for: .owner) }

    public let curated: CuratedList
    public let precedence: PrecedenceTable
    public let appleOwners: AppleOwnerTable
    public let trackers: TrackerList

    public init(curated: CuratedList = .bundled, precedence: PrecedenceTable = .bundled, appleOwners: AppleOwnerTable = .bundled, trackers: TrackerList = .bundled) {
        self.curated = curated
        self.precedence = precedence
        self.appleOwners = appleOwners
        self.trackers = trackers
    }

    /// the label by the precedence table (or by `order`, for a caller that fixes its own sources, such as
    /// the curated-only coverage baseline); an explicit unclassified label (source `.none`) when no source
    /// matches. `appleOwner` is the non-empty `domainOwner` of an imported report record
    public func classify(hostname: String, appleOwner: String? = nil, order: [LabelSource]? = nil) -> CompanyLabel {
        if let order {
            for source in order {
                let label = self.label(hostname: hostname, from: source, appleOwner: appleOwner)
                if label.isMatched { return label }
            }
            return unmatched(hostname)
        }
        return resolve(hostname: hostname, appleOwner: appleOwner).label
    }

    /// resolves one name by the precedence table: the owner (company and parent) from the first source of the
    /// owner row that answers and is not skipped by an exception, the category from the first source of the
    /// category row that answers. Apple never gives a category
    public func resolve(hostname: String, appleOwner: String? = nil) -> Resolution {
        var skipped: [SkippedSource] = []
        let ownerRow = precedence.row(for: .owner)
        var winner: CompanyLabel?
        for source in ownerRow.order {
            let label = self.label(hostname: hostname, from: source, appleOwner: appleOwner)
            guard label.isMatched else { continue }
            if let exception = ownerRow.exceptions.first(where: { $0.skip == source && applies($0.when, to: label) }) {
                skipped.append(SkippedSource(source: source, condition: exception.when))
                continue
            }
            winner = label
            break
        }
        var categorySource = LabelSource.none
        var category = CompanyCategory.unclassified
        for source in precedence.row(for: .category).order {
            let label = self.label(hostname: hostname, from: source, appleOwner: appleOwner)
            if label.isMatched, label.category != .unclassified {
                category = label.category
                categorySource = source
                break
            }
        }
        guard let winner else {
            return Resolution(label: unmatched(hostname), skipped: skipped, categorySource: categorySource)
        }
        let label = CompanyLabel(
            hostname: winner.hostname, registrableDomain: winner.registrableDomain, company: winner.company,
            parent: winner.parent, category: category, source: winner.source, rule: winner.rule,
            datasetId: winner.datasetId, datasetVersion: winner.datasetVersion, datasetSHA256: winner.datasetSHA256,
            hostingPlatform: winner.hostingPlatform, relation: winner.relation)
        return Resolution(label: label, skipped: skipped, categorySource: categorySource)
    }

    private func applies(_ condition: PrecedenceCondition, to label: CompanyLabel) -> Bool {
        switch condition {
        case .cdnOperator: label.source == .appleOwner && label.company.map(appleOwners.isCDNOperator) == true
        }
    }

    /// what one source alone says. never consults another source. no match gives the
    /// unclassified label. `.trackerList` answers only for a row with a company
    public func label(hostname: String, from source: LabelSource, appleOwner: String? = nil) -> CompanyLabel {
        let name = Self.normalise(hostname)
        let registrable = registrableDomain(of: name)
        switch source {
        case .curated:
            guard let registrable, let match = curated.lookup(name, registrable: registrable) else { break }
            let (row, rule) = match
            return CompanyLabel(
                hostname: name, registrableDomain: registrable, company: row.company, parent: row.parent,
                category: row.category, source: .curated, rule: rule, datasetId: CuratedList.datasetId,
                datasetVersion: curated.version, datasetSHA256: curated.sha256, hostingPlatform: nil, relation: .unknown)
        case .appleOwner:
            // the report names an owner but gives no category or parent, so neither is invented
            guard let owner = appleOwner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty else { break }
            return CompanyLabel(
                hostname: name, registrableDomain: registrable, company: String(owner.prefix(200)), parent: nil,
                category: .unclassified, source: .appleOwner, rule: .appleOwner, datasetId: nil,
                datasetVersion: nil, datasetSHA256: nil, hostingPlatform: nil, relation: .unknown)
        case .trackerList:
            // a row with no company (its tracker name is only a domain) is not an answer yet: Part 3 decides how
            // its category is shown. until then it is not identified, like no match
            guard let registrable, let (entry, rule) = trackers.lookup(name, registrable: registrable, companyOnly: true),
                  let company = entry.company else { break }
            return CompanyLabel(
                hostname: name, registrableDomain: registrable, company: company, parent: entry.parent ?? company,
                category: entry.category, source: .trackerList, rule: rule, datasetId: TrackerList.datasetId,
                datasetVersion: trackers.version, datasetSHA256: trackers.sha256, hostingPlatform: nil, relation: .unknown)
        case .none:
            break
        }
        return unmatched(name)
    }

    /// every source's answer, for comparing sources. the key is the source that was asked
    public func labelsBySource(hostname: String, appleOwner: String? = nil) -> [LabelSource: CompanyLabel] {
        var out: [LabelSource: CompanyLabel] = [:]
        for source in [LabelSource.curated, .trackerList, .appleOwner] {
            out[source] = label(hostname: hostname, from: source, appleOwner: appleOwner)
        }
        return out
    }

    private func unmatched(_ hostname: String) -> CompanyLabel {
        let name = Self.normalise(hostname)
        let found = registrable(of: name, in: .bundled)
        return CompanyLabel(
            hostname: name, registrableDomain: found?.domain, company: nil, parent: nil,
            category: .unclassified, source: .none, rule: .noMatch, datasetId: nil, datasetVersion: nil,
            datasetSHA256: nil, hostingPlatform: found?.platform, relation: .unknown)
    }

    private static func normalise(_ hostname: String) -> String {
        var name = hostname.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }
}
