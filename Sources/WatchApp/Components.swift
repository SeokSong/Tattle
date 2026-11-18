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

    var body: some View {
        if flows.isEmpty {
            Text("No flows yet").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Server").bold()
                    Text("Address").bold()
                    Text("App").bold()
                    Text("IP bytes").bold().gridColumnAlignment(.trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                ForEach(flows) { flow in
                    GridRow {
                        // a name here comes from the TLS handshake of this flow, never a guess
                        Text(flow.serverName ?? "name not seen")
                            .foregroundStyle(flow.serverName == nil ? Color.secondary : Color.primary)
                            .lineLimit(1)
                        Text(flow.address).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(flow.attribution).lineLimit(1)
                            if let label = flow.setAsideLabel {
                                Text(label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(formatBytes(flow.ipBytes)).monospacedDigit()
                    }
                }
            }
        }
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
