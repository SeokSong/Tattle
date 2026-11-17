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

}