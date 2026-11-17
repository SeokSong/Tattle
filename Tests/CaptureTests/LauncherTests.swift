import Foundation
import PCAPNG
import Testing
import TestSupport

@testable import Capture

private let udid = "00008110-FAKEUDID0001"

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func permissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}

private func writeScript(_ url: URL, _ body: String) throws {
    try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

// fake rvictl and tcpdump in a temp dir; tcpdump streams a pcapng then waits to be told to stop
private func fakeTools(in root: URL, rvictlOutput: String = "Starting device X [SUCCEEDED] with interface rvi9") throws -> CaptureTools {
    var tools = CaptureTools()
    tools.rvictl = root.appendingPathComponent("rvictl")
    tools.tcpdump = root.appendingPathComponent("tcpdump")
    let calls = root.appendingPathComponent("calls.txt").path
    try writeScript(tools.rvictl, """
        echo "rvictl $@" >> "\(calls)"
        case "$1" in -s) echo "\(rvictlOutput)" ;; esac
        exit 0
        """)
    var stream = PCAPNGBuilder.sectionHeader() + PCAPNGBuilder.interface("rvi9")
    for i in 0..<10 {
        stream += PCAPNGBuilder.packet(interface: 0, microseconds: 1_763_000_000_000_000 + UInt64(i), process: nil)
    }
    stream += PCAPNGBuilder.pcapTrailer
    let data = root.appendingPathComponent("data.pcapng")
    try Data(stream).write(to: data)
    try writeScript(tools.tcpdump, """
        echo "tcpdump $@" >> "\(calls)"
        trap 'exit 0' TERM INT
        cat "\(data.path)"
        while :; do sleep 0.1; done
        """)
    return tools
}

private let shRunner: PrototypeCaptureLauncher.Runner = { path in (URL(fileURLWithPath: "/bin/sh"), [path]) }
/// starts the script with INT and TERM ignored, as the macOS privilege helper does
private let ignoringSignalsRunner: PrototypeCaptureLauncher.Runner = { path in
    (URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' INT TERM; exec /bin/sh \"$0\"", path])
}

// MARK: - script

private let devicectlSample = """
    {"info":{"outcome":"success"},"result":{"devices":[
      {"connectionProperties":{"transportType":"wired","pairingState":"paired","tunnelState":"connected"},
       "hardwareProperties":{"udid":"00008110-FAKEUDID0001"},
       "deviceProperties":{"name":"Test Phone"}},
      {"connectionProperties":{"transportType":"localNetwork","pairingState":"paired","tunnelState":"disconnected"},
       "hardwareProperties":{"udid":"00008110-OTHER"},
       "deviceProperties":{"name":"Wireless Phone"}}
    ]}}
    """

// same serialized suite as CaptureTests.swift
extension CaptureSuite {

@Test func scriptHasTheThreeSteps() {
    let dir = URL(fileURLWithPath: "/tmp/run dir/it's")
    let script = PrototypeCaptureLauncher.renderScript(udid: udid, runDirectory: dir)

    #expect(script.contains("RVICTL='/Library/Apple/usr/bin/rvictl'"))
    #expect(script.contains("TCPDUMP='/usr/sbin/tcpdump'"))
    #expect(script.contains("UDID='\(udid)'"))
    #expect(script.contains("\"$RVICTL\" -s \"$UDID\""))
    #expect(script.contains("[SUCCEEDED]"))
    #expect(script.contains("\"$TCPDUMP\" -i \"$iface\" -n -p -s 0 -U -P -w -"))
    #expect(script.contains("$SIG{INT} = \"DEFAULT\""))
    #expect(script.contains("trap '\"$RVICTL\" -x \"$UDID\""))
    #expect(script.contains("[ -e \"$RUN/stop\" ]"))
    #expect(script.contains("kill -INT $pid"))
    #expect(script.contains("kill -TERM $pid"))
    #expect(script.contains("kill -KILL $pid"))
    #expect(script.contains("exit 1"))
    #expect(script.contains("exit 2"))
    #expect(script.contains("2>>\"$RUN/log\""))
    // the udid is only ever an argument: no echo or note line may mention it
    for line in script.split(separator: "\n") where !line.hasPrefix("trap") && (line.hasPrefix("echo") || line.contains("echo ") || line.hasPrefix("note ") || line.contains("; note ")) {
        #expect(!line.contains(udid), "udid in: \(line)")
        #expect(!line.contains("$UDID"), "udid variable in: \(line)")
    }
    // single quotes in the path are escaped
    #expect(script.contains("RUN='/tmp/run dir/it'\\''s'"))
}

@Test func scriptExitsOneWithoutSucceeded() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeTools(in: root, rvictlOutput: "Could not start device")
    let run = root.appendingPathComponent("run")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    let scriptURL = root.appendingPathComponent("script.sh")
    try PrototypeCaptureLauncher.renderScript(udid: udid, runDirectory: run, tools: tools)
        .write(to: scriptURL, atomically: true, encoding: .utf8)

    let result = try await CaptureController.run(URL(fileURLWithPath: "/bin/sh"), [scriptURL.path])
    #expect(result.status == 1)
    let calls = (try? String(contentsOf: root.appendingPathComponent("calls.txt"), encoding: .utf8)) ?? ""
    #expect(!calls.contains("tcpdump"))
    #expect(calls.contains("rvictl -x \(udid)"))
}

// MARK: - launcher

@Test func startReadsStreamAndStopCleansUp() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeTools(in: root)
    let runRoot = root.appendingPathComponent("run")
    let launcher = PrototypeCaptureLauncher(runRoot: runRoot, tools: tools, runner: shRunner)

    let source = try await launcher.start(udid: udid)
    let dir = try #require(await launcher.runDirectory)
    #expect(permissions(dir) == 0o700)
    #expect(permissions(dir.appendingPathComponent("script.sh")) == 0o600)

    var packets = 0
    var consumed = false
    let stream = source.events()
    for try await event in stream {
        if case .packet = event { packets += 1 }
        if packets == 10 && !consumed {
            consumed = true
            await launcher.stop()
        }
    }
    #expect(packets == 10)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
    let calls = try String(contentsOf: root.appendingPathComponent("calls.txt"), encoding: .utf8)
    #expect(calls.contains("tcpdump -i rvi9 -n -p -s 0 -U -P -w -"))
    #expect(calls.contains("rvictl -x \(udid)"))
}

@Test func cancelledDialogIsAccessDeniedAndCleansUp() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runRoot = root.appendingPathComponent("run")
    let cancel: PrototypeCaptureLauncher.Runner = { _ in
        (URL(fileURLWithPath: "/bin/sh"), ["-c", "echo 'execution error: User canceled. (-128)' >&2; exit 1"])
    }
    let launcher = PrototypeCaptureLauncher(runRoot: runRoot, runner: cancel)

    do {
        _ = try await launcher.start(udid: udid)
        Issue.record("start should have thrown")
    } catch let error as CaptureError {
        guard case .accessDenied = error else { Issue.record("wrong error \(error)"); return }
    }
    #expect(await launcher.runDirectory == nil)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: runRoot.path))?.isEmpty ?? true)
    await launcher.stop()
}

@Test func rviFailureSurfacesAndCleansUp() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeTools(in: root, rvictlOutput: "Could not start device")
    let runRoot = root.appendingPathComponent("run")
    let launcher = PrototypeCaptureLauncher(runRoot: runRoot, tools: tools, runner: shRunner)

    do {
        _ = try await launcher.start(udid: udid)
        Issue.record("start should have thrown")
    } catch let error as CaptureError {
        guard case .rviStartFailed(let text) = error else { Issue.record("wrong error \(error)"); return }
        #expect(!text.contains(udid))
    }
    #expect((try? FileManager.default.contentsOfDirectory(atPath: runRoot.path))?.isEmpty ?? true)
}

@Test func dialogTimeoutStopsTheLauncher() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runRoot = root.appendingPathComponent("run")
    let hang: PrototypeCaptureLauncher.Runner = { _ in (URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 30"]) }
    let launcher = PrototypeCaptureLauncher(runRoot: runRoot, accessTimeout: 0.5, runner: hang)

    do {
        _ = try await launcher.start(udid: udid)
        Issue.record("start should have thrown")
    } catch let error as CaptureError {
        guard case .accessTimedOut = error else { Issue.record("wrong error \(error)"); return }
    }
    #expect((try? FileManager.default.contentsOfDirectory(atPath: runRoot.path))?.isEmpty ?? true)
}

// MARK: - device lookup


@Test func deviceLookupDecodesWiredDevice() throws {
    let devices = try DeviceLookup.wiredDevices(from: Data(devicectlSample.utf8))
    #expect(devices.count == 1)
    #expect(devices[0].name == "Test Phone")
    #expect(devices[0].udid == udid)
    #expect(devices[0].pairing == "paired")
    #expect(devices[0].tunnel == "connected")
    #expect(!"\(devices[0])".contains(udid))
}

@Test func deviceLookupAbsentCases() throws {
    #expect(try DeviceLookup.wiredDevices(from: Data(#"{"result":{"devices":[]}}"#.utf8)).isEmpty)

    let wirelessOnly = #"{"result":{"devices":[{"connectionProperties":{"transportType":"localNetwork"}}]}}"#
    #expect(throws: DeviceLookupError.self) { try DeviceLookup.wiredDevices(from: Data(wirelessOnly.utf8)) }
    #expect(throws: DeviceLookupError.self) { try DeviceLookup.wiredDevices(from: Data(#"{"info":{}}"#.utf8)) }
    #expect(throws: DeviceLookupError.self) { try DeviceLookup.wiredDevices(from: Data("nope".utf8)) }
}

// MARK: - stubborn tcpdump

@Test func stopKillsATcpdumpThatIgnoresSignalsAndKeepsTheLog() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeTools(in: root)
    // overwrite the fake: ignores INT and TERM, writes the stream, then sleeps
    let data = root.appendingPathComponent("data.pcapng").path
    try writeScript(tools.tcpdump, """
        trap '' INT TERM
        cat "\(data)"
        while :; do sleep 0.1; done
        """)
    let runRoot = root.appendingPathComponent("run")
    let launcher = PrototypeCaptureLauncher(runRoot: runRoot, tools: tools, runner: shRunner)

    let source = try await launcher.start(udid: udid)
    let seen = Counter()
    let reader = Task { () -> Int in
        for try await event in source.events() { if case .packet = event { seen.increment() } }
        return seen.value
    }
    // the fake has installed its signal traps once its data has been read
    let ready = Date().addingTimeInterval(30)
    while seen.value < 10, Date() < ready { try await Task.sleep(nanoseconds: 50_000_000) }

    let began = Date()
    await launcher.stop()
    #expect(Date().timeIntervalSince(began) < 13)
    #expect(try await reader.value == 10)
    #expect(source.isFinished)

    let log = try #require(await launcher.lastLogURL)
    #expect(log.deletingLastPathComponent() == root.appendingPathComponent("logs"))
    #expect(permissions(log) == 0o600)
    #expect(permissions(log.deletingLastPathComponent()) == 0o700)
    let text = try String(contentsOf: log, encoding: .utf8)
    #expect(text.contains("INT sent"))
    #expect(text.contains("TERM sent"))
    #expect(text.contains("KILL sent"))
    #expect(text.contains("rvi down"))
    #expect(!text.contains(udid))
    #expect((try? FileManager.default.contentsOfDirectory(atPath: runRoot.path))?.isEmpty ?? true)
}

@Test func onlyTheNewestTenLogsAreKept() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeTools(in: root)
    let runRoot = root.appendingPathComponent("run")
    let logs = root.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    for i in 0..<10 {
        try Data().write(to: logs.appendingPathComponent(String(format: "capture-2000010%d-000000000.log", i)))
    }
    let launcher = PrototypeCaptureLauncher(runRoot: runRoot, tools: tools, runner: shRunner)
    _ = try await launcher.start(udid: udid)
    await launcher.stop()
    let names = try FileManager.default.contentsOfDirectory(atPath: logs.path)
    #expect(names.count == 10)
    #expect(!names.contains("capture-20000100-000000000.log"))
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}


@Test func cooperativeTcpdumpDiesFromIntEvenWhenSignalsWereInherited() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeTools(in: root)
    // fake tcpdump without traps that ends as a plain binary (bash itself defers INT while it waits
    // on a child), so like real tcpdump it should die from INT, never reach TERM or KILL
    let data = root.appendingPathComponent("data.pcapng").path
    try writeScript(tools.tcpdump, """
        cat "\(data)"
        exec /bin/sleep 600
        """)
    let runRoot = root.appendingPathComponent("run")
    let launcher = PrototypeCaptureLauncher(runRoot: runRoot, tools: tools, runner: ignoringSignalsRunner)

    let source = try await launcher.start(udid: udid)
    let reader = Task { () -> Int in
        var packets = 0
        for try await event in source.events() { if case .packet = event { packets += 1 } }
        return packets
    }
    try await Task.sleep(nanoseconds: 500_000_000)
    await launcher.stop()
    #expect(try await reader.value == 10)

    let log = try #require(await launcher.lastLogURL)
    let text = try String(contentsOf: log, encoding: .utf8)
    #expect(text.contains("INT sent"))
    #expect(!text.contains("TERM sent"))
    #expect(!text.contains("KILL sent"))
    #expect(text.contains("tcpdump status 130"))
    #expect(text.contains("rvi down"))
}
}
