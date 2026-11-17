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
                        Text(flow.attribution).lineLimit(1)
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
