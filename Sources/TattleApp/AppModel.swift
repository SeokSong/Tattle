import Attribution
import Capture
import Combine
import Domains
import Flows
import Foundation
import PCAPNG
import Pipeline
import Storage
import Summary
import SwiftUI

// everything the views show. the app never runs as root: the privileged part is PrototypeCaptureLauncher.
// the udid stays inside startCapture; views get the device name only.

enum SidebarItem: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case connect = "Connect"
    case live = "Live"
    case sessions = "Sessions"
    case importReport = "Import"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .summary: return "list.bullet.rectangle"
        case .connect: return "cable.connector"
        case .live: return "waveform"
        case .sessions: return "clock.arrow.circlepath"
        case .importReport: return "square.and.arrow.down"
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
    var gapCount = 0
    var maxGapMs = 0

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

struct SessionDetail {
    var grouping: ProcessGrouping
    var flows: [FlowLine]
    /// flows left out of the table (filtered or not), shown as "N more flows"
    var moreFlows = 0
    /// the apps the Sessions filter can offer for this session
    var appNames: [String] = []
    var gapCount = 0
    var maxGapMs = 0
    /// tcpdump's drop count; nil when unknown (the capture was ended by KILL)
    var kernelDropped: Int?
}

@MainActor
final class AppModel: ObservableObject {
    static let retentionChoices = [1, 3, 7]
    /// rows in the live flow table; the rest fold into one "N more flows" line
    static let liveTableRows = 10
    /// the Sessions table shows as many rows as before 5.1 (topFlows' default)
    static let sessionTableRows = 10
    /// the session count cache is cleared when it passes this (one entry per ended session)
    static let maxCountCache = 1_000

    @Published var selection: SidebarItem = .connect
    @Published var deviceStatus: DeviceStatus?
    @Published var captureState: CaptureState = .idle {
        didSet { importModel.captureBusy = isBusy }
    }
    @Published var showAccess = false
    @Published var liveStats = PipelineStats()
    @Published var liveFlows: [Flow] = []
    @Published var liveDNS: [DomainObservation] = []
    @Published var grouping = ProcessGrouping()
    @Published var topFlowLines: [FlowLine] = []
    /// flows beyond the ones in `topFlowLines`; shown as the fold line
    @Published var moreFlows = 0
    @Published var sessions: [SessionRow] = []
    @Published var storeError: String?
    @Published var summaryScreen: SummaryScreen?
    /// the app filters (5.1), one per screen; nil shows all apps. they change what is shown, never stored data.
    /// a filter whose app is not in the current names is cleared, so a table never comes up empty under a blank picker
    @Published var liveAppFilter: String? {
        didSet { if liveAppFilter != oldValue { updateDerived() } }
    }
    @Published var sessionsAppFilter: String?
    /// the apps the Live filter can offer
    @Published var liveAppNames: [String] = []
    @Published var summaryLoading = false

    @Published var retentionDays: Int {
        didSet {
            UserDefaults.standard.set(retentionDays, forKey: Self.retentionKey)
            importModel.retentionDays = retentionDays
            applyRetention()
        }
    }
    /// off at every launch on purpose: raw packets on disk should never be on by accident
    @Published var diagnosticCapture = false
    @Published private(set) var diagnosticActive = false

    private static let retentionKey = "retentionDays"

    /// the App Privacy Report import screen and list; views observe it directly
    let importModel: ImportModel

    private var importChange: AnyCancellable?
    private let storePath: URL
    private var store: Store?
    private var wiredDevice: DeviceSummary?
    private var launcher: PrototypeCaptureLauncher?
    private var pipeline: CapturePipeline?
    private var runTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// set when the stall watchdog judged the iPhone link dead; the capture end then says so
    private var linkLost = false
    private var currentSession: UUID?
    private var countCache: [UUID: (packets: Int, flows: Int)] = [:]

    init(storePath: URL = Store.defaultPath()) {
        self.storePath = storePath
        importModel = ImportModel(storePath: storePath)
        let saved = UserDefaults.standard.integer(forKey: Self.retentionKey)
        retentionDays = Self.retentionChoices.contains(saved) ? saved : 7
        importModel.retentionDays = retentionDays
        // views of this model (Settings) also show whether an import is running
        importChange = importModel.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        importModel.storeChanged = { [weak self] in self?.refreshSummary() }
        do {
            let opened = try Store(path: storePath)
            store = opened
            try opened.markInterruptedSessions()
            try opened.expire(olderThan: TimeInterval(retentionDays) * 86400)
        } catch {
            storeError = "The session database could not be opened: \(error.localizedDescription)"
        }
        // a crashed app can leave a run directory (and a root tcpdump) behind: ask it to stop, then clear it
        Task { [weak self] in
            let result = await PrototypeCaptureLauncher.cleanStaleRunDirectories(runRoot: PrototypeCaptureLauncher.defaultRunRoot())
            if !result.failed.isEmpty {
                self?.storeError = "\(result.failed.count) old capture folder(s) could not be removed. They hold no packets and are safe to delete from \(PrototypeCaptureLauncher.defaultRunRoot().path)."
            }
        }
        // demo mode (made-up data, for screenshots and the reader test) opens on the Summary screen
        if ProcessInfo.processInfo.environment["TATTLE_DEMO_SUMMARY"] == "1" { selection = .summary }
        // TATTLE_START_SCREEN opens a screen by name (for screenshots without clicking): summary, connect, live,
        // sessions, import, settings
        if let name = ProcessInfo.processInfo.environment["TATTLE_START_SCREEN"]?.lowercased(),
           let item = SidebarItem.allCases.first(where: { $0.rawValue.lowercased() == name || ($0 == .importReport && name == "import") }) {
            selection = item
        }
        DiagnosticFiles.purge(in: DiagnosticFiles.directory(under: storePath.deletingLastPathComponent()), now: Date())
        refreshSessions()
        importModel.refresh()
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
            liveDNS = []
            grouping = ProcessGrouping()
            topFlowLines = []
            moreFlows = 0

            // a failing stream stops the pipeline inside run, before the launcher is stopped: read the log then
            await pipeline.setKernelDroppedProvider { await started.kernelDroppedNow() }
            await pipeline.startFlushTimer()
            runTask = Task { [weak self] in
                var failure: String?
                do { _ = try await pipeline.run(source) } catch { failure = "\(error)" }
                await self?.captureEnded(failure: failure)
            }
            startRefreshing()
            startWatchdog(source: source, launcher: started, pipeline: pipeline)
            captureState = .capturing(since: Date())
            liveAppFilter = nil
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
        // a capture the user stopped opens the Summary, which finish() has started to reload (owner, 2026-11-24).
        // a capture that ended on its own stays on Live, so its message (why it stopped) is seen
        selection = .summary
    }

    /// run returned: a stop in progress finishes it; otherwise the capture died on its own
    private func captureEnded(failure: String?) async {
        guard isCapturing else { return }
        captureState = .stopping
        await launcher?.stop()
        let tcpdumpSawLinkLoss = await launcher?.lastLinkLost ?? false
        await finish(reason: .interrupted)
        if linkLost || tcpdumpSawLinkLoss {
            captureState = .failed(message: StallWatchdog.linkLostMessage
                + ". Everything received so far was saved. Check the cable, then start again.")
        } else {
            captureState = .failed(message: failure.map { "The capture stopped unexpectedly: \($0)" }
                ?? "The capture stopped unexpectedly. Check the phone and cable, then start again.")
        }
    }

    /// 6.3: no bytes for 15 s and the rvi interface gone or down ends the session as interrupted. a quiet
    /// but alive link ends nothing (the gap is counted from packet time)
    private func startWatchdog(source: FileHandlePacketSource, launcher: PrototypeCaptureLauncher, pipeline: CapturePipeline) {
        linkLost = false
        let tools = CaptureTools()
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            guard let owner = self else { return }
            _ = await runStallWatchdog(
                StallWatchdog(),
                lastByteAt: { source.lastByteAt },
                processRunning: { !source.isFinished },
                linkUp: {
                    // the script, not the app, knows the interface; the packets carry its name
                    let name = await pipeline.stats.interfaces.keys.filter { !$0.isEmpty }.sorted().first
                    if let name { return await LinkProbe.isUp(interface: name, tools: tools) }
                    return await LinkProbe.anyRVIPresent(tools: tools)
                },
                onLinkDown: {
                    await owner.markLinkLost()
                    await launcher.stop()
                    await pipeline.setKernelDropped(await launcher.lastKernelDropped)
                    await pipeline.stop(reason: .interrupted)
                })
        }
    }

    private func markLinkLost() { linkLost = true }

    private func finish(reason: FlowEndReason) async {
        refreshTask?.cancel()
        refreshTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        if let pipeline {
            if let launcher { await pipeline.setKernelDropped(await launcher.lastKernelDropped) }
            await pipeline.stop(reason: reason)
            liveStats = await pipeline.stats
            liveFlows = await pipeline.flowsSnapshot()
            liveDNS = await pipeline.dnsSnapshot()
            updateDerived()
        }
        pipeline = nil
        launcher = nil
        runTask = nil
        currentSession = nil
        diagnosticActive = false
        refreshSessions()
        refreshSummary()
    }

    // MARK: summary

    /// a request while a load runs is kept and run when it ends, so the screen never stays on an older result
    private var summaryReloadPending = false

    func refreshSummary() {
        if summaryLoading { summaryReloadPending = true; return }
        summaryLoading = true
        let path = storePath
        let days = retentionDays
        let excluding = currentSession
        let demo = ProcessInfo.processInfo.environment["TATTLE_DEMO_SUMMARY"] == "1"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SummaryLoader.load(storePath: path, retentionDays: days, now: Date(), excluding: excluding, demo: demo) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let screen): self.summaryScreen = screen
            case .failure(let error): self.storeError = "The summary could not be built: \(error.localizedDescription)"
            }
            self.summaryLoading = false
            if self.summaryReloadPending {
                self.summaryReloadPending = false
                self.refreshSummary()
            }
        }
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
                let dns = await pipeline.dnsSnapshot()
                if Task.isCancelled { return }
                self.liveStats = stats
                self.liveFlows = flows
                self.liveDNS = dns
                self.updateDerived()
            }
        }
    }

    private func updateDerived() {
        grouping = groupByProcess(from: liveFlows, withEmptyUnattributed: true)
        let names = appNames(in: liveFlows)
        if names != liveAppNames { liveAppNames = names }
        if let filter = liveAppFilter, !names.contains(filter) { liveAppFilter = nil; return }
        let rows = flowRows(liveFlows, observations: liveDNS, limit: Self.liveTableRows, app: liveAppFilter)
        topFlowLines = rows.lines
        moreFlows = rows.moreFlows
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
                    if session.endedAt != nil {
                        if countCache.count >= Self.maxCountCache { countCache.removeAll() }
                        countCache[session.id] = counts
                    }
                }
                rows.append(SessionRow(
                    id: session.id, startedAt: session.startedAt, endedAt: session.endedAt,
                    packets: counts?.packets ?? 0, flows: counts?.flows ?? 0, endReason: session.endReason))
                if let stats = try? store.sessionStats(id: session.id) {
                    rows[rows.count - 1].gapCount = stats.gapCount
                    rows[rows.count - 1].maxGapMs = stats.maxGapMs
                }
            }
            sessions = rows.sorted { $0.startedAt > $1.startedAt }
        } catch {
            storeError = "Sessions could not be read: \(error.localizedDescription)"
        }
    }

    func detail(for id: UUID) -> SessionDetail? {
        guard let store else { return nil }
        do {
            // the category is decided per flow, then carried to each of its tally rows
            let flows = try store.flows(session: id)
            let stats = try store.sessionStats(id: id)
            let names = appNames(in: flows)
            if let filter = sessionsAppFilter, !names.contains(filter) { sessionsAppFilter = nil }
            let rows = flowRows(flows, observations: try store.domains(session: id), limit: Self.sessionTableRows, app: sessionsAppFilter)
            return SessionDetail(
                grouping: groupByProcess(from: tallyInputs(from: flows), withEmptyUnattributed: true),
                flows: rows.lines, moreFlows: rows.moreFlows,
                appNames: names,
                gapCount: stats.gapCount, maxGapMs: stats.maxGapMs, kernelDropped: stats.kernelDropped)
        } catch {
            storeError = "Session could not be read: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: settings

    private func applyRetention() {
        guard !isBusy, !importModel.isRunning else { return }
        try? store?.expire(olderThan: TimeInterval(retentionDays) * 86400)
        refreshSessions()
        importModel.refresh()
        refreshSummary()
    }

    /// why Delete all data is off, or nil
    var deleteAllUnavailableReason: String? { importModel.deleteAllUnavailableReason(captureBusy: isBusy) }

    func deleteAll() {
        guard deleteAllUnavailableReason == nil else { return }
        DiagnosticFiles.purgeAll(in: diagnosticDirectory)
        do {
            try store?.deleteAll()
            countCache = [:]
        } catch {
            storeError = "Delete failed: \(error.localizedDescription)"
        }
        refreshSessions()
        importModel.refresh()
        refreshSummary()
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

    private var diagnosticDirectory: URL {
        DiagnosticFiles.directory(under: storePath.deletingLastPathComponent())
    }

    private func makeDiagnosticFile() throws -> FileHandle {
        do {
            return try DiagnosticFiles.create(in: diagnosticDirectory, now: Date())
        } catch {
            throw StartFailure("The diagnostic file could not be created.")
        }
    }
}
