import Attribution
import Capture
import Flows
import Foundation
import PCAPNG
import Pipeline
import Storage
import SwiftUI

// everything the views show. the app never runs as root: the privileged part is PrototypeCaptureLauncher.
// the udid stays inside startCapture; views get the device name only.

enum SidebarItem: String, CaseIterable, Identifiable {
    case connect = "Connect"
    case live = "Live"
    case sessions = "Sessions"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .connect: return "cable.connector"
        case .live: return "waveform"
        case .sessions: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

enum CaptureState: Equatable {
    case idle
    case requestingAccess
    case starting
    case capturing(since: Date)
    case stopping
    case failed(message: String)
}

struct DeviceStatus: Equatable {
    var usb = false
    var link = false
    /// shown as the device name; never the udid
    var name: String?
    var linkNote: String?
    var lookupError: String?
}

struct SessionRow: Identifiable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var packets: Int
    var flows: Int
    var endReason: String?

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

struct SessionDetail {
    var rows: [ProcessRow]
    var flows: [FlowLine]
}

@MainActor
final class AppModel: ObservableObject {
    static let retentionChoices = [1, 3, 7]

    @Published var selection: SidebarItem = .connect
    @Published var deviceStatus: DeviceStatus?
    @Published var captureState: CaptureState = .idle
    @Published var showAccess = false
    @Published var liveStats = PipelineStats()
    @Published var liveFlows: [Flow] = []
    @Published var processRows: [ProcessRow] = []
    @Published var topFlowLines: [FlowLine] = []
    @Published var sessions: [SessionRow] = []
    @Published var storeError: String?

    @Published var retentionDays: Int {
        didSet {
            UserDefaults.standard.set(retentionDays, forKey: Self.retentionKey)
            applyRetention()
        }
    }
    /// off at every launch on purpose: raw packets on disk should never be on by accident
    @Published var diagnosticCapture = false
    @Published private(set) var diagnosticActive = false

    private static let retentionKey = "retentionDays"

    private let storePath: URL
    private var store: Store?
    private var wiredDevice: DeviceSummary?
    private var launcher: PrototypeCaptureLauncher?
    private var pipeline: CapturePipeline?
    private var runTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var currentSession: UUID?
    private var countCache: [UUID: (packets: Int, flows: Int)] = [:]

    init(storePath: URL = Store.defaultPath()) {
        self.storePath = storePath
        let saved = UserDefaults.standard.integer(forKey: Self.retentionKey)
        retentionDays = Self.retentionChoices.contains(saved) ? saved : 7
        do {
            let opened = try Store(path: storePath)
            store = opened
            try opened.markInterruptedSessions()
            try opened.expire(olderThan: TimeInterval(retentionDays) * 86400)
        } catch {
            storeError = "The session database could not be opened: \(error.localizedDescription)"
        }
        refreshSessions()
    }

    // MARK: state helpers

    var isCapturing: Bool {
        if case .capturing = captureState { return true }
        return false
    }

    /// true from the first click until the capture is fully stopped again
    var isBusy: Bool {
        switch captureState {
        case .idle, .failed: return false
        default: return true
        }
    }

    var canStart: Bool {
        !isBusy && deviceStatus?.usb == true && deviceStatus?.link == true
    }

    var deviceName: String? { deviceStatus?.name }

    // MARK: device

    /// refreshes the device status every 5 s until the calling task is cancelled (Connect screen)
    func pollDevices() async {
        while !Task.isCancelled {
            if !isBusy { await refreshDevice() }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    func refreshDevice() async {
        var status = DeviceStatus()
        do {
            let devices = try await DeviceLookup.wiredDevices()
            if let device = devices.first {
                wiredDevice = device
                status.usb = true
                status.name = device.name
                // rvi needs a wired, paired device; the coredevice tunnel comes up on demand and is only shown
                status.link = device.pairing == "paired"
                status.linkNote = status.link ? "Paired, wired, tunnel \(device.tunnel)" : "\(device.pairing), tunnel \(device.tunnel)"
            } else {
                wiredDevice = nil
            }
        } catch {
            wiredDevice = nil
            status.lookupError = "\(error)"
        }
        if !Task.isCancelled { deviceStatus = status }
    }

    // MARK: start and stop

    func requestStart() {
        guard canStart else { return }
        showAccess = true
    }

    /// Allow once: the osascript password dialog runs inside launcher.start
    func startCapture() {
        showAccess = false
        guard !isBusy else { return }
        captureState = .starting
        Task { await performStart() }
    }

    private func performStart() async {
        var tee: FileHandle?
        var launcher: PrototypeCaptureLauncher?
        do {
            let devices = try await DeviceLookup.wiredDevices()
            guard let device = devices.first, device.pairing == "paired" else {
                throw StartFailure("No connected iPhone found. Check the cable and unlock the phone.")
            }
            guard let readStore = store else { throw StartFailure(storeError ?? "The session database is not open.") }
            let deviceHash = try readStore.deviceHash(udid: device.udid)

            if diagnosticCapture { tee = try makeDiagnosticFile() }
            captureState = .requestingAccess
            let started = PrototypeCaptureLauncher()
            launcher = started
            self.launcher = started
            let source = try await started.start(udid: device.udid, tee: tee)
            tee = nil  // the source owns it now
            captureState = .starting

            let session = CaptureSession(
                id: UUID(), startedAt: Date(), source: "rvi", deviceHash: deviceHash, deviceName: device.name,
                watchVersion: "dev")
            let pipeline = CapturePipeline(store: try Store(path: storePath), session: session, retainFlows: true)
            self.pipeline = pipeline
            currentSession = session.id
            diagnosticActive = diagnosticCapture
            liveStats = PipelineStats()
            liveFlows = []
            processRows = []
            topFlowLines = []

            await pipeline.startFlushTimer()
            runTask = Task { [weak self] in
                var failure: String?
                do { _ = try await pipeline.run(source) } catch { failure = "\(error)" }
                await self?.captureEnded(failure: failure)
            }
            startRefreshing()
            captureState = .capturing(since: Date())
            selection = .live
        } catch {
            try? tee?.close()
            if let launcher { await launcher.stop() }
            self.launcher = nil
            pipeline = nil
            currentSession = nil
            diagnosticActive = false
            captureState = .failed(message: Self.message(for: error))
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        captureState = .stopping
        Task { await performStop() }
    }

    private func performStop() async {
        await launcher?.stop()
        // the stream ends once tcpdump exits; run returns and captureEnded sees .stopping
        await runTask?.value
        await finish(reason: .captureStopped)
        captureState = .idle
    }

    /// run returned: a stop in progress finishes it; otherwise the capture died on its own
    private func captureEnded(failure: String?) async {
        guard isCapturing else { return }
        captureState = .stopping
        await launcher?.stop()
        await finish(reason: .interrupted)
        captureState = .failed(message: failure.map { "The capture stopped unexpectedly: \($0)" }
            ?? "The capture stopped unexpectedly. Check the phone and cable, then start again.")
    }

    private func finish(reason: FlowEndReason) async {
        refreshTask?.cancel()
        refreshTask = nil
        if let pipeline {
            await pipeline.stop(reason: reason)
            liveStats = await pipeline.stats
            liveFlows = await pipeline.flowsSnapshot()
            updateDerived()
        }
        pipeline = nil
        launcher = nil
        runTask = nil
        currentSession = nil
        diagnosticActive = false
        refreshSessions()
    }

    // MARK: live refresh

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, let pipeline = self.pipeline else { return }
                let stats = await pipeline.stats
                let flows = await pipeline.flowsSnapshot()
                if Task.isCancelled { return }
                self.liveStats = stats
                self.liveFlows = flows
                self.updateDerived()
            }
        }
    }

    private func updateDerived() {
        processRows = groupByProcess(from: liveFlows, withEmptyUnattributed: true)
        topFlowLines = topFlows(liveFlows)
    }

    var interfaceName: String? {
        liveStats.interfaces.keys.filter { !$0.isEmpty }.sorted().first
    }

    // MARK: sessions

    func refreshSessions() {
        guard let store else { return }
        do {
            var rows: [SessionRow] = []
            for session in try store.sessions() where session.id != currentSession {
                var counts = countCache[session.id]
                if counts == nil {
                    let totals = try store.processTotals(session: session.id)
                    let flows = try store.flows(session: session.id).count
                    counts = (totals.reduce(0) { $0 + $1.packets }, flows)
                    if session.endedAt != nil { countCache[session.id] = counts }
                }
                rows.append(SessionRow(
                    id: session.id, startedAt: session.startedAt, endedAt: session.endedAt,
                    packets: counts?.packets ?? 0, flows: counts?.flows ?? 0, endReason: session.endReason))
            }
            sessions = rows.sorted { $0.startedAt > $1.startedAt }
        } catch {
            storeError = "Sessions could not be read: \(error.localizedDescription)"
        }
    }

    func detail(for id: UUID) -> SessionDetail? {
        guard let store else { return nil }
        do {
            let totals = try store.processTotals(session: id)
            let inputs = totals.map { TallyInput(tally: [$0.0: $0.packets], packets: $0.packets, ipBytes: $0.ipBytes) }
            let flows = try store.flows(session: id)
            return SessionDetail(rows: groupByProcess(from: inputs, withEmptyUnattributed: true), flows: topFlows(flows))
        } catch {
            storeError = "Session could not be read: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: settings

    private func applyRetention() {
        guard !isBusy else { return }
        try? store?.expire(olderThan: TimeInterval(retentionDays) * 86400)
        refreshSessions()
    }

    func deleteAll() {
        guard !isBusy else { return }
        do {
            try store?.deleteAll()
            countCache = [:]
        } catch {
            storeError = "Delete failed: \(error.localizedDescription)"
        }
        refreshSessions()
    }

    // MARK: helpers

    private struct StartFailure: Error {
        var text: String
        init(_ text: String) { self.text = text }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let failure as StartFailure: return failure.text
        case CaptureError.accessDenied: return "Access was not granted. Nothing was started."
        case CaptureError.accessTimedOut: return "The password dialog timed out. Nothing was started."
        case let capture as CaptureError: return "\(capture)"
        default: return error.localizedDescription
        }
    }

    private func makeDiagnosticFile() throws -> FileHandle {
        let base = storePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = base.appendingPathComponent("diagnostic-\(stamp).pcapng")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forWritingAtPath: url.path) else {
            throw StartFailure("The diagnostic file could not be created.")
        }
        return handle
    }
}
