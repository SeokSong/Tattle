import Foundation

/// names the company behind a hostname. immutable and Sendable; callers memoise per distinct
/// hostname with a local dictionary. every answer says which source gave it, and each source can
/// be run on its own so sources can be compared (milestone 3, decision OD2)
public struct CompanyClassifier: Sendable {
    /// the order `classify` tries sources in. provisional: the order is decided by the agreement
    /// experiment, so callers that compare sources use `label(hostname:from:)` instead
    public static let provisionalOrder: [LabelSource] = [.curated, .appleOwner]

    public let curated: CuratedList

    public init(curated: CuratedList = .bundled) {
        self.curated = curated
    }

    /// the first source in `order` that matches; an explicit unclassified label (source `.none`)
    /// when none does. `appleOwner` is the non-empty `domainOwner` of an imported report record
    public func classify(hostname: String, appleOwner: String? = nil, order: [LabelSource] = CompanyClassifier.provisionalOrder) -> CompanyLabel {
        for source in order {
            let label = self.label(hostname: hostname, from: source, appleOwner: appleOwner)
            if label.isMatched { return label }
        }
        return unmatched(hostname)
    }

    /// what one source alone says. never consults another source. no match gives the
    /// unclassified label. `.trackerList` has no data yet and never matches
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
                datasetVersion: curated.version, datasetSHA256: curated.sha256, relation: .unknown)
        case .appleOwner:
            // the report names an owner but gives no category or parent, so neither is invented
            guard let owner = appleOwner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty else { break }
            return CompanyLabel(
                hostname: name, registrableDomain: registrable, company: String(owner.prefix(200)), parent: nil,
                category: .unclassified, source: .appleOwner, rule: .appleOwner, datasetId: nil,
                datasetVersion: nil, datasetSHA256: nil, relation: .unknown)
        case .trackerList, .none:
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
        return CompanyLabel(
            hostname: name, registrableDomain: registrableDomain(of: name), company: nil, parent: nil,
            category: .unclassified, source: .none, rule: .noMatch, datasetId: nil, datasetVersion: nil,
            datasetSHA256: nil, relation: .unknown)
    }

    private static func normalise(_ hostname: String) -> String {
        var name = hostname.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }
}
