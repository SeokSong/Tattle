import Attribution
import Companies
import Domains
import Flows
import Foundation
import Summary

// pure grouping of flows (live) or stored tally rows (sessions) into the by-process table

struct ProcessRow: Identifiable, Equatable {
    enum Kind: Equatable { case app, system, unattributed, setAside }

    var id: String
    var kind: Kind
    /// display name: "TikTok", "System: mDNSResponder" or "Unattributed". for a set-aside row the category label
    var name: String
    /// the names the kernel reported, before display names are applied (shown in the detail line when different)
    var rawNames: [String] = []
    var pids: [UInt32] = []
    var packets = 0
    var ipBytes = 0
    /// for system rows: the apps the traffic was made for (mDNSResponder lookups)
    var forApps: [String] = []
    /// set-aside rows only: the category and the process rows inside it
    var category: TrafficCategory?
    var children: [ProcessRow] = []

    /// raw process name when it differs from the display name
    var rawNameNote: String? {
        let shown = rawNames.filter { $0 != name && "System: " + $0 != name }
        return shown.isEmpty ? nil : "process name: " + shown.joined(separator: ", ")
    }
}

/// one unit of traffic with its tally: a flow, or one stored tally row of a flow
struct TallyInput {
    var tally: [ProcessPair: Int]
    var packets: Int
    var ipBytes: Int
    /// the category of the whole flow this input belongs to
    var category: TrafficCategory

    init(tally: [ProcessPair: Int], packets: Int, ipBytes: Int, category: TrafficCategory) {
        self.tally = tally
        self.packets = packets
        self.ipBytes = ipBytes
        self.category = category
    }

    init(flow: Flow) {
        self.init(
            tally: flow.tally, packets: flow.packetsIn + flow.packetsOut, ipBytes: flow.ipBytesIn + flow.ipBytesOut,
            category: Classifier.classify(flow).category)
    }
}

/// the by-process table split in two: phone traffic rows, and the traffic set aside (USB link, local network)
struct ProcessGrouping: Equatable {
    /// phone traffic by process
    var rows: [ProcessRow] = []
    /// one row per set-aside category, always both, each with its process rows in `children`
    var setAside: [ProcessRow] = []

    var phonePackets: Int { rows.reduce(0) { $0 + $1.packets } }
    var phoneBytes: Int { rows.reduce(0) { $0 + $1.ipBytes } }
    var setAsideBytes: Int { setAside.reduce(0) { $0 + $1.ipBytes } }
}

/// the categories listed under "Not counted as phone traffic", in display order
let setAsideCategories: [TrafficCategory] = TrafficCategory.allCases.filter { !$0.isPhoneTraffic }

let unattributedRowID = "unattributed"

/// groups by Attributor's primary result: an app name, "System: name" or "Unattributed", sorted by bytes.
/// a flow counts for its primary group as a whole. inputs whose category is not phone traffic go to `setAside`,
/// grouped by category and then by process. withEmptyUnattributed keeps the Unattributed row
/// present when nothing is unattributed, so the screen never hides it
func groupByProcess(from inputs: [TallyInput], withEmptyUnattributed: Bool = false) -> ProcessGrouping {
    let phone = inputs.filter { $0.category.isPhoneTraffic }
    var grouping = ProcessGrouping(rows: groupRows(phone, withEmptyUnattributed: withEmptyUnattributed))
    for category in setAsideCategories {
        let inside = inputs.filter { $0.category == category }
        let children = groupRows(inside, withEmptyUnattributed: false)
        grouping.setAside.append(
            ProcessRow(
                id: "setAside:" + category.rawValue, kind: .setAside, name: category.label,
                packets: inside.reduce(0) { $0 + $1.packets }, ipBytes: inside.reduce(0) { $0 + $1.ipBytes },
                category: category, children: children))
    }
    return grouping
}

private func groupRows(_ inputs: [TallyInput], withEmptyUnattributed: Bool) -> [ProcessRow] {
    var rows: [String: ProcessRow] = [:]
    var forApps: [String: Set<String>] = [:]
    var pids: [String: Set<UInt32>] = [:]
    var raws: [String: Set<String>] = [:]

    for input in inputs {
        let key: String
        var row: ProcessRow
        switch Attributor.attribute(input.tally).primary {
        case .app(let name, let appPids):
            key = "app:" + name
            row = rows[key] ?? ProcessRow(id: key, kind: .app, name: ProcessNames.displayName(name))
            pids[key, default: []].formUnion(appPids)
            raws[key, default: []].insert(name)
        case .system(let name):
            key = "system:" + name
            row = rows[key] ?? ProcessRow(id: key, kind: .system, name: "System: " + ProcessNames.displayName(name))
            raws[key, default: []].insert(name)
        case .onBehalfOf(let app, let via):
            key = "system:" + via
            row = rows[key] ?? ProcessRow(id: key, kind: .system, name: "System: " + ProcessNames.displayName(via))
            forApps[key, default: []].insert(ProcessNames.displayName(app))
            raws[key, default: []].insert(via)
        case .unknown:
            key = unattributedRowID
            row = rows[key] ?? ProcessRow(id: key, kind: .unattributed, name: "Unattributed")
        }
        row.packets += input.packets
        row.ipBytes += input.ipBytes
        rows[key] = row
    }

    if withEmptyUnattributed, rows[unattributedRowID] == nil {
        rows[unattributedRowID] = ProcessRow(id: unattributedRowID, kind: .unattributed, name: "Unattributed")
    }
    for key in rows.keys {
        rows[key]?.pids = (pids[key] ?? []).sorted()
        rows[key]?.forApps = (forApps[key] ?? []).sorted()
        rows[key]?.rawNames = (raws[key] ?? []).sorted()
    }
    return rows.values.sorted {
        $0.ipBytes != $1.ipBytes ? $0.ipBytes > $1.ipBytes : $0.name < $1.name
    }
}

func groupByProcess(from flows: [Flow], withEmptyUnattributed: Bool = false) -> ProcessGrouping {
    groupByProcess(from: flows.map { TallyInput(flow: $0) }, withEmptyUnattributed: withEmptyUnattributed)
}

/// session detail: one input per stored tally row, with the flow's ip bytes shared out by packet count
/// (the flow only stores byte totals) and the category of the flow the row belongs to
func tallyInputs(from flows: [Flow]) -> [TallyInput] {
    var inputs: [TallyInput] = []
    for flow in flows {
        let category = Classifier.classify(flow).category
        let bytes = flow.ipBytesIn + flow.ipBytesOut
        let total = max(flow.packetsIn + flow.packetsOut, 1)
        for (pair, count) in flow.tally {
            inputs.append(
                TallyInput(
                    tally: [pair: count], packets: count,
                    ipBytes: Int((Double(bytes) * Double(count) / Double(total)).rounded()), category: category))
        }
    }
    return inputs
}

/// the share of packets in the Unattributed row, nil when there are no packets
func unattributedShare(_ rows: [ProcessRow]) -> Double? {
    let total = rows.reduce(0) { $0 + $1.packets }
    guard total > 0 else { return nil }
    let lost = rows.first { $0.kind == .unattributed }?.packets ?? 0
    return Double(lost) / Double(total)
}

// MARK: - flow lines

struct FlowLine: Identifiable {
    var id: UUID
    /// the resolved name, nil when the flow has none
    var hostname: String?
    var hostnameSource: HostnameSource?
    /// seconds from the dns answer to the flow's first packet; dns names only
    var dnsAgeSeconds: Double?
    /// no name: the reason it has none (shared with the report)
    var unnamedReason: UnnamedReason?
    var address: String
    var ipBytes: Int
    var attribution: String
    /// the category label, set only for flows that are not phone traffic
    var setAsideLabel: String?
    /// the company behind the name; nil when the flow has no name (the reason is shown instead)
    var companyLabel: FlowLabel?

    /// the company cell: the company and one category word, "Possible: ..." when the name is only a
    /// hint, "Not identified" when no source knows the name. nil for a flow with no name. the source
    /// and dataset version are not on the row, see `companyDetail`
    var companyText: String? {
        guard let companyLabel else { return nil }
        let label = companyLabel.label
        guard label.isMatched, let company = label.company else { return "Not identified" }
        var text = company
        if label.category != .unclassified { text += " · " + label.category.label }
        return companyLabel.isPossible ? "Possible: " + text : text
    }

    /// tooltip for the company cell: where the answer came from
    var companyDetail: String? {
        guard let companyLabel else { return nil }
        let label = companyLabel.label
        guard label.isMatched else { return "No company is listed for this name" }
        var text = "Company list"
        if let version = label.datasetVersion, !version.isEmpty { text += " version " + version }
        if label.source == .appleOwner { text = "Owner named in the imported report" }
        if companyLabel.isPossible { text += ". The name is a hint and may belong to another service on the same server" }
        return text
    }

    /// the text under or instead of the name in a table cell: the source, or the reason
    var hostnameNote: String {
        if let hostnameSource { return hostnameSource.shortLabel }
        return (unnamedReason ?? .noDNSMatch).label
    }

    /// the full sentence for help text and details, with the dns answer's age
    var hostnameDetail: String {
        guard let hostnameSource else { return (unnamedReason ?? .noDNSMatch).label }
        var text = hostnameSource.label
        if hostnameSource == .dns, let age = dnsAgeSeconds {
            text += ". The DNS answer came \(String(format: "%.1f", age)) s before the connection"
        }
        return text
    }
}

func describeAttribution(_ result: AttributionResult) -> String {
    var text: String
    switch result.primary {
    case .app(let name, _): text = ProcessNames.displayName(name)
    case .onBehalfOf(let app, let via): text = "\(ProcessNames.displayName(app)) via \(ProcessNames.displayName(via))"
    case .system(let name): text = "System: \(ProcessNames.displayName(name))"
    case .unknown: text = "Unknown"
    }
    if result.mixed { text += " (mixed)" }
    return text
}

/// builds the hostname index once, then looks up each of the shown flows. `makeIndex` is a seam for tests
func topFlows(
    _ flows: [Flow], observations: [DomainObservation] = [], limit: Int = 10,
    classifier: CompanyClassifier = CompanyClassifier(),
    makeIndex: ([DomainObservation], [Flow]) -> HostnameIndex = { HostnameIndex($0, flows: $1) }
) -> [FlowLine] {
    let index = makeIndex(observations, flows)
    // one label per distinct hostname for this refresh; dropped when the rows are built
    var cache = LabelCache(classifier: classifier)
    return flows.sorted { $0.ipBytesIn + $0.ipBytesOut > $1.ipBytesIn + $1.ipBytesOut }
        .prefix(limit)
        .map { flow in
            let category = Classifier.classify(flow).category
            var line = FlowLine(
                id: flow.id,
                address: "\(flow.key.remoteAddress.description):\(flow.key.remotePort)",
                ipBytes: flow.ipBytesIn + flow.ipBytesOut,
                attribution: describeAttribution(Attributor.attribute(flow.tally)),
                setAsideLabel: category.isPhoneTraffic ? nil : category.label)
            line.companyLabel = FlowLabels.label(for: flow, index: index, cache: &cache)
            switch index.outcome(for: flow) {
            case .named(let resolved):
                line.hostname = resolved.name
                line.hostnameSource = resolved.source
                line.dnsAgeSeconds = resolved.dnsAgeSeconds
            case .unnamed(let reason):
                line.unnamedReason = reason
            }
            return line
        }
}

/// the flows shown in a list plus how many were left out. a fold line says "N more flows" so a long
/// session never builds an unbounded list
struct FlowRows {
    /// the biggest flows by bytes, at most `limit`
    var lines: [FlowLine]
    /// flows not shown; the fold line stands for them
    var moreFlows: Int

    /// "N more flows", nil when everything is shown
    var foldLine: String? {
        moreFlows > 0 ? "\(moreFlows) more flow\(moreFlows == 1 ? "" : "s")" : nil
    }
}

/// at most `liveRowLimit` rows by default; the live screen passes its own smaller limit
let liveRowLimit = 500

func flowRows(
    _ flows: [Flow], observations: [DomainObservation] = [], limit: Int = liveRowLimit,
    classifier: CompanyClassifier = CompanyClassifier(),
    makeIndex: ([DomainObservation], [Flow]) -> HostnameIndex = { HostnameIndex($0, flows: $1) }
) -> FlowRows {
    FlowRows(
        lines: topFlows(flows, observations: observations, limit: limit, classifier: classifier, makeIndex: makeIndex),
        moreFlows: max(0, flows.count - limit))
}

func formatBytes(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}
