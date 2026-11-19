import Foundation
import PCAPNG
import Pipeline
import Storage
import Testing
import TestSupport

@testable import Capture

private let udid = "00008110-FAKEUDID0001"

// a temp dir with fake rvictl and tcpdump scripts; both append their argv to one log
private struct Fake {
    let dir: URL
    var tools = CaptureTools()
    var log: URL { dir.appendingPathComponent("log.txt") }

    var logText: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    // tcpdumpBody runs after the argv is logged
    init(rvictl: String? = nil, tcpdumpBody: (URL) throws -> String) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("capture-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rvictlScript = """
            #!/bin/sh
            echo "rvictl $@" >> "\(log.path)"
            case "$1" in
            -s) \(rvictl ?? "echo \"Starting device $2 [SUCCEEDED] with interface rvi9\"") ;;
            -l) if [ -f "\(dir.path)/listed" ]; then echo "Current active devices: \(udid)"; fi ;;
            esac
            exit 0
            """
        let tcpdumpScript = """
            #!/bin/sh
            echo "tcpdump $@" >> "\(log.path)"
            \(try tcpdumpBody(dir))
            """
        tools.rvictl = try write("rvictl", rvictlScript)
        tools.tcpdump = try write("tcpdump", tcpdumpScript)
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// fake ifconfig: logs "ifconfig <args>" then runs body
    mutating func addIfconfig(_ body: String) throws {
        tools.ifconfig = try write("ifconfig", "#!/bin/sh\necho \"ifconfig $@\" >> \"\(log.path)\"\n\(body)\n")
    }

    func markListed() { FileManager.default.createFile(atPath: dir.appendingPathComponent("listed").path, contents: Data()) }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    // writes data to a file and returns a script body that cats it in chunks
    /// inserts the pid write after the stream bytes and before any hang loop
    static func pidAfterCat(_ body: String, pidFile: URL) -> String {
        let line = "echo $$ > \"\(pidFile.path)\"\n"
        if let range = body.range(of: "while :; do sleep") {
            return body[..<range.lowerBound] + line + body[range.lowerBound...]
        }
        return body + line
    }

    static func catBody(_ data: [UInt8], chunk: Int = 4096, sleep: String = "0.05", thenHang: Bool = false) -> (URL) throws -> String {
        { dir in
        let file = dir.appendingPathComponent("data.pcapng")
        try Data(data).write(to: file)
        let chunks = (data.count + chunk - 1) / chunk
        var body = """
            i=0
            while [ $i -lt \(chunks) ]; do
              dd if="\(file.path)" bs=\(chunk) skip=$i count=1 2>/dev/null
              i=$((i + 1))
              sleep \(sleep)
            done

            """
        if thenHang { body += "while :; do sleep 0.05; done\n" }
        return body
        }
    }
}

private func sampleStream(packets: Int = 200) -> [UInt8] {
    var bytes = PCAPNGBuilder.sectionHeader() + PCAPNGBuilder.interface("rvi9")
    for i in 0..<packets {
        bytes += PCAPNGBuilder.packet(interface: 0, microseconds: 1_763_000_000_000_000 + UInt64(i) * 1000, process: nil)
    }
    return bytes + PCAPNGBuilder.pcapTrailer
}

private func collect(_ source: ProcessPacketSource) async throws -> (packets: Int, end: PCAPNGEnd?) {
    var packets = 0
    var end: PCAPNGEnd?
    for try await event in source.events() {
        switch event {
        case .packet: packets += 1
        case .end(let e): end = e
        default: break
        }
    }
    return (packets, end)
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func hit() { lock.lock(); value += 1; lock.unlock() }
}

private final class TickClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Date { lock.lock(); defer { lock.unlock() }; value += 1; return Date(timeIntervalSince1970: Double(value)) }
}

private func linkWatchdog(
    source: ProcessPacketSource, interface: String, tools: CaptureTools, controller: CaptureController,
    pipeline: CapturePipeline
) -> Task<StallWatchdog.Verdict?, Never> {
    Task {
        await runStallWatchdog(
            StallWatchdog(stallAfter: 0.3, checkEvery: 0.1),
            lastByteAt: { source.lastByteAt },
            processRunning: { source.terminationStatus == nil },
            linkUp: { await LinkProbe.isUp(interface: interface, tools: tools) },
            onLinkDown: {
                await controller.stop()
                await pipeline.stop(reason: .interrupted)
            })
    }
}

private func pidAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

// these tests spawn processes, send signals and install process-wide handlers: run them one at a time
@Suite(.serialized) struct CaptureSuite {

@Test func startYieldsInterfaceAndPackets() async throws {
    var fake = try Fake(tcpdumpBody: Fake.catBody(sampleStream()))
    defer { fake.cleanup() }
    fake.tools.extraTcpdumpArguments = ["-c", "5"]

    let controller = CaptureController(tools: fake.tools)
    let (interface, source) = try await controller.start(udid: udid)
    #expect(interface == "rvi9")

    let result = try await collect(source)
    #expect(result.packets == 200)
    #expect(result.end == .pcapTrailer)
    #expect(source.terminationStatus == 0)

    await controller.stop()
    let log = fake.logText
    #expect(log.contains("rvictl -s \(udid)"))
    #expect(log.contains("tcpdump -i rvi9 -n -p -s 0 -U -P -w - -c 5"))
    #expect(log.contains("rvictl -x \(udid)"))
}

@Test func stopWhileRunningKillsTcpdumpAndRemovesRvi() async throws {
    let cat = Fake.catBody(sampleStream(packets: 20), thenHang: true)
    // the pid file is written after the stream bytes, so stop() cannot race the data
    let fake = try Fake(tcpdumpBody: { dir in try Fake.pidAfterCat(cat(dir), pidFile: dir.appendingPathComponent("pid")) })
    defer { fake.cleanup() }
    let pidFile = fake.dir.appendingPathComponent("pid")

    let controller = CaptureController(tools: fake.tools)
    let (_, source) = try await controller.start(udid: udid)
    let reader = Task { try await collect(source) }

    // wait for the script to start
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
        try await Task.sleep(for: .milliseconds(20))
    }
    let pid = Int32(((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(pid != nil)
    #expect(pid.map(pidAlive) == true)

    let began = ContinuousClock.now
    await controller.stop()
    #expect(ContinuousClock.now - began < .seconds(3))
    if let pid { #expect(!pidAlive(pid)) }
    #expect(fake.logText.contains("rvictl -x \(udid)"))

    // the stream ends once the process is gone
    let result = try await reader.value
    #expect(result.packets == 20)
    #expect(source.terminationStatus != nil)

    // stop twice is harmless
    await controller.stop()
}

@Test func rviFailureThrowsAndStartsNoTcpdump() async throws {
    let fake = try Fake(rvictl: "echo \"Starting device $2 [FAILED]\"", tcpdumpBody: { _ in "exit 0" })
    defer { fake.cleanup() }

    let controller = CaptureController(tools: fake.tools)
    do {
        _ = try await controller.start(udid: udid)
        Issue.record("expected rviStartFailed")
    } catch let error as CaptureError {
        guard case .rviStartFailed(let output) = error else {
            Issue.record("wrong error \(error)")
            return
        }
        #expect(output.contains("[FAILED]"))
        #expect(!output.contains(udid))
        #expect(!"\(error)".contains(udid))
    }
    #expect(!fake.logText.contains("tcpdump"))
    // it cleans up after itself, so a retry is allowed
    #expect(fake.logText.contains("rvictl -x \(udid)"))
}

@Test func tcpdumpExitingNonZeroThrowsAndSetsStatus() async throws {
    let fake = try Fake(tcpdumpBody: { _ in "echo 'tcpdump: rvi9: permission denied' >&2\nexit 3" })
    defer { fake.cleanup() }

    let controller = CaptureController(tools: fake.tools)
    let (_, source) = try await controller.start(udid: udid)
    do {
        _ = try await collect(source)
        Issue.record("expected the stream to throw")
    } catch let error as CaptureError {
        guard case .tcpdumpExited(3) = error else {
            Issue.record("wrong error \(error)")
            return
        }
    }
    #expect(source.terminationStatus == 3)

    // stderr is captured
    for _ in 0..<50 where await controller.stderrLines.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await controller.stderrLines.contains { $0.contains("permission denied") })
    await controller.stop()
}

@Test func startTwiceThrowsAlreadyRunning() async throws {
    let fake = try Fake(tcpdumpBody: Fake.catBody(sampleStream(packets: 5), thenHang: true))
    defer { fake.cleanup() }

    let controller = CaptureController(tools: fake.tools)
    _ = try await controller.start(udid: udid)
    do {
        _ = try await controller.start(udid: udid)
        Issue.record("expected alreadyRunning")
    } catch let error as CaptureError {
        guard case .alreadyRunning = error else {
            Issue.record("wrong error \(error)")
            return
        }
    }
    await controller.stop()
}

@Test func cleanupStaleRemovesOnlyListedDevice() async throws {
    let fake = try Fake(tcpdumpBody: { _ in "exit 0" })
    defer { fake.cleanup() }

    await CaptureController.cleanupStaleInterfaces(udid: udid, tools: fake.tools)
    #expect(fake.logText.contains("rvictl -l"))
    #expect(!fake.logText.contains("rvictl -x"))

    fake.markListed()
    await CaptureController.cleanupStaleInterfaces(udid: udid, tools: fake.tools)
    #expect(fake.logText.contains("rvictl -x \(udid)"))
}

@Test func diagnosticTeeReceivesRawBytes() async throws {
    let data = sampleStream(packets: 30)
    let fake = try Fake(tcpdumpBody: Fake.catBody(data))
    defer { fake.cleanup() }
    let teeURL = fake.dir.appendingPathComponent("tee.pcapng")
    FileManager.default.createFile(atPath: teeURL.path, contents: nil)

    let controller = CaptureController(tools: fake.tools)
    let (_, source) = try await controller.start(udid: udid, tee: try FileHandle(forWritingTo: teeURL))
    let result = try await collect(source)
    #expect(result.packets == 30)
    await controller.stop()
    #expect(try Data(contentsOf: teeURL) == Data(data))
}

@Test func fixtureRunMatchesFlowsCommand() async throws {
    guard let fixture = Fixtures.url("watch-clean-test.pcap") else { return }
    let fake = try Fake(tcpdumpBody: { _ in "cat \"\(fixture.path)\"\n" })
    defer { fake.cleanup() }

    let dbURL = fake.dir.appendingPathComponent("test.db")
    let store = try Store(path: dbURL)
    let session = CaptureSession(
        id: UUID(), startedAt: Date(), source: "rvi", deviceHash: try store.deviceHash(udid: udid), watchVersion: "test")
    let live = CapturePipeline(store: store, session: session, retainFlows: true)

    let controller = CaptureController(tools: fake.tools)
    let (_, source) = try await controller.start(udid: udid)
    _ = try await live.run(source)
    await live.stop(reason: .captureStopped)
    await controller.stop()

    let replay = CapturePipeline(store: nil, session: session, retainFlows: true)
    _ = try await replay.run(FilePacketSource(url: fixture))
    await replay.stop(reason: .captureStopped)

    let liveStats = await live.stats
    let replayStats = await replay.stats
    #expect(liveStats.packets == replayStats.packets)
    #expect(liveStats.flowsOpened == replayStats.flowsOpened)
    #expect(await live.flowsSnapshot().count == replayStats.flowsOpened)
    #expect(await live.flowsSnapshot().count == (await replay.flowsSnapshot().count))
}

@Test func childKeepsDefaultSigintAfterHandlersInstalled() async throws {
    installCaptureSignalHandlers()
    let cat = Fake.catBody(sampleStream(packets: 5), thenHang: true)
    let fake = try Fake(tcpdumpBody: { dir in
        "trap 'echo \"got INT\" >> \"\(dir.path)/log.txt\"; exit 0' INT\n" + (try Fake.pidAfterCat(cat(dir), pidFile: dir.appendingPathComponent("pid")))
    })
    defer { fake.cleanup() }
    let pidFile = fake.dir.appendingPathComponent("pid")

    let controller = CaptureController(tools: fake.tools)
    let (_, source) = try await controller.start(udid: udid)
    let reader = Task { try await collect(source) }
    // the fake script can take a while to start when the suite runs in parallel: wait for a complete pid line
    var pidText = ""
    for _ in 0..<500 where Int32(pidText) == nil {
        try await Task.sleep(for: .milliseconds(20))
        pidText = ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let pid = try #require(Int32(pidText))

    // only the child gets the signal
    kill(pid, SIGINT)
    let result = try await reader.value
    #expect(result.packets == 5)
    #expect(source.terminationStatus == 0)
    #expect(fake.logText.contains("got INT"))
    #expect(source.end != nil)
    await controller.stop()
}

@Test func fakeIfconfigDrivesVerdict() async throws {
    var up = try Fake(tcpdumpBody: { _ in "exit 0" })
    defer { up.cleanup() }
    try up.addIfconfig("echo 'rvi9: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 0'")
    var down = try Fake(tcpdumpBody: { _ in "exit 0" })
    defer { down.cleanup() }
    try down.addIfconfig("echo 'ifconfig: interface rvi9 does not exist' >&2; exit 1")
    var noUp = try Fake(tcpdumpBody: { _ in "exit 0" })
    defer { noUp.cleanup() }
    try noUp.addIfconfig("echo 'rvi9: flags=8822<BROADCAST,SMART,SIMULATE,MULTICAST> mtu 0'")

    let old = Date(timeIntervalSince1970: 1000)
    let now = old.addingTimeInterval(20)
    for (fake, expected) in [(up, StallWatchdog.Verdict.quietButAlive), (down, .linkDown), (noUp, .linkDown)] {
        var watchdog = StallWatchdog()
        let tools = fake.tools
        let verdict = await watchdog.evaluate(now: now, lastByteAt: old, processRunning: true) {
            await LinkProbe.isUp(interface: "rvi9", tools: tools)
        }
        #expect(verdict == expected)
    }
    // the probe passes only the interface name, never a device id
    #expect(up.logText.contains("ifconfig rvi9"))
    #expect(!up.logText.contains(udid))
    // a name that is not plain is refused without running anything
    #expect(await LinkProbe.isUp(interface: "rvi9; rm", tools: up.tools) == false)
}

@Test func runnerStopsSessionOnLinkDown() async throws {
    // a stream of 3 flows, then silence; ifconfig says the interface is gone
    var bytes = PCAPNGBuilder.sectionHeader() + PCAPNGBuilder.interface("rvi9")
    for i in 0..<3 {
        let frame = PacketBuilder.ethernetIPv4TCP(
            src: PacketBuilder.v4(10, 0, 0, 2), dst: PacketBuilder.v4(93, 184, 216, 34),
            srcPort: 50_000 + i, dstPort: 80, flags: 0x10, payload: [1, 2, 3])
        bytes += PCAPNGBuilder.packet(
            interface: 0, microseconds: 1_763_000_000_000_000 + UInt64(i) * 1000, process: nil, payload: frame)
    }
    var fake = try Fake(tcpdumpBody: Fake.catBody(bytes, chunk: 1 << 20, thenHang: true))
    defer { fake.cleanup() }
    try fake.addIfconfig("exit 1")

    let dbURL = fake.dir.appendingPathComponent("test.db")
    let hash = try Store(path: dbURL).deviceHash(udid: udid)
    let session = CaptureSession(id: UUID(), startedAt: Date(), source: "rvi", deviceHash: hash, watchVersion: "test")
    let openedStore = try Store(path: dbURL)
    let pipeline = CapturePipeline(store: openedStore, session: session, retainFlows: true)
    let controller = CaptureController(tools: fake.tools)
    let (interface, source) = try await controller.start(udid: udid)
    let tools = fake.tools

    // real clock with small thresholds, so the test waits under a second
    let watchdog = linkWatchdog(source: source, interface: interface, tools: tools, controller: controller, pipeline: pipeline)
    let began = ContinuousClock.now
    _ = try await pipeline.run(source)
    let verdict = await watchdog.value
    let took = ContinuousClock.now - began
    #expect(verdict == .linkDown)
    #expect(took < .seconds(10))

    // data is saved and the session ended as interrupted
    let store = try Store(path: dbURL)
    let finalStats = await pipeline.stats
    #expect(finalStats.packets == 3)
    let savedFlows = try store.flows(session: session.id)
    #expect(savedFlows.count == 3)
    let saved = try store.sessions()
    let endReason = saved.first(where: { $0.id == session.id })?.endReason
    #expect(endReason == "interrupted")
    #expect(fake.logText.contains("rvictl -x \(udid)"))
    #expect(!fake.logText.contains("ifconfig \(udid)"))
}

@Test func quietButAliveDoesNotEndTheSession() async throws {
    let cat = Fake.catBody(sampleStream(packets: 3), thenHang: true)
    var fake = try Fake(tcpdumpBody: cat)
    defer { fake.cleanup() }
    try fake.addIfconfig("echo 'rvi9: flags=8863<UP,RUNNING> mtu 0'")
    let controller = CaptureController(tools: fake.tools)
    let (interface, source) = try await controller.start(udid: udid)
    let tools = fake.tools
    let called = CallCounter()
    let watchdog = Task {
        await runStallWatchdog(
            StallWatchdog(stallAfter: 0.2, checkEvery: 0.1),
            lastByteAt: { source.lastByteAt },
            processRunning: { source.terminationStatus == nil },
            linkUp: { called.hit(); return await LinkProbe.isUp(interface: interface, tools: tools) },
            onLinkDown: { Issue.record("link judged down") })
    }
    let reader = Task { try await collect(source) }
    try await Task.sleep(for: .milliseconds(800))
    #expect(called.count >= 1)
    watchdog.cancel()
    #expect(await watchdog.value == nil)
    await controller.stop()
    _ = try await reader.value
}

@Test func lastByteAtUpdates() async throws {
    // a clock that ticks once per call: each chunk read moves lastByteAt strictly forward
    let clock = TickClock()
    let fake = try Fake(tcpdumpBody: Fake.catBody(sampleStream(packets: 20), chunk: 256, sleep: "0.02"))
    defer { fake.cleanup() }
    let process = Process()
    process.executableURL = fake.tools.tcpdump
    let pipe = Pipe()
    process.standardOutput = pipe
    let source = ProcessPacketSource(process: process, clock: { clock.next() })
    let start = source.lastByteAt
    try process.run()

    var seen: [Date] = [start]
    let reader = Task { try await collect(source) }
    while process.isRunning {
        seen.append(source.lastByteAt)
        try await Task.sleep(for: .milliseconds(10))
    }
    _ = try await reader.value
    seen.append(source.lastByteAt)
    #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(seen.last! > start)
}


}

// MARK: - kernel drop summary (6.4)

@Test func parsesDropLine() {
    #expect(CaptureController.droppedByKernel(in: ["26916 packets captured", "26916 packets received by filter", "12 packets dropped by kernel"]) == 12)
    #expect(CaptureController.droppedByKernel(in: ["1 packet dropped by kernel"]) == 1)
    #expect(CaptureController.droppedByKernel(in: ["0 packets dropped by kernel"]) == 0)
    #expect(CaptureController.droppedByKernel(in: ["tcpdump: listening on rvi0", "26916 packets captured"]) == nil)
    #expect(CaptureController.droppedByKernel(in: []) == nil)
}

@Test func ignoresOtherLines() {
    #expect(CaptureController.droppedByKernel(in: ["0 packets received by filter"]) == nil)
    #expect(CaptureController.droppedByKernel(in: ["12 packets dropped by interface"]) == nil)
    #expect(CaptureController.droppedByKernel(in: ["note: 12 packets dropped by kernel"]) == nil)
    #expect(CaptureController.droppedByKernel(in: ["12:00:01 tcpdump status 0"]) == nil)
}

@Test func redactedLinesStillParse() {
    let line = redact("12 packets dropped by kernel \(udid)", udid: udid)
    #expect(CaptureController.droppedByKernel(in: [line]) == 12)
}

@Test func kernelDroppedStoredAtEnd() async throws {
    let fake = try Fake(tcpdumpBody: { dir in
        try Data(sampleStream(packets: 5)).write(to: dir.appendingPathComponent("s.pcapng"))
        return "cat \"\(dir.path)/s.pcapng\"\necho \"30 packets captured\" >&2\necho \"12 packets dropped by kernel\" >&2\n"
    })
    defer { fake.cleanup() }
    let dbURL = fake.dir.appendingPathComponent("test.db")
    let reader = try Store(path: dbURL)
    let session = CaptureSession(
        id: UUID(), startedAt: Date(), source: "rvi", deviceHash: try reader.deviceHash(udid: udid), watchVersion: "test")
    let pipeline = CapturePipeline(store: try Store(path: dbURL), session: session)
    let controller = CaptureController(tools: fake.tools)
    let (_, source) = try await controller.start(udid: udid)
    _ = try await pipeline.run(source)
    await controller.stop()
    await pipeline.setKernelDropped(await controller.kernelDropped())
    await pipeline.stop(reason: .captureStopped)
    #expect(try reader.sessionStats(id: session.id).kernelDropped == 12)
}

@Test func missingSummaryLeavesKernelDroppedUnknown() async throws {
    let fake = try Fake(tcpdumpBody: { dir in
        try Data(sampleStream(packets: 5)).write(to: dir.appendingPathComponent("s.pcapng"))
        return "cat \"\(dir.path)/s.pcapng\"\n"
    })
    defer { fake.cleanup() }
    let controller = CaptureController(tools: fake.tools)
    let (_, source) = try await controller.start(udid: udid)
    _ = try await collect(source)
    await controller.stop()
    #expect(await controller.kernelDropped() == nil)
}

// MARK: - link loss seen by tcpdump (6.5, PH-5)

private let ph5Stderr = [
    "tcpdump: pcap_loop: The interface disappeared", "5197 packets captured",
    "5209 packets received by filter", "0 packets dropped by kernel",
]

@Test func interfaceDisappearedMatchesVariants() {
    #expect(CaptureController.interfaceDisappeared(in: ph5Stderr))
    #expect(CaptureController.interfaceDisappeared(in: ["the interface disappeared"]))
    #expect(CaptureController.interfaceDisappeared(in: ["TCPDUMP: PCAP_LOOP: THE INTERFACE DISAPPEARED"]))
    #expect(!CaptureController.interfaceDisappeared(in: ["tcpdump: rvi0: No such device exists", "0 packets dropped by kernel"]))
    #expect(!CaptureController.interfaceDisappeared(in: []))
}

// the PH-5 order: tcpdump prints its stats on stderr, exits 1, the stream fails inside run (which stops
// the pipeline); the stored session must still carry kernel_dropped 0 and end as interrupted
@Test func tcpdumpExitingOnItselfStoresKernelDropped() async throws {
    let fake = try Fake(tcpdumpBody: { dir in
        try Data(sampleStream(packets: 5)).write(to: dir.appendingPathComponent("s.pcapng"))
        let lines = ph5Stderr.map { "echo \"\($0)\" >&2" }.joined(separator: "\n")
        return "cat \"\(dir.path)/s.pcapng\"\n\(lines)\nexit 1\n"
    })
    defer { fake.cleanup() }
    let dbURL = fake.dir.appendingPathComponent("test.db")
    let reader = try Store(path: dbURL)
    let session = CaptureSession(
        id: UUID(), startedAt: Date(), source: "rvi", deviceHash: try reader.deviceHash(udid: udid), watchVersion: "test")
    let pipeline = CapturePipeline(store: try Store(path: dbURL), session: session)
    let controller = CaptureController(tools: fake.tools)
    await pipeline.setKernelDroppedProvider { await controller.kernelDropped() }
    let (_, source) = try await controller.start(udid: udid)
    var failure: Error?
    do { _ = try await pipeline.run(source) } catch { failure = error }
    guard case CaptureError.tcpdumpExited(1)? = failure else {
        Issue.record("expected tcpdumpExited(1), got \(String(describing: failure))")
        return
    }
    #expect(await controller.linkLostByTcpdump())
    await controller.stop()
    let stats = try reader.sessionStats(id: session.id)
    #expect(stats.kernelDropped == 0)
    #expect(try reader.sessions().first(where: { $0.id == session.id })?.endReason == "interrupted")
}

@Test func genuineTcpdumpFailureIsNotLinkLoss() async throws {
    let fake = try Fake(tcpdumpBody: { _ in "echo \"tcpdump: rvi9: permission denied\" >&2\nexit 1\n" })
    defer { fake.cleanup() }
    let controller = CaptureController(tools: fake.tools)
    let (_, source) = try await controller.start(udid: udid)
    do { _ = try await collect(source); Issue.record("expected a failure") } catch {}
    #expect(await controller.linkLostByTcpdump() == false)
    #expect(await controller.kernelDropped() == nil)
    await controller.stop()
}
