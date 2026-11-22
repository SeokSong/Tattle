import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmDelete = false
    @State private var showAbout = false

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
                Text("Raw packets, including any unencrypted web traffic, are saved on this Mac until you delete them: after 24 hours or with Delete all.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Button("Data sources and licences...") { showAbout = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAbout) { AboutView() }
        .confirmationDialog("Delete all sessions?", isPresented: $confirmDelete) {
            Button("Delete all", role: .destructive) { model.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every stored flow and domain, and any saved raw packet files. It cannot be undone.")
        }
    }
}
