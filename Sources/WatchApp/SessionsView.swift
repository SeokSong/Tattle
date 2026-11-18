import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: UUID?
    @State private var detail: SessionDetail?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sessions").font(.largeTitle.bold()).padding([.top, .horizontal], 20).padding(.bottom, 8)
                if model.sessions.isEmpty {
                    Text("No sessions yet").foregroundStyle(.secondary).padding(20)
                    Spacer()
                } else {
                    List(model.sessions, selection: $selected) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened)).fontWeight(.medium)
                            Text(summary(session)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(session.id)
                    }
                }
            }
            .frame(minWidth: 250, idealWidth: 280, maxWidth: 360)

            Group {
                if let detail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Phone traffic: \(formatBytes(detail.grouping.phoneBytes))").font(.headline)
                            Text("Phone traffic by process").font(.headline)
                            ProcessTable(rows: detail.grouping.rows)
                            SetAsideSection(rows: detail.grouping.setAside)
                            Text("Top flows by bytes").font(.headline)
                            FlowTable(flows: detail.flows)
                            Text("Byte totals per process are shared out by packet count from stored flow totals. Each flow is placed in one category as a whole.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("Select a session").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400)
        }
        .onAppear { model.refreshSessions() }
        .onChange(of: selected) { id in detail = id.flatMap { model.detail(for: $0) } }
        .onChange(of: model.sessions) { rows in
            if let selected, !rows.contains(where: { $0.id == selected }) {
                self.selected = nil
                detail = nil
            }
        }
    }

    private func summary(_ session: SessionRow) -> String {
        let duration = session.duration.map(durationText) ?? "unfinished"
        return "\(duration) · \(session.packets) packets · \(session.flows) flows"
    }
}
