import SwiftUI

/// the app filter above a connection table (5.1): "All apps" or one app, with "Showing 1 of N apps" when filtered
struct AppFilterPicker: View {
    @Binding var selection: String?
    let names: [String]

    var body: some View {
        HStack(spacing: 12) {
            Picker("App", selection: $selection) {
                Text("All apps").tag(String?.none)
                ForEach(names, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: 280)
            if let caption = filterCaption(app: selection, appCount: names.count) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// one connection's details: where the name and the company came from, and the numbers (5.1)
struct FlowDetailView: View {
    let line: FlowLine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(line.detailRows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
