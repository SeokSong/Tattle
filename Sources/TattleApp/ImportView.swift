import AppKit
import SwiftUI

// the Import screen: setup text, a file picker, the result of the last import and the stored imports.
// the picker is an NSOpenPanel so the user chooses the file; the app never remembers its path.

struct ImportView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ImportModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import an App Privacy Report").font(.title2.bold())
                Text(ImportText.setup).font(.callout)
                Text(ImportText.originalFileNotice).font(.callout).fontWeight(.medium)
                Text(ImportText.retention(days: app.retentionDays)).font(.callout).foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Choose report file...") { choose() }
                        .disabled(model.isRunning)
                    if model.isRunning {
                        ProgressView().controlSize(.small)
                        Text("Reading the report...").foregroundStyle(.secondary)
                    }
                }

                switch model.state {
                case .idle, .running: EmptyView()
                case .failed(let message): FailureBox(message: message)
                case .done(let card): CardBox(card: card, dismiss: { model.dismissResult() })
                }

                Divider()
                Text("Imported reports").font(.headline)
                ImportListView(model: model)
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the App Privacy Report file you saved"
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url { model.start(file: url) }
    }
}

private struct FailureBox: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CardBox: View {
    let card: ImportCard
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(card.headline, systemImage: card.kind == .stored ? "checkmark.circle" : "info.circle")
                .fontWeight(.medium)
            if let warning = card.warning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(card.details, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            Button("Dismiss", action: dismiss).controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}

/// the stored imports with a delete button each; used on the Import screen and in Settings
struct ImportListView: View {
    @ObservedObject var model: ImportModel
    @State private var pending: ImportItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.listError { Text(error).foregroundStyle(.red) }
            if model.items.isEmpty {
                Text("No reports imported.").foregroundStyle(.secondary)
            }
            ForEach(model.items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.periodText(start: item.periodStart, end: item.periodEnd)).fontWeight(.medium)
                        Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete...", role: .destructive) { pending = item }
                }
            }
        }
        .confirmationDialog(
            "Delete this imported report?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { item in
            Button("Delete", role: .destructive) { model.delete(sha256: item.sha256) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the imported records from this Mac. The file you saved is not touched. It cannot be undone.")
        }
    }

    private func detail(_ item: ImportItem) -> String {
        var text = ImportText.count(item.recordsKept, "network record", "network records")
        if item.skippedLines > 0 { text += ", \(ImportText.count(item.skippedLines, "line", "lines")) not read" }
        return text
    }
}
