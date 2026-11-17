import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connect").font(.largeTitle.bold())
                Text("Plug in the iPhone with a cable and unlock it. Nothing is captured until you press Start.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    CheckRow(state: usbState, title: "USB", detail: usbDetail)
                    CheckRow(state: linkState, title: "Device link", detail: linkDetail)
                    CheckRow(state: .neutral, title: "Capture access", detail: "Asked on start")
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))

                if case .failed(let message) = model.captureState {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }

                if model.showAccess {
                    AccessView()
                } else if model.captureState == .requestingAccess {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the administrator password dialog...")
                    }
                } else if model.captureState == .starting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting...")
                    }
                } else if model.isCapturing {
                    Text("Capturing. See Live.").foregroundStyle(.secondary)
                } else {
                    Button("Start capture") { model.requestStart() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.canStart)
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // cancelled when the screen goes away, so devicectl is only polled while it is shown
        .task { await model.pollDevices() }
    }

    private var usbState: CheckRow.State {
        guard let status = model.deviceStatus else { return .pending }
        return status.usb ? .ok : .bad
    }

    private var usbDetail: String {
        guard let status = model.deviceStatus else { return "Checking..." }
        if let error = status.lookupError { return "Could not check: \(error)" }
        if status.usb { return status.name ?? "iPhone connected" }
        return "No iPhone found on a cable"
    }

    private var linkState: CheckRow.State {
        guard let status = model.deviceStatus else { return .pending }
        return status.link ? .ok : .bad
    }

    private var linkDetail: String {
        guard let status = model.deviceStatus else { return "Checking..." }
        if let note = status.linkNote { return note }
        return "Needs a connected iPhone"
    }
}

struct CheckRow: View {
    enum State { case ok, bad, pending, neutral }

    var state: State
    var title: String
    var detail: String

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .bad: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .pending: ProgressView().controlSize(.small)
            case .neutral: Image(systemName: "lock.circle").foregroundStyle(.secondary)
            }
            Text(title).fontWeight(.medium).frame(width: 130, alignment: .leading)
            Text(detail).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
