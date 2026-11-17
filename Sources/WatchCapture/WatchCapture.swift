
import Foundation
import IOKit
import IOKit.usb
import Attribution
import Capture
import Dispatch
import Flows
import PCAPNG
import Pipeline
import Storage

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
            domain: "WatchCapture",
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
    case .app(let name, let pids): text = "\(name) (\(pids.count) pid\(pids.count == 1 ? "" : "s"))"
    case .onBehalfOf(let app, let via): text = "\(app) via \(via)"
    case .system(let name): text = "system \(name)"
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

func flowLine(_ flow: Flow) -> String {
    let timeFormatter = ISO8601DateFormatter()
    timeFormatter.formatOptions = [.withTime, .withColonSeparatorInTime]
    let key = flow.key
    let transport = key.transport == .tcp ? "tcp" : "udp"
    var line = "  \(timeFormatter.string(from: flow.firstSeen))  \(flow.interface)  \(transport)  "
    line += "\(key.remoteAddress.description):\(key.remotePort)  in \(flow.ipBytesIn) out \(flow.ipBytesOut)"
    if let name = flow.serverName { line += "  \(name)" }
    line += "  -> \(describe(Attributor.attribute(flow.tally)))"
    return line
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
    let pipeline = CapturePipeline(store: store, session: newSession(), retainFlows: true)
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
    print("\nTop flows by IP bytes:")
    for flow in flows.sorted(by: { $0.ipBytesIn + $0.ipBytesOut > $1.ipBytesIn + $1.ipBytesOut }).prefix(20) {
        print(flowLine(flow))
    }

    print("\nDomains: DNS answers \(stats.dnsObservations)  SNI found \(stats.sniFound)")
    print("Handshake buffers gave up: TLS \(await pipeline.tlsGaveUp)  QUIC \(await pipeline.quicGaveUp)")

    let multi = flows.filter { appNames($0).count > 1 }
        .sorted { $0.ipBytesIn + $0.ipBytesOut > $1.ipBytesIn + $1.ipBytesOut }
    print("\nFlows with more than one app name: \(multi.count)")
    for flow in multi {
        print(flowLine(flow))
        print("      names: \(appNames(flow).joined(separator: ", "))")
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


// MARK: - capture command

let captureUsage = """
    usage: sudo WatchCapture capture (--udid <udid> | --device <name>) [--db <path>] [--duration <seconds>] [--diagnostic <file.pcapng>]

      --udid <udid>          device to capture, skips the devicectl lookup
      --device <name>        pick the first wired device from devicectl (only the name is printed)
      --db <path>            save flows and domains to this database
      --duration <seconds>   stop automatically after this many seconds
      --diagnostic <file>    also write the raw pcapng stream to this file (raw packets on disk)

    exit codes: 0 stopped, 1 rvi failed, 2 tcpdump failed, 3 device not found, 64 bad arguments
    """

struct CaptureOptions {
    var udid: String?
    var device: String?
    var dbPath: String?
    var duration: Double?
    var diagnostic: String?
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
            guard let device = devices.first else { throw DeviceLookupError.failed("devicectl lists no wired device") }
            udid = device.udid
            name = device.name
        } catch {
            print("Device not found: \(redactUDIDs("\(error)", udid: ""))")
            return 3
        }
    }
    print("Device: \(name ?? "(given by --udid)")")

    // store
    var store: Store?
    var deviceHash: String?
    if let dbPath = options.dbPath {
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
    if let path = options.diagnostic {
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forWritingAtPath: path) else {
            print("Unable to create diagnostic file \(path)")
            return 1
        }
        tee = handle
        print("WARNING: raw packets are being written to \(path)")
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

    var exitCode: Int32 = 0
    var failure: Error?
    do {
        _ = try await pipeline.run(source)
    } catch {
        failure = error
    }
    statsTask.cancel()
    signalTask.cancel()
    await pipeline.stop(reason: stopRequest.isRequested || failure == nil ? .captureStopped : .interrupted)
    await controller.stop()

    if let failure, !stopRequest.isRequested {
        exitCode = 2
        print("Capture failed: \(redactUDIDs("\(failure)", udid: udid))")
        for line in await controller.stderrLines { print("  tcpdump: \(line)") }
    } else if failure == nil && !stopRequest.isRequested {
        print("Capture ended: tcpdump stopped on its own")
    }

    let final = await pipeline.stats
    print("\nCapture stopped.")
    await printSummary(pipeline: pipeline, stats: final, final: final, dbPath: options.dbPath)
    switch source.end {
    case .pcapTrailer?: print("\nStream ended: pcap trailer")
    case .cleanEnd?: print("\nStream ended: clean")
    case nil: print("\nStream ended: no end marker")
    }
    print("tcpdump exit status: \(source.terminationStatus.map(String.init) ?? "unknown")")
    return exitCode
}

func redactUDIDs(_ text: String, udid: String) -> String {
    udid.isEmpty ? text : text.replacingOccurrences(of: udid, with: "<udid>")
}

// MARK: - Main

let arguments = CommandLine.arguments

if arguments.count >= 2 && arguments[1] == "capture" {
    exit(await runCapture(Array(arguments.dropFirst(2))))
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



