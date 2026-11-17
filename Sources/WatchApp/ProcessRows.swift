import Attribution
import Flows
import Foundation

// pure grouping of flows (live) or stored tally rows (sessions) into the by-process table

struct ProcessRow: Identifiable, Equatable {
    enum Kind: Equatable { case app, system, unattributed }

    var id: String
    var kind: Kind
    /// "TikTok", "System: mDNSResponder" or "Unattributed"
    var name: String
    var pids: [UInt32] = []
    var packets = 0
    var ipBytes = 0
    /// for system rows: the apps the traffic was made for (mDNSResponder lookups)
    var forApps: [String] = []
}

/// one unit of traffic with its tally: a flow, or one stored tally row
struct TallyInput {
    var tally: [ProcessPair: Int]
    var packets: Int
    var ipBytes: Int
}

let unattributedRowID = "unattributed"

/// groups by Attributor's primary result: an app name, "System: name" or "Unattributed", sorted by bytes.
/// a flow counts for its primary group as a whole. withEmptyUnattributed keeps the Unattributed row
/// present when nothing is unattributed, so the screen never hides it
func groupByProcess(from inputs: [TallyInput], withEmptyUnattributed: Bool = false) -> [ProcessRow] {
    var rows: [String: ProcessRow] = [:]
    var forApps: [String: Set<String>] = [:]
    var pids: [String: Set<UInt32>] = [:]

    for input in inputs {
        let key: String
        var row: ProcessRow
        switch Attributor.attribute(input.tally).primary {
        case .app(let name, let appPids):
            key = "app:" + name
            row = rows[key] ?? ProcessRow(id: key, kind: .app, name: name)
            pids[key, default: []].formUnion(appPids)
        case .system(let name):
            key = "system:" + name
            row = rows[key] ?? ProcessRow(id: key, kind: .system, name: "System: " + name)
        case .onBehalfOf(let app, let via):
            key = "system:" + via
            row = rows[key] ?? ProcessRow(id: key, kind: .system, name: "System: " + via)
            forApps[key, default: []].insert(app)
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
    }
    return rows.values.sorted {
        $0.ipBytes != $1.ipBytes ? $0.ipBytes > $1.ipBytes : $0.name < $1.name
    }
}

func groupByProcess(from flows: [Flow], withEmptyUnattributed: Bool = false) -> [ProcessRow] {
    groupByProcess(
        from: flows.map {
            TallyInput(tally: $0.tally, packets: $0.packetsIn + $0.packetsOut, ipBytes: $0.ipBytesIn + $0.ipBytesOut)
        }, withEmptyUnattributed: withEmptyUnattributed)
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
    var serverName: String?
    var address: String
    var ipBytes: Int
    var attribution: String
}

func describeAttribution(_ result: AttributionResult) -> String {
    var text: String
    switch result.primary {
    case .app(let name, _): text = name
    case .onBehalfOf(let app, let via): text = "\(app) via \(via)"
    case .system(let name): text = "System: \(name)"
    case .unknown: text = "Unknown"
    }
    if result.mixed { text += " (mixed)" }
    return text
}

func topFlows(_ flows: [Flow], limit: Int = 10) -> [FlowLine] {
    flows.sorted { $0.ipBytesIn + $0.ipBytesOut > $1.ipBytesIn + $1.ipBytesOut }
        .prefix(limit)
        .map { flow in
            FlowLine(
                id: flow.id, serverName: flow.serverName,
                address: "\(flow.key.remoteAddress.description):\(flow.key.remotePort)",
                ipBytes: flow.ipBytesIn + flow.ipBytesOut,
                attribution: describeAttribution(Attributor.attribute(flow.tally)))
        }
}

func formatBytes(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}
