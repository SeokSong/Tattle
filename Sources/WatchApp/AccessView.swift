import SwiftUI

struct AccessView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow capture access").font(.title2.bold())
            Text("To see the iPhone's network traffic, macOS needs to open a virtual network interface for it. That takes administrator rights.")
            VStack(alignment: .leading, spacing: 4) {
                Text("Only two Apple tools run with those rights: rvictl, which creates the interface, and tcpdump, which reads it.")
                Text("This app itself never runs as administrator, and the rights end when you press Stop.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Allow once") { model.startCapture() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Button("Always allow") {}.disabled(true)
                    Text("needs the signed helper (later)").font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { model.showAccess = false }
                    .controlSize(.large)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
    }
}
