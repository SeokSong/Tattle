import Attribution
import Companies
import Flows
import Foundation

// read time only, never on the packet path.
// port 443 only: the same base as the quality report and `Coverage`.
// hints never enter `companies` or the counts.

public enum SummaryBuilder {
    public static let port = Coverage.port

    private struct Accumulator {
        var key: String
        var name: String
        var company: String?
        var identified = TrafficCount()
        var notIdentified = TrafficCount()
        var hinted = TrafficCount()
        var unseen: [UnnamedReason: TrafficCount] = [:]
        var parents: [String: ParentAcc] = [:]
        var possible = Set<String>()
        var unnamed: [CompanyCategory: Set<String>] = [:]
        var start: Date
        var end: Date
    }

    private struct ParentAcc {
        var brands = Set<String>()
        var categories = Set<CompanyCategory>()
        var relation: LabelRelation = .unknown
        var traffic = TrafficCount()
    }

    private static func add(_ count: inout TrafficCount, _ bytes: Int) {
        count.connections += 1
        count.bytes += bytes
    }

    public static func build(
        flows: [Flow], index: HostnameIndex, classifier: CompanyClassifier = CompanyClassifier(),
        apps: AppTable = .bundled
    ) -> CaptureSummary {
        var cache = LabelCache(classifier: classifier)
        var entries: [String: Accumulator] = [:]
        var noProcess = TrafficCount()
        var excluded: [TrafficCategory: TrafficCount] = [.deviceLink: TrafficCount(), .localNetwork: TrafficCount()]

        for flow in flows where flow.key.remotePort == port {
            let bytes = flow.ipBytesIn + flow.ipBytesOut
            let category = Classifier.classify(flow).category
            let key: String, name: String, company: String?
            switch category {
            case .deviceLink, .localNetwork:
                add(&excluded[category, default: TrafficCount()], bytes)
                continue
            case .unknown:
                add(&noProcess, bytes)
                continue
            case .system:
                key = CaptureSummary.systemKey
                name = CaptureSummary.systemName
                company = CaptureSummary.systemCompany
            case .app, .helper:
                let raw: String
                switch Attributor.attribute(flow.tally).primary {
                case .app(let n, _): raw = n
                case .onBehalfOf(let n, _): raw = n
                default:
                    // not expected for app or helper traffic; counted as no process info so no byte is lost
                    add(&noProcess, bytes)
                    continue
                }
                if let row = apps.row(forProcessName: raw) {
                    key = row.bundleId
                    name = row.displayName
                    company = row.company
                } else {
                    let display = ProcessNames.displayName(raw)
                    key = "process:" + display
                    name = display
                    company = nil
                }
            }

            var entry = entries[key] ?? Accumulator(
                key: key, name: name, company: company, start: flow.firstSeen, end: flow.lastSeen)
            entry.start = min(entry.start, flow.firstSeen)
            entry.end = max(entry.end, flow.lastSeen)

            if case .unnamed(let reason) = index.outcome(for: flow) {
                add(&entry.unseen[reason, default: TrafficCount()], bytes)
            } else if let result = FlowLabels.label(for: flow, index: index, cache: &cache, appCompany: company) {
                let label = result.label
                if result.isPossible {
                    add(&entry.hinted, bytes)
                    if label.isMatched, let parent = label.parent ?? label.company { entry.possible.insert(parent) }
                } else if label.isMatched {
                    add(&entry.identified, bytes)
                    if let parent = label.parent ?? label.company {
                        var p = entry.parents[parent] ?? ParentAcc()
                        if let brand = label.company { p.brands.insert(brand) }
                        p.categories.insert(label.category)
                        p.relation = label.relation
                        add(&p.traffic, bytes)
                        entry.parents[parent] = p
                    }
                } else {
                    add(&entry.notIdentified, bytes)
                    if let registrable = label.registrableDomain,
                       let (row, _) = classifier.trackers.lookup(label.hostname, registrable: registrable),
                       row.company == nil, row.category != .unclassified {
                        entry.unnamed[row.category, default: []].insert(registrable)
                    }
                }
            } else {
                // a named flow whose observed server name had ECH: it has no label and matches neither
                // identified nor not identified, so its bytes are unseen (the name is hidden)
                add(&entry.unseen[.echHidden, default: TrafficCount()], bytes)
            }
            entries[key] = entry
        }

        func finish(_ e: Accumulator) -> CaptureAppSummary {
            let companies = e.parents.map { parent, p in
                CompanyEntry(
                    parent: parent, brands: p.brands.sorted(),
                    categories: CompanyCategory.allCases.filter { p.categories.contains($0) },
                    relation: p.relation, traffic: p.traffic)
            }.sorted { a, b in
                let ao = a.relation == .sameCompanyAsApp, bo = b.relation == .sameCompanyAsApp
                if ao != bo { return ao }
                if a.isAdvertisingOrTracking != b.isAdvertisingOrTracking { return a.isAdvertisingOrTracking }
                return a.parent < b.parent
            }
            var unseen: [UnnamedReason: TrafficCount] = [:]
            for reason in UnnamedReason.allCases { unseen[reason] = e.unseen[reason] ?? TrafficCount() }
            let total = e.identified.bytes + e.notIdentified.bytes + e.hinted.bytes + unseen.values.reduce(0) { $0 + $1.bytes }
            return CaptureAppSummary(
                key: e.key, name: e.name, company: e.company, companies: companies,
                possibleCompanies: e.possible.subtracting(e.parents.keys).sorted(),
                unnamedCategories: e.unnamed.mapValues(\.count),
                identified: e.identified, notIdentified: e.notIdentified, hinted: e.hinted, unseen: unseen,
                coverage: CoverageRatio(numerator: e.identified.bytes, denominator: total),
                windowStart: e.start, windowEnd: e.end)
        }

        let system = entries[CaptureSummary.systemKey].map(finish)
        let appSummaries = entries.values.filter { $0.key != CaptureSummary.systemKey }.map(finish).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
        }
        return CaptureSummary(
            apps: appSummaries, system: system, noProcess: noProcess, excluded: excluded,
            curatedVersion: classifier.curated.version, trackerListVersion: classifier.trackers.version)
    }
}
