import SwiftUI

struct Tile: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }
}

struct ProcessTable: View {
    var rows: [ProcessRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Process").bold()
                Text("PIDs").bold()
                Text("Packets").bold().gridColumnAlignment(.trailing)
                Text("IP bytes").bold().gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { row in
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .italic(row.kind == .unattributed)
                            .foregroundStyle(row.kind == .system ? Color.secondary : Color.primary)
                        if !row.forApps.isEmpty {
                            Text("lookups for " + row.forApps.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let note = row.rawNameNote {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(row.pids.isEmpty ? "unknown" : row.pids.map(String.init).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(row.packets)").monospacedDigit()
                    Text(formatBytes(row.ipBytes)).monospacedDigit()
                }
            }
        }
    }
}

/// the set-aside lines under the phone traffic table: category, bytes, and a toggle to the process rows inside
struct SetAsideSection: View {
    var rows: [ProcessRow]
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not counted as phone traffic").font(.headline)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    } label: {
                        HStack {
                            Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                                .frame(width: 12)
                            Text(row.name)
                            Spacer()
                            Text(formatBytes(row.ipBytes)).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded.contains(row.id) {
                        if row.children.isEmpty {
                            Text("Nothing in this category").foregroundStyle(.secondary).padding(.leading, 20)
                        } else {
                            ProcessTable(rows: row.children).padding(.leading, 20)
                        }
                    }
                }
            }
            Text("Seen on the phone's interface, but not traffic the phone sent to the internet for its apps.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct FlowTable: View {
    var flows: [FlowLine]
    /// flows left out of the table, shown as one "N more flows" line
    var moreFlows = 0
    /// an app filter is on: an empty table then means no connections for that app, not no capture
    var filtered = false
    /// the connection whose detail sheet is open
    @State private var detail: FlowLine?

    var body: some View {
        // one container that stays, so an open detail sheet survives a refresh that empties the table
        Group {
        if flows.isEmpty {
            Text(filtered ? "No connections for this app" : "No flows yet").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Name").bold()
                    Text("Company").bold()
                    Text("Address").bold()
                    Text("App").bold()
                    Text("IP bytes").bold().gridColumnAlignment(.trailing)
                    Text("")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                ForEach(flows) { flow in
                    GridRow {
                        // an sni name is observed; dns and same-address names are secondary and says it may differ
                        VStack(alignment: .leading, spacing: 2) {
                            if let name = flow.hostname {
                                Text(name)
                                    .foregroundStyle(flow.hostnameSource == .sni ? Color.primary : Color.secondary)
                                    .italic(flow.hostnameSource != .sni)
                                    .lineLimit(1)
                                Text(flow.hostnameNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            } else {
                                Text(flow.hostnameNote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .help(flow.hostnameDetail)
                        // a hint is neutral and italic like the name above it; no match says so plainly
                        Text(flow.companyText ?? "")
                            .foregroundStyle(flow.companyLabel?.isPossible == true || flow.companyLabel?.label.isMatched == false
                                ? Color.secondary : Color.primary)
                            .italic(flow.companyLabel?.isPossible == true)
                            .lineLimit(1)
                            .help(flow.companyDetail ?? "")
                        Text(flow.address).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(flow.attribution).lineLimit(1)
                            if let label = flow.setAsideLabel {
                                Text(label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(formatBytes(flow.ipBytes)).monospacedDigit()
                        Button { detail = flow } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless)
                            .help("Connection details")
                    }
                }
                if let fold = FlowRows(lines: [], moreFlows: moreFlows).foldLine {
                    GridRow { Text(fold).foregroundStyle(.secondary).gridCellColumns(6) }
                }
            }
        }
        }
        .sheet(item: $detail) { FlowDetailView(line: $0) }
    }
}

func percentText(_ share: Double?) -> String {
    guard let share else { return "none yet" }
    return String(format: "%.1f%%", share * 100)
}

func durationText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

/// "Gaps: 2 (longest 41 s)"; nil when there were none. a gap is a silence over 5 s, such as a locked phone
func gapText(count: Int, maxGapMs: Int) -> String? {
    guard count > 0 else { return nil }
    return "Gaps: \(count) (longest \((maxGapMs + 500) / 1000) s)"
}

/// "Dropped by the Mac: 12 packets" for a known nonzero count; nil when zero or unknown
func kernelDroppedText(_ count: Int?) -> String? {
    guard let count, count > 0 else { return nil }
    return "Warning: the Mac dropped \(count) packets while capturing, so these totals are too low."
}
