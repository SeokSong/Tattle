
import Foundation
import IOKit
import IOKit.usb
import Attribution
import Capture
import Companies
import Dispatch
import Domains
import Flows
import PCAPNG
import Pipeline
import Report
import Storage
import Summary
import AppKit
import SwiftUI
import WorldMap

let appleVendorID = 1452

// MARK: - USB Detection

func isIPhoneConnectedViaUSB() -> Bool {
    let matching = IOServiceMatching(kIOUSBDeviceClassName)

    var iterator: io_iterator_t = 0

    let result = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        matching,
        &iterator
    )

    guard result == KERN_SUCCESS else {
        print("Unable to enumerate USB devices")
        return false
    }

    defer {
        IOObjectRelease(iterator)
    }

    while true {
        let device = IOIteratorNext(iterator)

        if device == 0 {
            break
        }

        defer {
            IOObjectRelease(device)
        }

        let vendorID = IORegistryEntryCreateCFProperty(
            device,
            "idVendor" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Int

        let productName = IORegistryEntryCreateCFProperty(
            device,
            "USB Product Name" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String

        if vendorID == appleVendorID && productName == "iPhone" {
            return true
        }
    }

    return false
}

// MARK: - CoreDevice Information

struct DeviceInfoResponse: Decodable {
    let info: CommandInfo
    let result: DeviceDetails?
}

struct CommandInfo: Decodable {
    let outcome: String
}

struct DeviceDetails: Decodable {
    let connectionProperties: ConnectionProperties?
    let deviceProperties: DeviceProperties?
}

struct ConnectionProperties: Decodable {
    let pairingState: String?
    let transportType: String?
    let tunnelState: String?
}

struct DeviceProperties: Decodable {
    let name: String?
    let developerModeStatus: String?
}

// MARK: - CoreDevice Check

func getDeviceInfo(udid: String) throws -> DeviceInfoResponse {
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("json")

    defer {
        try? FileManager.default.removeItem(at: outputURL)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "devicectl",
        "device",
        "info",
        "details",
        "--device",
        udid,
        "--json-output",
        outputURL.path
    ]

    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: AppIdentity.name,
            code: Int(process.terminationStatus),
            userInfo: [
                NSLocalizedDescriptionKey: "devicectl failed"
            ]
        )
    }

    let data = try Data(contentsOf: outputURL)

    return try JSONDecoder().decode(
        DeviceInfoResponse.self,
        from: data
    )
}

// MARK: - Capture Summary

func printCaptureSummary(path: String) {
    let capture: PCAPNGCapture

    do {
        capture = try PCAPNGReader.read(contentsOf: URL(fileURLWithPath: path))
    } catch {
        print("Unable to read \(path): \(error)")
        exit(1)
    }

    print("Sections: \(capture.sectionCount)")

    print("\nInterfaces:")
    for interface in capture.interfaces {
        let count = capture.packets.filter { $0.interface == interface }.count
        print("  [\(interface.id)] \(interface.name ?? "?")  linktype \(interface.linkType)  packets \(count)")
    }

    print("\nPackets: \(capture.packets.count)")

    if let first = capture.packets.first?.timestamp, let last = capture.packets.last?.timestamp {
        print("Time range: \(first) to \(last)")
    }

    var packetsByProcess: [String: Int] = [:]
    for packet in capture.packets {
        let key = packet.process.map { "\($0.name ?? "?") (\($0.pid))" } ?? "no process"
        packetsByProcess[key, default: 0] += 1
    }

    print("\nPackets by process:")
    for (process, count) in packetsByProcess.sorted(by: { $0.value > $1.value }) {
        print("  \(count)\t\(process)")
    }

    print("\nFirst packets:")
    for packet in capture.packets.prefix(10) {
        let process = packet.process.map { "\($0.name ?? "?")[\($0.pid)]" } ?? "-"
        let effective = packet.effectiveProcess.map { " for \($0.name ?? "?")[\($0.pid)]" } ?? ""
        print("  \(packet.timestamp)  \(packet.interface.name ?? "?")  \(packet.capturedLength)B  \(process)\(effective)")
    }

    if capture.unresolvedProcessReferences > 0 {
        print("\nUnresolved process references: \(capture.unresolvedProcessReferences)")
    }

    if !capture.skippedBlocks.isEmpty {
        let skipped = capture.skippedBlocks.map { "0x\(String($0.key, radix: 16)) x\($0.value)" }
        print("\nSkipped blocks: \(skipped.joined(separator: ", "))")
    }

    print("\nEnd: \(capture.endedWithPcapTrailer ? "24-byte pcap trailer" : "end of file")")
}

// MARK: - Pipeline commands

func newSession() -> CaptureSession {
    CaptureSession(id: UUID(), startedAt: Date(), source: "file", watchVersion: "dev")
}

func describe(_ attribution: AttributionResult) -> String {
    var text: String
    switch attribution.primary {
    case .app(let name, let pids):
        text = "\(ProcessNames.displayName(name)) (\(pids.count) pid\(pids.count == 1 ? "" : "s"))"
    case .onBehalfOf(let app, let via): text = "\(ProcessNames.displayName(app)) via \(ProcessNames.displayName(via))"
    case .system(let name): text = "system \(ProcessNames.displayName(name))"
    case .unknown: text = "unknown"
    }
    if attribution.mixed { text += " [mixed]" }
    return text
}

func appNames(_ flow: Flow) -> [String] {
    var names = Set<String>()
    for pair in flow.tally.keys {
        if let name = pair.effectiveName ?? pair.processName { names.insert(name) }
    }
    return names.sorted()
}

/// name with its source, or the reason there is none. the index is built once by the caller
func hostnameText(_ flow: Flow, index: HostnameIndex) -> String {
    switch index.outcome(for: flow) {
    case .named(let resolved):
        switch resolved.source {
        case .sni: return "\(resolved.name) [sni]"
        case .dns: return "\(resolved.name) [dns, may be another service]"
        case .sameAddress: return "\(resolved.name) [same server as another connection, may be another service]"
        }
    case .unnamed(let reason): return "(\(reason.label))"
    }
}

/// the company and category of a flow's name, "Possible: " for a hint, "Not identified" for a name no
/// list knows; empty when the flow has no name. the same words as the app
func companyText(_ label: FlowLabel?) -> String {
    guard let label else { return "" }
    let value = label.label
    guard value.isMatched, let company = value.company else { return "[" + value.unidentifiedText + "]" }
    var text = company
    if value.category != .unclassified { text += ", " + value.category.label }
    return "[" + (label.isPossible ? "Possible: " : "") + text + "]"
}

func flowLine(_ flow: Flow, index: HostnameIndex, cache: inout LabelCache) -> String {
    let timeFormatter = ISO8601DateFormatter()
    timeFormatter.formatOptions = [.withTime, .withColonSeparatorInTime]
    let key = flow.key
    let transport = key.transport == .tcp ? "tcp" : "udp"
    let category = Classifier.classify(flow).category.rawValue
    let padded = category.padding(toLength: 12, withPad: " ", startingAt: 0)
    var line = "  \(padded)  \(timeFormatter.string(from: flow.firstSeen))  \(flow.interface)  \(transport)  "
    line += "\(key.remoteAddress.description):\(key.remotePort)  in \(flow.ipBytesIn) out \(flow.ipBytesOut)"
    line += "  \(hostnameText(flow, index: index))"
    let company = companyText(FlowLabels.label(for: flow, index: index, cache: &cache))
    if !company.isEmpty { line += "  \(company)" }
    line += "  -> \(describe(Attributor.attribute(flow.tally)))"
    return line
}

/// the non-zero give-up reasons, in enum order. numbers only
func gaveUpSummary(_ stats: PipelineStats) -> String {
    let parts = GaveUpReason.allCases.compactMap { r in stats.handshakeGaveUp[r.rawValue].map { "\(r.rawValue) \($0)" } }
    return "Handshake gave up: " + (parts.isEmpty ? "none" : parts.joined(separator: ", "))
}

/// every cap counter and peak on one line, numbers only. all counters are 0 unless a cap was hit
func capsSummary(_ s: PipelineStats) -> String {
    "Caps: peakOpenFlows \(s.peakOpenFlows)  evictedFlows \(s.evictedFlows)  droppedClosedFlows \(s.droppedClosedFlows)"
        + "  tallyRowsFolded \(s.tallyRowsFolded)  peakPendingDomains \(s.peakPendingDomains)  droppedDomains \(s.droppedDomains)"
        + "  peakHandshakeStates \(s.peakHandshakeStates)  handshakeStatesDropped \(s.handshakeStatesDropped)"
        + "  retainedDropped \(s.retainedDropped)  retainedDomainsDropped \(s.retainedDomainsDropped)"
        + "  interfacesFolded \(s.interfacesFolded)"
        + (s.anyCapHit ? "\nWarning: a cap was hit; totals built from memory may be lower than the saved session" : "")
}

func printFlows(path: String, dbPath: String?) async {
    let url = URL(fileURLWithPath: path)
    var store: Store?
    if let dbPath {
        do { store = try Store(path: URL(fileURLWithPath: dbPath)) } catch {
            print("Unable to open database: \(error)")
            exit(1)
        }
    }
    let pipeline = CapturePipeline(store: store, session: newSession(), retainFlows: true, retainDomains: true)
    let stats: PipelineStats
    do {
        stats = try await pipeline.run(FilePacketSource(url: url))
    } catch {
        print("Pipeline stopped: \(error)")
        exit(1)
    }
    await pipeline.stop(reason: .captureStopped)
    let final = await pipeline.stats

    await printSummary(pipeline: pipeline, stats: stats, final: final, dbPath: dbPath)
}

func printSummary(pipeline: CapturePipeline, stats: PipelineStats, final: PipelineStats, dbPath: String?) async {
    print("Packets: \(stats.packets)  decoded \(stats.decoded)  skipped \(stats.skipped)  malformed \(stats.malformed)  no port \(stats.droppedNoPort)")
    print("Flows: opened \(final.flowsOpened)  closed \(final.flowsClosed)")
    print("Interfaces: " + stats.interfaces.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    print("Elapsed: \(String(format: "%.3f", stats.elapsed)) s")
    if dbPath != nil { print("Saved to \(dbPath ?? "")") }

    let flows = await pipeline.flowsSnapshot()
    let index = HostnameIndex(await pipeline.domainsSnapshot(), flows: flows)
    var cache = LabelCache()
    print("\nTop flows by IP bytes:")
    for flow in flows.sorted(by: { $0.ipBytesIn + $0.ipBytesOut > $1.ipBytesIn + $1.ipBytesOut }).prefix(20) {
        print(flowLine(flow, index: index, cache: &cache))
    }

    print("\nBytes by category (IP bytes, whole flows):")
    var categoryBytes: [TrafficCategory: Int] = [:]
    var categoryFlows: [TrafficCategory: Int] = [:]
    for flow in flows {
        let category = Classifier.classify(flow).category
        categoryBytes[category, default: 0] += flow.ipBytesIn + flow.ipBytesOut
        categoryFlows[category, default: 0] += 1
    }
    for category in TrafficCategory.allCases {
        let name = category.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
        let counted = category.isPhoneTraffic ? "phone traffic" : "not phone traffic"
        print("  \(name)  \(categoryBytes[category] ?? 0) bytes  \(categoryFlows[category] ?? 0) flows  (\(category.label), \(counted))")
    }
    let phoneBytes = TrafficCategory.allCases.filter(\.isPhoneTraffic).reduce(0) { $0 + (categoryBytes[$1] ?? 0) }
    print("  Phone traffic total: \(phoneBytes) bytes")

    printCompanyCounts(flows: flows, index: index, cache: &cache)

    print("\nDomains: DNS answers \(stats.dnsObservations)  SNI found \(stats.sniFound)")
    print("Handshake buffers gave up: TLS \(await pipeline.tlsGaveUp)  QUIC \(await pipeline.quicGaveUp)")
    print(gaveUpSummary(stats))
    print(capsSummary(final))

    let multi = flows.filter { appNames($0).count > 1 }
        .sorted { $0.ipBytesIn + $0.ipBytesOut > $1.ipBytesIn + $1.ipBytesOut }
    print("\nFlows with more than one app name: \(multi.count)")
    for flow in multi {
        print(flowLine(flow, index: index, cache: &cache))
        print("      names: \(appNames(flow).joined(separator: ", "))")
    }
}

/// numbers only: how many flows and distinct hostnames got a company. a hint is counted apart and
/// never as named. computed here from the finished flows, not on the packet path
func printCompanyCounts(flows: [Flow], index: HostnameIndex, cache: inout LabelCache) {
    var namedMatched = 0, namedUnmatched = 0, hintMatched = 0, hintUnmatched = 0, unnamed = 0
    var hostnames = Set<String>(), matchedHostnames = Set<String>()
    var byCategory: [CompanyCategory: Int] = [:]
    for flow in flows {
        guard let result = FlowLabels.label(for: flow, index: index, cache: &cache) else { unnamed += 1; continue }
        let matched = result.label.isMatched
        if result.isPossible {
            if matched { hintMatched += 1 } else { hintUnmatched += 1 }
            continue
        }
        hostnames.insert(result.label.hostname)
        if matched {
            namedMatched += 1
            matchedHostnames.insert(result.label.hostname)
            byCategory[result.label.category, default: 0] += 1
        } else {
            namedUnmatched += 1
        }
    }
    print("\nCompany labels (names seen in the connection; hints counted apart):")
    print("  Flows with a company: \(namedMatched)  not identified: \(namedUnmatched)  no name: \(unnamed)")
    print("  Possible only (hint names): \(hintMatched) with a company, \(hintUnmatched) not identified")
    print("  Distinct hostnames: \(hostnames.count)  with a company: \(matchedHostnames.count)")
    for category in CompanyCategory.curatable where byCategory[category] != nil {
        print("  \(category.rawValue): \(byCategory[category] ?? 0) flows")
    }
}

func runBench(path: String) async {
    let url = URL(fileURLWithPath: path)
    var best = 0.0
    for run in 1...3 {
        let pipeline = CapturePipeline(store: nil, session: newSession())
        do {
            let stats = try await pipeline.run(FilePacketSource(url: url))
            await pipeline.stop(reason: .captureStopped)
            let rate = Double(stats.packets) / max(stats.elapsed, 1e-9)
            best = max(best, rate)
            print("Run \(run): \(stats.packets) packets in \(String(format: "%.3f", stats.elapsed)) s  \(Int(rate)) packets/s")
        } catch {
            print("Pipeline stopped: \(error)")
            exit(1)
        }
    }
    print("Best: \(Int(best)) packets/s")
}


// MARK: - metrics command

let metricsUsage = """
    usage: tattle metrics <file.csv>

    reads a file written by capture --metrics and prints duration, rows, resident memory (min, max, last),
    the memory slope over the last two thirds of the run, peak open flows, gaps and a verdict.
    "memory flat" means a slope under 1 MB per 10 minutes. exit 0 unless the file is unreadable
    """

func runMetrics(_ args: [String]) -> Int32 {
    guard args.count == 1, args[0] != "--help", args[0] != "-h" else {
        print(metricsUsage)
        return args.first == "--help" || args.first == "-h" ? 0 : 64
    }
    guard let data = FileManager.default.contents(atPath: args[0]), let text = String(data: data, encoding: .utf8) else {
        print("Unable to read metrics file \(args[0])")
        return 1
    }
    do {
        print(MetricsAnalysis.render(try MetricsAnalysis.summarize(csv: text)))
        return 0
    } catch MetricsAnalysis.ParseError.header {
        print("Not a metrics file: the header row does not match")
        return 1
    } catch {
        print("The metrics file has no data rows")
        return 1
    }
}

// MARK: - capture command

let captureUsage = """
    usage: sudo tattle capture (--udid <udid> | --device <name>) [--db <path>] [--duration <seconds>] [--diagnostic <file.pcapng>]
                                  [--metrics <file.csv>]

      --udid <udid>          device to capture, skips the devicectl lookup
      --device <name>        wired device with this name from devicectl: exact match (case and apostrophe style ignored),
                             else a unique substring; ambiguous or missing is exit 3 (only names are printed)
      --db <path>            save flows and domains to this database
      --duration <seconds>   stop automatically after this many seconds
      --diagnostic <file>    also write the raw pcapng stream to this file (raw packets on disk)
      --metrics <file>       append a numbers-only csv row every 2 seconds (packets, flows, caps, gaps, memory); new file only

    exit codes: 0 stopped, 1 rvi failed, 2 tcpdump failed, 3 device not found, 64 bad arguments
    """

struct CaptureOptions {
    var udid: String?
    var device: String?
    var dbPath: String?
    var duration: Double?
    var diagnostic: String?
    var metrics: String?
}

func parseCaptureOptions(_ args: [String]) -> CaptureOptions? {
    var options = CaptureOptions()
    var index = 0
    while index < args.count {
        let flag = args[index]
        guard index + 1 < args.count else { return nil }
        let value = args[index + 1]
        switch flag {
        case "--udid": options.udid = value
        case "--device": options.device = value
        case "--db": options.dbPath = value
        case "--diagnostic": options.diagnostic = value
        case "--metrics": options.metrics = value
        case "--duration":
            guard let seconds = Double(value), seconds > 0 else { return nil }
            options.duration = seconds
        default: return nil
        }
        index += 2
    }
    guard (options.udid == nil) != (options.device == nil) else { return nil }
    return options
}

final class StopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
    func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }
}

func runCapture(_ args: [String]) async -> Int32 {
    if args.contains("--help") || args.contains("-h") {
        print(captureUsage)
        return 0
    }
    guard let options = parseCaptureOptions(args) else {
        print(captureUsage)
        return 64
    }

    // device
    var udid: String
    var name: String?
    if let given = options.udid {
        udid = given
    } else {
        do {
            let devices = try await DeviceLookup.wiredDevices()
            switch DeviceLookup.select(name: options.device, from: devices) {
            case .chosen(let device):
                udid = device.udid
                name = device.name
            case .notFound(let available):
                let list = available.isEmpty ? "no wired device listed" : "wired devices: " + available.joined(separator: ", ")
                print("Device not found: \(options.device ?? "(no name given)") (\(list))")
                return 3
            case .ambiguous(let matches):
                print("Device name is ambiguous, matches: \(matches.joined(separator: ", ")). Pass a longer --device name or use --udid")
                return 3
            }
        } catch {
            print("Device not found: \(redactUDIDs("\(error)", udid: ""))")
            return 3
        }
    }
    print("Device: \(name ?? "(given by --udid)")")

    // under sudo, files must end up owned by the invoking user, in that user's home
    let sudoUser = FileOwnership.sudoUser(environment: ProcessInfo.processInfo.environment)
    func resolved(_ path: String?) -> String? {
        guard let path else { return nil }
        guard let sudoUser else { return path }
        return FileOwnership.expandTilde(path, home: sudoUser.home)
    }
    let dbPath = resolved(options.dbPath)
    let diagnosticPath = resolved(options.diagnostic)
    let metricsPath = resolved(options.metrics)
    var ownedPaths: [String] = []
    var failedHandBack = 0
    func handBack() {
        guard let sudoUser else { return }
        failedHandBack = max(failedHandBack, FileOwnership.giveBack(ownedPaths, to: sudoUser).count)
    }
    func reportHandBack() {
        if failedHandBack > 0 { print("Could not give \(failedHandBack) file(s) back to the user") }
    }
    defer { handBack(); reportHandBack() }

    // store
    var store: Store?
    var deviceHash: String?
    if let dbPath {
        let newDirectories = FileOwnership.missingDirectories(of: dbPath)
        defer {
            ownedPaths += newDirectories + [dbPath, dbPath + "-wal", dbPath + "-shm"]
            handBack()
        }
        do {
            let opened = try Store(path: URL(fileURLWithPath: dbPath))
            deviceHash = try opened.deviceHash(udid: udid)
            store = opened
        } catch {
            print("Unable to open database: \(error)")
            return 1
        }
    }

    // diagnostic file
    var tee: FileHandle?
    if let path = diagnosticPath {
        let newDirectories = FileOwnership.missingDirectories(of: path)
        let handle: FileHandle
        do {
            if sudoUser != nil {
                // never write through a symlink or over an existing file as root
                handle = try FileOwnership.openForWriting(path: path)
            } else {
                guard FileManager.default.createFile(
                    atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]),
                    let opened = FileHandle(forWritingAtPath: path)
                else { throw FileOwnership.OpenError.failed(errno: errno) }
                handle = opened
            }
        } catch {
            print("Unable to create diagnostic file \(path)")
            return 1
        }
        ownedPaths += newDirectories + [path]
        handBack()
        tee = handle
        print("WARNING: raw packets are being written to \(path)")
        print("The file is not deleted automatically")
    }

    // metrics file: always a new file, never through a symlink, owned by the user, mode 0600
    var metricsHandle: FileHandle?
    if let path = metricsPath {
        let newDirectories = FileOwnership.missingDirectories(of: path)
        do {
            metricsHandle = try FileOwnership.openForWriting(path: path)
        } catch {
            print("Unable to create metrics file \(path)")
            return 1
        }
        ownedPaths += newDirectories + [path]
        handBack()
    }

    // before anything is started, so Ctrl-C during start cannot skip the rvictl -x cleanup
    installCaptureSignalHandlers()
    let tools = CaptureTools()
    await CaptureController.cleanupStaleInterfaces(udid: udid, tools: tools)

    let controller = CaptureController(tools: tools)
    let interface: String
    let source: ProcessPacketSource
    do {
        (interface, source) = try await controller.start(udid: udid, tee: tee)
    } catch let error as CaptureError {
        let message = redactUDIDs("\(error)", udid: udid)
        print("Capture failed: \(message)")
        if case .rviStartFailed = error { return 1 }
        return 2
    } catch {
        print("Capture failed: \(redactUDIDs("\(error)", udid: udid))")
        return 1
    }

    let session = CaptureSession(
        id: UUID(), startedAt: Date(), source: "rvi", deviceHash: deviceHash, deviceName: name, watchVersion: "dev")
    let pipeline = CapturePipeline(store: store, session: session, retainFlows: true)
    let stopRequest = StopRequest()
    // run stops the pipeline itself when tcpdump exits on its own; the drop count must be read by then
    await pipeline.setKernelDroppedProvider { await controller.kernelDropped() }

    print("Capturing on \(interface) ... Ctrl-C to stop")

    if let duration = options.duration {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            stopRequest.request()
            await controller.stop()
        }
    }
    await pipeline.startFlushTimer()
    // the handlers only set a flag; this loop turns it into a stop. tcpdump got Ctrl-C itself
    let signalTask = Task {
        while !Task.isCancelled {
            if capturedSignal != 0 {
                stopRequest.request()
                await controller.stop()
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    let statsTask = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            let s = await pipeline.stats
            print("packets \(s.packets)  flows open \(s.flowsOpened - s.flowsClosed)  DNS \(s.dnsObservations)  SNI \(s.sniFound)")
        }
    }

    // metrics rows come from this task, not from the packet path. it sleeps until the writer's next
    // fixed slot (no drift, see MetricsWriter). the final row is written after the pipeline stops
    let metricsTask: Task<MetricsWriter?, Never>? = metricsHandle.map { handle in
        let started = ContinuousClock.now
        let clock: @Sendable () -> TimeInterval = {
            let d = ContinuousClock.now - started
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        return Task {
            var writer = MetricsWriter(handle: handle, clock: clock)
            while !Task.isCancelled {
                if writer.isDue() {
                    // nil until tcpdump has ended and its stderr is read: unknown is empty, never 0
                    writer.write(stats: await pipeline.stats, kernelDropped: await controller.kernelDropped(timeout: 0))
                }
                try? await Task.sleep(nanoseconds: UInt64(max(writer.secondsUntilDue(), 0.01) * 1e9))
            }
            return writer
        }
    }

    // a dead link ends the session as interrupted (6.3): stop the capture, then the pipeline
    let linkLost = StopRequest()
    let watchdogTask = Task {
        _ = await runStallWatchdog(
            StallWatchdog(),
            lastByteAt: { source.lastByteAt },
            processRunning: { source.terminationStatus == nil },
            linkUp: { await LinkProbe.isUp(interface: interface, tools: tools) },
            onLinkDown: {
                linkLost.request()
                await controller.stop()
                await pipeline.setKernelDropped(await controller.kernelDropped())
                await pipeline.stop(reason: .interrupted)
            })
    }

    var exitCode: Int32 = 0
    var failure: Error?
    do {
        _ = try await pipeline.run(source)
    } catch {
        failure = error
    }
    statsTask.cancel()
    signalTask.cancel()
    watchdogTask.cancel()
    await watchdogTask.value
    // tcpdump must be gone and its stderr read before the stats are written, so the drop count is in them
    await controller.stop()
    let kernelDropped = await controller.kernelDropped()
    await pipeline.setKernelDropped(kernelDropped)
    await pipeline.stop(reason: stopRequest.isRequested || failure == nil ? .captureStopped : .interrupted)
    if let metricsTask {
        metricsTask.cancel()
        if var writer = await metricsTask.value {
            writer.write(stats: await pipeline.stats, kernelDropped: kernelDropped)
        }
    }
    handBack()  // WAL files can appear after the store was opened

    // tcpdump noticed the cable pull itself (PH-5: 2-3 s, "The interface disappeared", exit 1)
    if failure != nil, !stopRequest.isRequested, !linkLost.isRequested, await controller.linkLostByTcpdump() {
        linkLost.request()
    }
    if linkLost.isRequested {
        exitCode = 2
        print("Capture ended: \(StallWatchdog.linkLostMessage). Everything received so far was saved")
    } else if let failure, !stopRequest.isRequested {
        exitCode = 2
        print("Capture failed: \(redactUDIDs("\(failure)", udid: udid))")
        for line in await controller.stderrLines { print("  tcpdump: \(line)") }
    } else if failure == nil && !stopRequest.isRequested {
        print("Capture ended: tcpdump stopped on its own")
    }

    let final = await pipeline.stats
    print("\nCapture stopped.")
    await printSummary(pipeline: pipeline, stats: final, final: final, dbPath: dbPath)
    switch source.end {
    case .pcapTrailer?: print("\nStream ended: pcap trailer")
    case .cleanEnd?: print("\nStream ended: clean")
    case nil: print("\nStream ended: no end marker")
    }
    print("tcpdump exit status: \(source.terminationStatus.map(String.init) ?? "unknown")")
    if let line = kernelDroppedLine(kernelDropped) { print(line) }
    return exitCode
}

/// "Kernel dropped: 12 packets  WARNING: ..." for a known count; nil when unknown (tcpdump was killed)
func kernelDroppedLine(_ count: Int?) -> String? {
    guard let count else { return nil }
    if count == 0 { return "Kernel dropped: 0 packets" }
    return "Kernel dropped: \(count) packets  WARNING: the Mac dropped packets, so these totals are too low"
}

func redactUDIDs(_ text: String, udid: String) -> String {
    udid.isEmpty ? text : text.replacingOccurrences(of: udid, with: "<udid>")
}

// MARK: - Report

let reportUsage = """
    usage: tattle report <file.pcap|pcapng> [options]
           tattle report --db <path> --session <id|latest> [options]

      --detail            add process names (names never appear without it)
      --json              print the JSON report instead of the text table
      --scenario <file>   score the capture against a scenario file (numbers only are printed)
      --bands <file>      compare with a band file; exit 3 on a regression
      --write-bands <file> --label <text>
                          write a band file from this report (keeps notes of an existing file)
    with --json and --scenario or --bands the output is {"report", "score", "regressions"}
    exit codes: 0 ok, 2 a reconciliation check failed, 3 a band regression, 1 other error
    """

struct RegressionLine: Encodable {
    var metric: String, kind: String, value: Double, limit: Double, points: Double
    init(_ r: Regression) {
        metric = r.metric
        kind = r.kind.rawValue
        value = r.value
        limit = r.limit
        points = r.points
    }
}

struct ReportBundle: Encodable {
    var report: QualityReport
    var score: ScenarioScore?
    var regressions: [RegressionLine]?
}

/// returns the exit code. the report goes to stdout only
func runReport(_ args: [String]) async -> Int32 {
    var file: String?, db: String?, session: String?
    var scenarioPath: String?, bandsPath: String?, writeBandsPath: String?, label: String?
    var detail = false, json = false
    var i = 0
    func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n" + reportUsage + "\n").utf8))
        return 1
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--detail": detail = true
        case "--json": json = true
        case "--db", "--session", "--scenario", "--bands", "--write-bands", "--label":
            guard i + 1 < args.count else { return fail("\(a) needs a value") }
            i += 1
            switch a {
            case "--db": db = args[i]
            case "--session": session = args[i]
            case "--scenario": scenarioPath = args[i]
            case "--bands": bandsPath = args[i]
            case "--write-bands": writeBandsPath = args[i]
            default: label = args[i]
            }
        default:
            guard !a.hasPrefix("--"), file == nil else { return fail("unexpected argument: \(a)") }
            file = a
        }
        i += 1
    }
    if writeBandsPath != nil && label == nil { return fail("--write-bands needs --label") }
    if writeBandsPath != nil && bandsPath != nil { return fail("use --bands or --write-bands, not both") }
    let options = ReportOptions(detail: detail)
    let report: QualityReport
    var flows: [Flow] = [], domains: [DomainObservation] = []
    var gaveUpLine: String?
    do {
        switch (file, db) {
        case (let path?, nil):
            guard session == nil else { return fail("--session needs --db") }
            let pipeline = CapturePipeline(store: nil, session: newSession(), retainFlows: true, retainDomains: true)
            let stats = try await pipeline.run(FilePacketSource(url: URL(fileURLWithPath: path)))
            await pipeline.stop(reason: .captureStopped)
            let snapshot = PipelineSnapshot(
                packets: stats.packets, decoded: stats.decoded, skipped: stats.skipped,
                malformed: stats.malformed, droppedNoPort: stats.droppedNoPort)
            gaveUpLine = gaveUpSummary(stats) + "\n" + capsSummary(await pipeline.stats)
            flows = await pipeline.flowsSnapshot()
            domains = await pipeline.domainsSnapshot()
            let final = await pipeline.stats
            let sessionStats = SessionStats(
                gapCount: final.gapCount, maxGapMs: Int((final.maxGap * 1000).rounded()),
                saveFailures: final.saveFailures, unsavedFlows: final.unsavedFlows)
            report = ReportBuilder.build(
                flows: flows, domains: domains, pipeline: snapshot, session: sessionStats, options: options)
        case (nil, let dbPath?):
            guard let session else { return fail("--db needs --session <id|latest>") }
            let store = try Store(path: URL(fileURLWithPath: dbPath))
            let all = try store.sessions()
            let chosen: CaptureSession?
            if session == "latest" {
                chosen = all.last
            } else {
                guard let id = UUID(uuidString: session) else { return fail("not a session id: \(session)") }
                chosen = all.first { $0.id == id }
            }
            guard let chosen else {
                FileHandle.standardError.write(Data("no such session\n".utf8))
                return 1
            }
            // no pipeline stats are stored: packetsRead and decodedAccounted are skipped
            flows = try store.flows(session: chosen.id)
            domains = try store.domains(session: chosen.id)
            report = ReportBuilder.build(
                flows: flows, domains: domains, pipeline: nil, session: try store.sessionStats(id: chosen.id),
                options: options)
        default:
            return fail("give either a capture file or --db")
        }
        var score: ScenarioScore?
        if let scenarioPath {
            score = try Scenario.load(URL(fileURLWithPath: scenarioPath)).score(flows: flows, domains: domains)
        }
        var regressions: [Regression]?
        if let bandsPath {
            let bands = try BandsFile.load(URL(fileURLWithPath: bandsPath))
            if let score, score.scenario != bands.scenario {
                return fail("scenario file and band file name different scenarios")
            }
            regressions = Ratchet.check(report: report, bands: bands)
        }
        if let writeBandsPath, let label {
            let url = URL(fileURLWithPath: writeBandsPath)
            let previous = try? BandsFile.load(url)
            let name = score?.scenario ?? previous?.scenario ?? url.deletingPathExtension().lastPathComponent
            let bands = Bands.make(from: report, scenario: name, baselineLabel: label, previous: previous)
            try Data(bands.json().utf8).write(to: url, options: .atomic)
            FileHandle.standardError.write(Data("wrote bands to \(writeBandsPath)\n".utf8))
        }
        if json && (score != nil || regressions != nil) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let out = ReportBundle(
                report: report, score: score,
                regressions: regressions?.map { RegressionLine($0) })
            print(String(decoding: try encoder.encode(out), as: UTF8.self))
        } else if json {
            print(try report.json())
        } else {
            print(ReportRendering.text(report), terminator: "")
            if let gaveUpLine { print("\n" + gaveUpLine) }
            if let score { print("\n" + score.text(), terminator: "") }
            if let regressions {
                print("\nBands: " + (regressions.isEmpty ? "no regressions" : "REGRESSION"))
                for r in regressions { print(r.description) }
            }
        }
        if !report.reconciliation.ok { return 2 }
        if let regressions, !regressions.isEmpty { return 3 }
    } catch {
        FileHandle.standardError.write(Data("report failed: \(error)\n".utf8))
        return 1
    }
    return 0
}

// MARK: - Companies

let companiesUsage = """
    usage: tattle companies coverage <file.pcap|pcapng> [options]
           tattle companies coverage --db <path> --session <id|latest> [options]

      --json              print the coverage report as JSON (numbers and keys only)
      --bands <file>      compare with a coverage band file; exit 3 when coverage is below its floor
      --write-bands <file> --label <text>
                          write a band file from this run (keeps the notes of an existing file)
      --unmatched-out <file>
                          write the most frequent unidentified registrable domains to a local file
                          (tab separated: flows, bytes, domain; mode 600, new file only). names go only to
                          that file, never to the screen. refused inside a git work tree
      --sources <list>   curated (default, the frozen baseline) or curated,trackerList; --write-bands needs curated
    sources: the curated list only unless --sources is given (the frozen baseline). exit codes: 0 ok, 3 below the floor, 1 error

    usage: tattle companies agreement --report <App_Privacy_Report.ndjson> [--disagreements-out <file>] [--second <source>]
      classifies every domain of the report with the curated list alone and with the second source alone
      (neither sees the other) and prints counts only. IP addresses are excluded and counted
      --second <source>   appleOwner (default) or trackerList: the source compared with the curated list
      --disagreements-out <file>
                          write every disagreement and every name only the second source named to a local file (tab
                          separated; mode 600, new file only; refused inside a git work tree)

    usage: tattle companies audit --references <dir> [--report <file>] [--captures <dir>]
                                  [--contradictions-out <file>] [--domains-out <file>]
      compares our parent company for every domain we label with two independent references in <dir>
      (ddg-domain-map.json and cert-orgs.tsv, made by scripts/audit-references.sh) and prints numbers only:
      per stratum n, confirmed, contradicted, unverifiable and the 95% upper bound of the contradiction rate.
      strata: the curated list's own entries, the capture folder's confirmed names, the report's named domains
      --contradictions-out <file>
                          the contradicted rows for a decision by hand (tab separated; mode 600, new file only;
                          refused inside a git work tree)
      --domains-out <file>
                          the audited registrable domains, one per line, for the certificate fetcher (same rules)
    """

/// coverage of a capture or a saved session by the company sources. read-time only: it reads flows and
/// names already saved and never touches the packet path. returns the exit code
func runCompanies(_ args: [String]) async -> Int32 {
    func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n" + companiesUsage + "\n").utf8))
        return 1
    }
    if args.first == "agreement" { return runAgreement(Array(args.dropFirst()), fail: fail) }
    if args.first == "audit" { return await runAudit(Array(args.dropFirst()), fail: fail) }
    guard args.first == "coverage" else { return fail("unknown companies command") }
    var file: String?, db: String?, session: String?
    var bandsPath: String?, writeBandsPath: String?, label: String?, unmatchedOut: String?
    var json = false
    var sources: [LabelSource] = [.curated]
    var i = 1
    while i < args.count {
        let a = args[i]
        switch a {
        case "--json": json = true
        case "--db", "--session", "--bands", "--write-bands", "--label", "--unmatched-out", "--sources":
            guard i + 1 < args.count else { return fail("\(a) needs a value") }
            i += 1
            switch a {
            case "--db": db = args[i]
            case "--session": session = args[i]
            case "--bands": bandsPath = args[i]
            case "--write-bands": writeBandsPath = args[i]
            case "--unmatched-out": unmatchedOut = args[i]
            case "--sources":
                // only the frozen baseline or the bundled order: the AdGuard list never comes before the curated list (1.6 D)
                switch args[i] {
                case "curated": sources = [.curated]
                case "curated,trackerList": sources = [.curated, .trackerList]
                default: return fail("--sources takes curated or curated,trackerList")
                }
            default: label = args[i]
            }
        default:
            guard !a.hasPrefix("--"), file == nil else { return fail("unexpected argument: \(a)") }
            file = a
        }
        i += 1
    }
    if writeBandsPath != nil && label == nil { return fail("--write-bands needs --label") }
    if writeBandsPath != nil && bandsPath != nil { return fail("use --bands or --write-bands, not both") }
    // band files are the curated-only baseline: a floor raised by another source would fail the next curated run
    if writeBandsPath != nil && sources != [LabelSource.curated] { return fail("--write-bands works only with the curated list (the frozen baseline)") }
    // the file holds real domain names: never inside a git work tree, checked before any work is done
    if let unmatchedOut, FileOwnership.gitWorkTreeRoot(containing: unmatchedOut) != nil {
        return fail("--unmatched-out must point outside the git work tree: the file holds real domain names")
    }
    do {
        var flows: [Flow] = [], domains: [DomainObservation] = []
        switch (file, db) {
        case (let path?, nil):
            guard session == nil else { return fail("--session needs --db") }
            let pipeline = CapturePipeline(store: nil, session: newSession(), retainFlows: true, retainDomains: true)
            _ = try await pipeline.run(FilePacketSource(url: URL(fileURLWithPath: path)))
            await pipeline.stop(reason: .captureStopped)
            flows = await pipeline.flowsSnapshot()
            domains = await pipeline.domainsSnapshot()
        case (nil, let dbPath?):
            guard let session else { return fail("--db needs --session <id|latest>") }
            let store = try Store(path: URL(fileURLWithPath: dbPath))
            let all = try store.sessions()
            let chosen: CaptureSession?
            if session == "latest" {
                chosen = all.last
            } else {
                guard let id = UUID(uuidString: session) else { return fail("not a session id: \(session)") }
                chosen = all.first { $0.id == id }
            }
            guard let chosen else {
                FileHandle.standardError.write(Data("no such session\n".utf8))
                return 1
            }
            flows = try store.flows(session: chosen.id)
            domains = try store.domains(session: chosen.id)
        default:
            return fail("give either a capture file or --db")
        }
        let result = Coverage.build(flows: flows, index: HostnameIndex(domains, flows: flows), sources: sources)
        var regressions: [CoverageRegression]?
        if let bandsPath {
            regressions = CoverageRatchet.check(
                report: result.report, bands: try CoverageBands.load(URL(fileURLWithPath: bandsPath)))
        }
        if let writeBandsPath, let label {
            let url = URL(fileURLWithPath: writeBandsPath)
            let previous = try? CoverageBands.load(url)
            let name = previous?.scenario ?? url.deletingPathExtension().lastPathComponent
            let bands = CoverageBands.make(from: result.report, scenario: name, baselineLabel: label, previous: previous)
            try Data(bands.json().utf8).write(to: url, options: .atomic)
            FileHandle.standardError.write(Data("wrote bands to \(writeBandsPath)\n".utf8))
        }
        if let unmatchedOut {
            let lines = result.unmatched.prefix(200).map { "\($0.flows)\t\($0.bytes)\t\($0.domain)" }
            // created 0600 from the first byte; refuses an existing file or a symlink
            let handle: FileHandle
            do { handle = try FileOwnership.openForWriting(path: unmatchedOut) } catch {
                return fail("cannot create the --unmatched-out file (it must be a new file): \(error)")
            }
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            try handle.close()
            FileHandle.standardError.write(Data("wrote \(lines.count) unidentified domains to a local file\n".utf8))
        }
        print(json ? try result.report.json() : result.report.text(), terminator: "")
        if let regressions {
            if !json { print("\nBands: " + (regressions.isEmpty ? "no regressions" : "REGRESSION")) }
            for r in regressions { FileHandle.standardError.write(Data((r.description + "\n").utf8)) }
            if !regressions.isEmpty { return 3 }
        }
    } catch {
        FileHandle.standardError.write(Data("companies coverage failed: \(error)\n".utf8))
        return 1
    }
    return 0
}

/// the agreement matrix of the curated list and Apple's owner string over one imported report's domains
func runAgreement(_ args: [String], fail: (String) -> Int32) -> Int32 {
    var report: String?, out: String?
    var second = LabelSource.appleOwner
    var i = 0
    while i < args.count {
        guard ["--report", "--disagreements-out", "--second"].contains(args[i]), i + 1 < args.count else { return fail("bad argument: \(args[i])") }
        switch args[i] {
        case "--report": report = args[i + 1]
        case "--second":
            guard args[i + 1] == "appleOwner" || args[i + 1] == "trackerList", let source = LabelSource(rawValue: args[i + 1]) else {
                return fail("--second takes appleOwner or trackerList")
            }
            second = source
        default: out = args[i + 1]
        }
        i += 2
    }
    guard let report else { return fail("agreement needs --report <file>") }
    // the file holds real domain names: never inside a git work tree, checked before any work is done
    if let out, FileOwnership.gitWorkTreeRoot(containing: out) != nil {
        return fail("--disagreements-out must point outside the git work tree: the file holds real domain names")
    }
    do {
        let observations = try ReportImporter.domainOwners(file: URL(fileURLWithPath: report))
        let (matrix, rows) = Agreement.measure(observations, classifier: CompanyClassifier(), second: second)
        if let out {
            let header = second == .trackerList
                ? "kind\tdomain\tcurated parent\tcurated category\ttracker company\ttracker parent"
                : "kind\tdomain\tcurated parent\tcurated category\tapple owner\taliased parent"
            let lines = [header] + rows.map {
                [$0.kind.rawValue, $0.domain, $0.firstParent ?? "-", $0.firstCategory?.rawValue ?? "-", $0.secondOwner ?? "-", $0.secondParent ?? "-"]
                    .joined(separator: "\t")
            }
            // created 0600 from the first byte; refuses an existing file or a symlink
            let handle: FileHandle
            do { handle = try FileOwnership.openForWriting(path: out) } catch {
                return fail("cannot create the --disagreements-out file (it must be a new file): \(error)")
            }
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            try handle.close()
            FileHandle.standardError.write(Data("wrote \(rows.count) rows to a local file\n".utf8))
        }
        print(matrix.text(), terminator: "")
    } catch {
        FileHandle.standardError.write(Data("companies agreement failed: \(error)\n".utf8))
        return 1
    }
    return 0
}

/// the accuracy audit of the company classification against two independent references (OD13)
func runAudit(_ args: [String], fail: (String) -> Int32) async -> Int32 {
    var references: String?, report: String?, captures: String?, contradictionsOut: String?, domainsOut: String?
    var i = 0
    while i < args.count {
        guard ["--references", "--report", "--captures", "--contradictions-out", "--domains-out"].contains(args[i]), i + 1 < args.count
        else { return fail("bad argument: \(args[i])") }
        switch args[i] {
        case "--references": references = args[i + 1]
        case "--report": report = args[i + 1]
        case "--captures": captures = args[i + 1]
        case "--contradictions-out": contradictionsOut = args[i + 1]
        default: domainsOut = args[i + 1]
        }
        i += 2
    }
    guard let references else { return fail("audit needs --references <dir>") }
    // the files hold real domain names: never inside a git work tree, checked before any work is done
    for out in [contradictionsOut, domainsOut].compactMap({ $0 }) where FileOwnership.gitWorkTreeRoot(containing: out) != nil {
        return fail("output files must point outside the git work tree: they hold real domain names")
    }
    // fixed messages, never the path or the system's error text (both can carry a path)
    func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
    guard isFolder(references) else { return fail("the references folder is missing or not a folder") }
    if let captures, !isFolder(captures) { return fail("the captures folder is missing or not a folder") }
    enum AuditStep { case entityMap, captures, report, output }
    var step = AuditStep.entityMap
    do {
        let dir = URL(fileURLWithPath: references, isDirectory: true)
        var maps = ReferenceMaps()
        if let data = try? Data(contentsOf: dir.appendingPathComponent("ddg-domain-map.json")) {
            maps.entities = try ReferenceMaps.parseEntityMap(data)
        }
        step = .captures
        if let text = try? String(contentsOf: dir.appendingPathComponent("cert-orgs.tsv"), encoding: .utf8) {
            maps.certificates = ReferenceMaps.parseCertificateCache(text)
        }
        let classifier = CompanyClassifier()
        let aliases = ReferenceAliases.loadBundled(appleOwners: classifier.appleOwners)

        // our parent for a label: the curated parent, or Apple's owner string made comparable
        func subject(_ label: CompanyLabel) -> AuditSubject? {
            guard label.isMatched, let domain = label.registrableDomain, !isIPAddress(label.hostname) else { return nil }
            guard let parent = label.parent ?? label.company.map(classifier.appleOwners.comparableParent(forOwner:)) else { return nil }
            return AuditSubject(domain: domain, parent: parent, company: label.company, category: label.category)
        }

        var strata: [(name: String, subjects: [AuditSubject])] = []
        strata.append(("curated list entries", classifier.curated.entries.compactMap { entry in
            guard let domain = registrableDomain(of: entry.domain) else { return nil }
            return AuditSubject(domain: domain, parent: entry.parent, company: entry.company, category: entry.category)
        }))
        var capturesSubjects: [AuditSubject] = [], reportSubjects: [AuditSubject] = []
        if let captures {
            let files = try FileManager.default.contentsOfDirectory(atPath: captures).filter { $0.hasSuffix(".pcapng") || $0.hasSuffix(".pcap") }.sorted()
            for file in files {
                let pipeline = CapturePipeline(store: nil, session: newSession(), retainFlows: true, retainDomains: true)
                _ = try await pipeline.run(FilePacketSource(url: URL(fileURLWithPath: captures).appendingPathComponent(file)))
                await pipeline.stop(reason: .captureStopped)
                let flows = await pipeline.flowsSnapshot()
                let index = HostnameIndex(await pipeline.domainsSnapshot(), flows: flows)
                var cache = LabelCache(classifier: classifier)
                for flow in flows where flow.key.remotePort == Coverage.port {
                    // only a name seen in the connection itself counts, never a hint
                    guard let result = FlowLabels.label(for: flow, index: index, cache: &cache), !result.isPossible,
                          let found = subject(result.label) else { continue }
                    capturesSubjects.append(found)
                }
            }
        }
        step = .report
        if let report {
            for (domain, owner) in try ReportImporter.domainOwners(file: URL(fileURLWithPath: report)) {
                if let found = subject(classifier.classify(hostname: domain, appleOwner: owner)) { reportSubjects.append(found) }
            }
        }
        if captures != nil { strata.append(("capture confirmed names", capturesSubjects)) }
        if report != nil { strata.append(("privacy report named domains", reportSubjects)) }
        if captures != nil && report != nil { strata.append(("owner data together", capturesSubjects + reportSubjects)) }

        var results: [AuditStratum] = [], allRows: [AuditRow] = [], allSubjects: [AuditSubject] = []
        for (name, subjects) in strata {
            let rows = Audit.rows(subjects, references: maps, aliases: aliases)
            results.append(Audit.summarise(name: name, rows: rows))
            allRows += rows
            allSubjects += subjects
        }
        func writeLocal(_ path: String, _ lines: [String], what: String) throws -> Int32? {
            // created 0600 from the first byte; refuses an existing file or a symlink
            guard let handle = try? FileOwnership.openForWriting(path: path) else {
                return fail("cannot create the \(what) file (it must be a new file)")
            }
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            try handle.close()
            return nil
        }
        step = .output
        if let domainsOut {
            let domains = Audit.domains(allSubjects)
            if let code = try writeLocal(domainsOut, domains, what: "--domains-out") { return code }
            FileHandle.standardError.write(Data("wrote \(domains.count) domains to a local file\n".utf8))
        }
        if let contradictionsOut {
            let lines = Audit.contradictionLines(allRows)
            if let code = try writeLocal(contradictionsOut, lines, what: "--contradictions-out") { return code }
            FileHandle.standardError.write(Data("wrote \(lines.count - 1) contradicted rows to a local file\n".utf8))
        }
        print(Audit.report(results), terminator: "")
    } catch {
        let reason: String
        if let failure = error as? ReportImportFailure {
            reason = failure.message  // counts only, never a path
        } else {
            switch step {
            case .entityMap: reason = "the entity map in the references folder could not be read"
            case .captures: reason = "a capture in the captures folder could not be read"
            case .report: reason = "the report file could not be read"
            case .output: reason = "a local output file could not be written"
            }
        }
        FileHandle.standardError.write(Data("companies audit failed: \(reason)\n".utf8))
        return 1
    }
    return 0
}

// MARK: - Apps

let appsUsage = """
    usage: tattle apps coverage <file.pcap|pcapng> [--unmatched-out <file>]

    prints how many distinct process names of the capture the app table knows (counts only).
      --unmatched-out <file>
                          write the process names that did not join to a local file (mode 600, new
                          file only, refused inside a git work tree). names go only to that file
    """

func runApps(_ args: [String]) async -> Int32 {
    func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n" + appsUsage + "\n").utf8))
        return 2
    }
    guard args.first == "coverage" else { return fail("unknown apps command") }
    var file: String?, unmatchedOut: String?
    var i = 1
    while i < args.count {
        if args[i] == "--unmatched-out" {
            i += 1
            guard i < args.count else { return fail("--unmatched-out needs a path") }
            unmatchedOut = args[i]
        } else if args[i].hasPrefix("--") || file != nil {
            return fail("unexpected argument")
        } else {
            file = args[i]
        }
        i += 1
    }
    guard let file else { return fail("give a capture file") }
    if let unmatchedOut, FileOwnership.gitWorkTreeRoot(containing: unmatchedOut) != nil {
        return fail("--unmatched-out must point outside the git work tree: the file holds real process names")
    }
    do {
        let pipeline = CapturePipeline(store: nil, session: newSession(), retainFlows: true, retainDomains: false)
        _ = try await pipeline.run(FilePacketSource(url: URL(fileURLWithPath: (file as NSString).expandingTildeInPath)))
        await pipeline.stop(reason: .captureStopped)
        let names = await pipeline.flowsSnapshot().flatMap { appNames($0) }
        try printJoinRate(
            AppTable.bundled.joinRate(processNames: names),
            what: "Capture process names", unjoinedOut: unmatchedOut)
        return 0
    } catch {
        FileHandle.standardError.write(Data("apps coverage failed: \(error)\n".utf8))
        return 1
    }
}

// MARK: - Import report

let importReportUsage = """
    usage: tattle import-report <file> [--db <path>]
           tattle import-report <file> --join-rate [--unjoined-out <file>]

      --join-rate         do not import: print how many apps of the report the app table knows
                          (counts only). nothing is stored
      --unjoined-out <file>
                          with --join-rate, write the report's unjoined bundle ids to a local file
                          (mode 600, new file only, refused inside a git work tree)
    """

/// counts only: how many distinct ids joined the app table. the ids that did not join go only to `unjoinedOut`
func printJoinRate(_ rate: JoinRate, what: String, unjoinedOut: String?) throws {
    print("\(what): \(rate.joined) of \(rate.total) joined the app table (\(rate.total - rate.joined) not joined)")
    if let unjoinedOut {
        // created 0600 from the first byte; refuses an existing file or a symlink
        let handle = try FileOwnership.openForWriting(path: unjoinedOut)
        try handle.write(contentsOf: Data((rate.notJoined.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        FileHandle.standardError.write(Data("wrote \(rate.notJoined.count) unjoined ids to a local file\n".utf8))
    }
}

func runImportReport(_ args: [String]) -> Int32 {
    func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n" + importReportUsage + "\n").utf8))
        return 2
    }
    var file: String?
    var db: String?
    var joinRate = false
    var unjoinedOut: String?
    var i = 0
    while i < args.count {
        if args[i] == "--db" {
            i += 1
            guard i < args.count else { return fail("--db needs a path") }
            db = args[i]
        } else if args[i] == "--join-rate" {
            joinRate = true
        } else if args[i] == "--unjoined-out" {
            i += 1
            guard i < args.count else { return fail("--unjoined-out needs a path") }
            unjoinedOut = args[i]
        } else if args[i].hasPrefix("--") {
            return fail("unknown option")
        } else if file == nil {
            file = args[i]
        } else {
            return fail("give one file")
        }
        i += 1
    }
    guard let file else { return fail("give the report file") }
    if unjoinedOut != nil && !joinRate { return fail("--unjoined-out needs --join-rate") }
    if joinRate {
        if db != nil { return fail("--join-rate stores nothing, so --db does not apply") }
        if let unjoinedOut, FileOwnership.gitWorkTreeRoot(containing: unjoinedOut) != nil {
            return fail("--unjoined-out must point outside the git work tree: the file holds real app ids")
        }
        do {
            let ids = try ReportImporter.appIds(file: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
            try printJoinRate(AppTable.bundled.joinRate(bundleIds: ids), what: "Report apps", unjoinedOut: unjoinedOut)
            return 0
        } catch {
            print("\(error)")
            return 1
        }
    }

    // under sudo, new database files must still belong to the invoking user
    let sudoUser = FileOwnership.sudoUser(environment: ProcessInfo.processInfo.environment)
    func resolved(_ path: String) -> String {
        guard let sudoUser else { return (path as NSString).expandingTildeInPath }
        return FileOwnership.expandTilde(path, home: sudoUser.home)
    }
    let dbPath = db.map(resolved) ?? Store.defaultPath().path
    let newDirectories = FileOwnership.missingDirectories(of: dbPath)
    var failedHandBack = 0
    defer {
        if let sudoUser {
            failedHandBack = FileOwnership.giveBack(newDirectories + [dbPath, dbPath + "-wal", dbPath + "-shm"], to: sudoUser).count
            if failedHandBack > 0 { print("Could not give \(failedHandBack) file(s) back to the user") }
        }
    }
    let store: Store
    do { store = try Store(path: URL(fileURLWithPath: dbPath)) } catch {
        print("Unable to open database.")
        return 1
    }
    do {
        let summary = try ReportImporter.run(file: URL(fileURLWithPath: resolved(file)), store: store)
        for line in summary.lines { print(line) }
        switch summary.outcome {
        case .stored, .duplicate: return 0
        case .empty, .olderThanStored, .olderThanRetention: return 1
        }
    } catch {
        print("\(error)")
        return 1
    }
}

// MARK: - Main

let arguments = CommandLine.arguments

if arguments.count >= 2 && arguments[1] == "capture" {
    exit(await runCapture(Array(arguments.dropFirst(2))))
}

if arguments.count >= 2 && arguments[1] == "import-report" {
    exit(runImportReport(Array(arguments.dropFirst(2))))
}

if arguments.count >= 2 && arguments[1] == "apps" {
    exit(await runApps(Array(arguments.dropFirst(2))))
}

if arguments.count >= 2 && arguments[1] == "metrics" {
    exit(runMetrics(Array(arguments.dropFirst(2))))
}

if arguments.count >= 2 && arguments[1] == "companies" {
    exit(await runCompanies(Array(arguments.dropFirst(2))))
}

if arguments.count >= 2 && arguments[1] == "report" {
    exit(await runReport(Array(arguments.dropFirst(2))))
}

if arguments.count == 3 && arguments[1] == "read" {
    printCaptureSummary(path: arguments[2])
    exit(0)
}

if arguments.count == 3 && arguments[1] == "flows" {
    await printFlows(path: arguments[2], dbPath: nil)
    exit(0)
}

if arguments.count == 5 && arguments[1] == "flows" && arguments[3] == "--db" {
    await printFlows(path: arguments[2], dbPath: arguments[4])
    exit(0)
}

/// `tattle globe-preview <out.png> [lat,lon] [zoom]`: draws the globe with made-up connections to real head
/// offices from the bundled table, for choosing and checking the look without the app. no capture data is read.
/// the start point is the middle of the contiguous US, never a real person's place
@MainActor
func runGlobePreview(_ args: [String]) {
    guard let out = args.first else {
        print("usage: tattle globe-preview <out.png> [lat,lon] [zoom]")
        exit(2)
    }
    let start = GeoPoint(latitude: 39.83, longitude: -98.58)
    // looking from a little south of the start, so lines that rise off the globe show their curve
    var centre = GeoPoint(latitude: start.latitude - 15, longitude: start.longitude)
    if args.count > 1 {
        let n = args[1].split(separator: ",").compactMap { Double($0) }
        if n.count == 2 { centre = GeoPoint(latitude: n[0], longitude: n[1]) }
    }
    let zoom = args.count > 2 ? Double(args[2]) ?? 0.45 : 0.45
    guard let table = try? HeadOfficeTable.loadBundled() else {
        print("the head-office data could not be read")
        exit(1)
    }
    // made-up traffic: how many connections went to each company
    let traffic: [(String, Int)] = [
        ("Alphabet", 40), ("Meta Platforms", 18), ("Amazon", 12), ("Apple", 25), ("Microsoft", 6), ("AppLovin", 9),
        ("Cloudflare", 5), ("ByteDance", 7), ("Criteo", 3), ("Spotify", 2), ("Tencent", 1), ("Adform", 1),
        ("Unity", 4), ("Snap", 3), ("Yandex", 1), ("Atlassian", 1),
    ]
    var lines = MapLines()
    for (company, n) in traffic {
        let office = table.office(forParent: company)
        for _ in 0..<n {
            lines.add(company: office == nil ? nil : company,
                      place: office.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) }, city: office?.city ?? "")
        }
    }
    let view = GlobeView(centre: centre, zoom: zoom, lines: lines.lines, start: start)
        .frame(width: 1200, height: 800)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        print("could not draw the preview")
        exit(1)
    }
    do { try png.write(to: URL(fileURLWithPath: out)) } catch {
        print("could not write \(out)")
        exit(1)
    }
    print("wrote \(out): \(lines.lines.count) lines, \(lines.notDrawn) connections not drawn")
}

if arguments.count >= 3 && arguments[1] == "globe-preview" {
    await runGlobePreview(Array(arguments.dropFirst(2)))
    exit(0)
}

if arguments.count == 3 && arguments[1] == "bench" {
    await runBench(path: arguments[2])
    exit(0)
}

print("Checking iPhone connection...\n")

let usbConnected = isIPhoneConnectedViaUSB()

guard usbConnected else {
    print("USB: No iPhone detected")
    print("\nResult: Connect an iPhone via USB.")
    exit(1)
}

print("USB: iPhone detected")

do {
    // the first wired device: nothing about a specific phone is hardcoded
    guard let device = try? await DeviceLookup.wiredDevices().first else {
        print("CoreDevice: no wired device found")
        exit(1)
    }
    let response = try getDeviceInfo(udid: device.udid)

    guard response.info.outcome == "success",
          let details = response.result,
          let connection = details.connectionProperties else {
        print("CoreDevice: Device information unavailable")
        exit(1)
    }

    print("\nCoreDevice:")
    print("Pairing: \(connection.pairingState ?? "unknown")")
    print("Transport: \(connection.transportType ?? "unknown")")
    print("Tunnel: \(connection.tunnelState ?? "unknown")")
    print("Device: \(details.deviceProperties?.name ?? "unknown")")
    print("Developer Mode: \(details.deviceProperties?.developerModeStatus ?? "unknown")")

    if usbConnected &&
       connection.pairingState == "paired" &&
       connection.transportType == "wired" &&
       connection.tunnelState == "connected" {
        print("\nResult: iPhone is connected and available over USB.")
    } else {
        print("\nResult: USB and CoreDevice connection checks do not both indicate an available wired device.")
    }

} catch {
    print("\nCoreDevice error: \(error.localizedDescription)")
}



