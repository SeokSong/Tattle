import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Capture access") {
                LabeledContent("Access", value: "Asked each time (prototype)")
                Button("Revoke access") {}.disabled(true)
            }
            Section("Retention") {
                Picker("Keep sessions for", selection: $model.retentionDays) {
                    ForEach(AppModel.retentionChoices, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Button("Delete all sessions...", role: .destructive) { confirmDelete = true }
                    .disabled(model.isBusy)
            }
            Section("Diagnostic capture") {
                Toggle("Also save the raw packet stream", isOn: $model.diagnosticCapture)
                    .disabled(model.isBusy)
                Text("Writes every packet to a file in ~/Library/Application Support/Watch for the next capture. Off at every launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all sessions?", isPresented: $confirmDelete) {
            Button("Delete all", role: .destructive) { model.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every stored flow and domain. It cannot be undone.")
        }
    }
}
