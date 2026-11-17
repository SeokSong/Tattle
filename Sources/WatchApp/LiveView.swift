import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if case .capturing(let since) = model.captureState {
                CaptureBar(since: since)
                content
            } else if model.captureState == .stopping {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Stopping...")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Text("Not capturing").font(.title2.bold())
                    Text("Start a capture from Connect. Finished captures are in Sessions.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Live · this session").font(.headline).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Tile(title: "Packets", value: "\(model.liveStats.packets)")
                    Tile(title: "Flows", value: "\(model.liveStats.flowsOpened)")
                    Tile(title: "Unattributed", value: percentText(unattributedShare(model.processRows)))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Traffic by process").font(.headline)
                    ProcessTable(rows: model.processRows.isEmpty
                        ? groupByProcess(from: [] as [TallyInput], withEmptyUnattributed: true) : model.processRows)
                    Text("Counts are packets and IP bytes seen on the phone's interface.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top 10 flows by bytes").font(.headline)
                    FlowTable(flows: model.topFlowLines)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CaptureBar: View {
    @EnvironmentObject private var model: AppModel
    var since: Date

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(Color.white).frame(width: 10, height: 10)
            Text("Capturing").fontWeight(.semibold)
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(durationText(context.date.timeIntervalSince(since))).monospacedDigit()
            }
            Text(model.interfaceName ?? "starting interface").opacity(0.85)
            if model.diagnosticActive {
                Text("Diagnostic capture on: raw packets are being saved")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.3)))
            }
            Spacer()
            Button("Stop") { model.stopCapture() }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.red)
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: .command)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.red)
    }
}
