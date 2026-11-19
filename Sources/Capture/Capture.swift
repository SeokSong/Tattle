import Foundation
import PCAPNG

// starts rvi, runs tcpdump on it, hands its stdout to the pcapng reader (see md/CAPTURE.md).
// the udid is never logged; error text has it redacted.

// MARK: - Tools and errors

public struct CaptureTools: Sendable {
    public var rvictl = URL(fileURLWithPath: "/Library/Apple/usr/bin/rvictl")
    public var tcpdump = URL(fileURLWithPath: "/usr/sbin/tcpdump")
    /// the link check runs `ifconfig <interface>`; it needs no root
    public var ifconfig = URL(fileURLWithPath: "/sbin/ifconfig")
    public var extraTcpdumpArguments: [String] = []

    public init() {}
}

public enum CaptureError: Error, Sendable, CustomStringConvertible {
    case alreadyRunning
    /// rvictl did not report success; the text has the udid redacted
    case rviStartFailed(String)
    case tcpdumpLaunchFailed(String)
    /// tcpdump exited with a non-zero status
    case tcpdumpExited(Int32)
    case stdoutNotAPipe
    /// the user cancelled the administrator password dialog
    case accessDenied
    /// no capture data arrived within the time allowed for the password dialog
    case accessTimedOut
    /// the run directory or its files could not be set up
    case runDirectoryFailed(String)

    public var description: String {
        switch self {
        case .alreadyRunning: return "capture already running"
        case .rviStartFailed(let output): return "rvictl failed: \(output)"
        case .tcpdumpLaunchFailed(let reason): return "tcpdump could not start: \(reason)"
        case .tcpdumpExited(let status): return "tcpdump exited with status \(status)"
        case .stdoutNotAPipe: return "process standard output is not a pipe"
        case .accessDenied: return "administrator access was not granted"
        case .accessTimedOut: return "timed out waiting for administrator access"
        case .runDirectoryFailed(let reason): return "could not prepare the capture: \(reason)"
        }
    }
}

extension CaptureError: LocalizedError {
    public var errorDescription: String? { description }
}

func redact(_ text: String, udid: String) -> String {
    guard !udid.isEmpty else { return text }
    return text.replacingOccurrences(of: udid, with: "<udid>")
}

// MARK: - Signals

// plain C handlers, not SIG_IGN: an ignored disposition would be inherited by tcpdump across
// posix_spawn, while a caught one resets to default on exec. the terminal sends Ctrl-C to the whole
// foreground group, so tcpdump sees SIGINT itself; SIGTERM is forwarded to it.
nonisolated(unsafe) private var receivedSignal: sig_atomic_t = 0
nonisolated(unsafe) private var forwardPid: sig_atomic_t = 0

private func captureSignalHandler(_ sig: Int32) {
    receivedSignal = sig
    if sig == SIGTERM, forwardPid > 0 { kill(forwardPid, SIGTERM) }
}

/// installs the SIGINT and SIGTERM handlers shared by the CLI and tests
public func installCaptureSignalHandlers() {
    for sig in [SIGINT, SIGTERM] {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = captureSignalHandler
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(sig, &action, nil)
    }
}

/// the signal number received since installCaptureSignalHandlers, or 0
public var capturedSignal: Int32 { receivedSignal }

// MARK: - Process packet source

/// reads a running process's stdout through PCAPNGStreamParser in 64 KB chunks.
/// events() may be called once. the stream throws CaptureError.tcpdumpExited when the process
/// exits non-zero; a process killed by a signal ends the stream without error.
public final class ProcessPacketSource: PacketSource, @unchecked Sendable {
    public static let chunkSize = 64 * 1024

    private let process: Process
    private let output: FileHandle?
    private let tee: FileHandle?
    private let lock = NSLock()
    private var status: Int32?
    private var streamEnd: PCAPNGEnd?
    private var lastRead: Date
    private let clock: @Sendable () -> Date

    /// tee receives every raw byte read, for the diagnostic capture; it is closed at the end.
    /// clock is injectable for tests; lastByteAt starts at the time of init
    public init(process: Process, tee: FileHandle? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.process = process
        self.clock = clock
        self.lastRead = clock()
        self.output = (process.standardOutput as? Pipe)?.fileHandleForReading
        self.tee = tee
    }

    /// set once the process has exited
    public var terminationStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    /// how the stream ended, set when the parser finishes
    public var end: PCAPNGEnd? {
        lock.lock()
        defer { lock.unlock() }
        return streamEnd
    }

    /// when bytes were last read from the process (the time of init until the first read). read by the
    /// stall watchdog; costs one lock and one clock read per 64 KB chunk
    public var lastByteAt: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastRead
    }

    private func noteBytes() {
        let now = clock()
        lock.lock()
        lastRead = now
        lock.unlock()
    }

    private func setEnd(_ value: PCAPNGEnd) {
        lock.lock()
        streamEnd = value
        lock.unlock()
    }

    private func setStatus(_ value: Int32) {
        lock.lock()
        status = value
        lock.unlock()
    }

    public func events() -> AsyncThrowingStream<PCAPNGEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let output = self.output else {
                continuation.finish(throwing: CaptureError.stdoutNotAPipe)
                return
            }
            let cancelled = CancelFlag()
            continuation.onTermination = { _ in cancelled.set() }
            // blocking reads stay off the cooperative pool
            DispatchQueue.global(qos: .userInitiated).async {
                self.pump(output, continuation, cancelled)
            }
        }
    }

    /// bounded replacement for waitUntilExit: 5 s grace, SIGTERM, 2 s, SIGKILL, 2 s
    static func waitForExit(_ process: Process) {
        func wait(_ seconds: Double) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            return !process.isRunning
        }
        if wait(5) { return }
        process.terminate()
        if wait(2) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = wait(2)
    }

    private func pump(
        _ output: FileHandle, _ continuation: AsyncThrowingStream<PCAPNGEvent, Error>.Continuation,
        _ cancelled: CancelFlag
    ) {
        defer { try? tee?.close() }
        let fd = output.fileDescriptor
        var parser = PCAPNGStreamParser()
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)

        do {
            while !cancelled.isSet {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if n == 0 { break }
                noteBytes()
                if let tee { try? tee.write(contentsOf: buffer[0..<n]) }
                for event in try parser.append(buffer[0..<n]) { continuation.yield(event) }
            }
        } catch {
            // parser error: stop reading. the owner kills the process
            continuation.finish(throwing: error)
            return
        }

        // the stream is at EOF, so the process is gone or about to be. never wait on it unbounded:
        // a process that closed its output but lingers is terminated, then killed
        Self.waitForExit(process)
        let code = process.terminationStatus
        setStatus(code)

        if process.terminationReason == .exit && code != 0 {
            continuation.finish(throwing: CaptureError.tcpdumpExited(code))
            return
        }
        do {
            let end = try parser.finish()
            setEnd(end)
            continuation.yield(.end(end))
        } catch {
            // killed by a signal: a truncated last block is expected
            if process.terminationReason == .exit {
                continuation.finish(throwing: error)
                return
            }
            setEnd(.cleanEnd)
            continuation.yield(.end(.cleanEnd))
        }
        continuation.finish()
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

// last lines of tcpdump's stderr
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var partial = ""
    private var ended = false
    static let limit = 20

    /// set when the pipe reached end of file, so the exit summary has been read
    func finish() {
        lock.lock()
        ended = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        partial += String(decoding: data, as: UTF8.self)
        var parts = partial.components(separatedBy: "\n")
        partial = parts.removeLast()
        lines += parts.filter { !$0.isEmpty }
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        var all = lines
        if !partial.isEmpty { all.append(partial) }
        return Array(all.suffix(Self.limit))
    }
}

// MARK: - Controller

public actor CaptureController {
    private let tools: CaptureTools
    private var udid: String?
    private var process: Process?
    private var stderr: StderrTail?
    private var stopTask: Task<Void, Never>?

    public init(tools: CaptureTools = .init()) {
        self.tools = tools
    }

    /// last lines of tcpdump's stderr, udid redacted
    public var stderrLines: [String] {
        let lines = stderr?.snapshot ?? []
        guard let udid else { return lines }
        return lines.map { redact($0, udid: udid) }
    }

    /// tcpdump's "packets dropped by kernel" count, once the process has ended and its stderr is read
    /// (waits up to `timeout` for the end of the pipe). nil when the line is absent: tcpdump was killed,
    /// so the count is unknown, never 0
    public func kernelDropped(timeout: TimeInterval = 1) async -> Int? {
        guard let tail = stderr else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while !tail.isFinished, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return Self.droppedByKernel(in: tail.snapshot)
    }

    /// true when tcpdump's stderr says the interface vanished ("tcpdump: pcap_loop: The interface
    /// disappeared"): a cable pull or a phone that dropped off. seen on a real phone (PH-5): tcpdump then
    /// prints its summary and exits 1. matched case-insensitively, with or without the pcap_loop prefix
    public static func interfaceDisappeared(in lines: [String]) -> Bool {
        lines.contains { $0.range(of: "the interface disappeared", options: .caseInsensitive) != nil }
    }

    /// whether tcpdump reported a vanished interface; waits up to `timeout` for the end of its stderr
    public func linkLostByTcpdump(timeout: TimeInterval = 1) async -> Bool {
        guard let tail = stderr else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while !tail.isFinished, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return Self.interfaceDisappeared(in: tail.snapshot)
    }

    /// the value of the last "N packets dropped by kernel" line (tcpdump prints it on a clean exit), or nil.
    /// the count is a number only, so redaction never changes it
    public static func droppedByKernel(in lines: [String]) -> Int? {
        for line in lines.reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let match = text.range(of: #"^\d+ packets? dropped by kernel"#, options: .regularExpression) else { continue }
            if let count = Int(text[match].prefix { $0.isNumber }) { return count }
        }
        return nil
    }

    /// starts rvi for the udid, then tcpdump on it. returns the interface name (rvi0) and the source.
    /// on failure everything started so far is stopped again. tee gets the raw stream (diagnostic capture)
    public func start(udid: String, tee: FileHandle? = nil) async throws -> (interface: String, source: ProcessPacketSource) {
        guard self.udid == nil, stopTask == nil else { throw CaptureError.alreadyRunning }
        self.udid = udid
        do {
            let result: (status: Int32, output: String)
            do {
                result = try await Self.run(tools.rvictl, ["-s", udid])
            } catch {
                throw CaptureError.rviStartFailed(redact("\(error.localizedDescription)", udid: udid))
            }
            let output = result.output
            guard output.contains("[SUCCEEDED]"), let interface = Self.interfaceName(in: output) else {
                throw CaptureError.rviStartFailed(redact(output.trimmingCharacters(in: .whitespacesAndNewlines), udid: udid))
            }

            let process = Process()
            process.executableURL = tools.tcpdump
            process.arguments = ["-i", interface, "-n", "-p", "-s", "0", "-U", "-P", "-w", "-"] + tools.extraTcpdumpArguments
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            let tail = StderrTail()
            err.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    tail.finish()
                } else {
                    tail.append(data)
                }
            }
            let source = ProcessPacketSource(process: process, tee: tee)
            do {
                try process.run()
            } catch {
                err.fileHandleForReading.readabilityHandler = nil
                throw CaptureError.tcpdumpLaunchFailed(redact("\(error)", udid: udid))
            }
            self.process = process
            forwardPid = process.processIdentifier
            self.stderr = tail
            return (interface, source)
        } catch {
            await stop()
            throw error
        }
    }

    /// SIGINT tcpdump, wait up to 2 s, SIGKILL; then rvictl -x. safe to call at any point, any number of times
    public func stop() async {
        if let task = stopTask {
            await task.value
            return
        }
        let task = Task { await self.performStop() }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStop() async {
        forwardPid = 0
        if let process {
            if process.isRunning {
                process.interrupt()
                let deadline = ContinuousClock.now + .seconds(2)
                while process.isRunning && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    let hard = ContinuousClock.now + .seconds(1)
                    while process.isRunning && ContinuousClock.now < hard {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            self.process = nil
        }
        if let udid {
            _ = try? await Self.run(tools.rvictl, ["-x", udid])
            self.udid = nil
        }
    }

    /// rvictl -x if rvictl -l lists the udid; used on launch
    public static func cleanupStaleInterfaces(udid: String, tools: CaptureTools) async {
        guard let listed = try? await run(tools.rvictl, ["-l"]), listed.output.contains(udid) else { return }
        _ = try? await run(tools.rvictl, ["-x", udid])
    }

    // MARK: helpers

    /// "with interface rvi0" -> "rvi0"
    static func interfaceName(in output: String) -> String? {
        guard let range = output.range(of: "with interface ") else { return nil }
        let name = output[range.upperBound...].prefix { !$0.isWhitespace }
        return name.isEmpty ? nil : String(name)
    }

    /// runs a short-lived tool to completion; stdout and stderr go to a temp file, so a lingering
    /// child can never hold a pipe open
    static func run(_ url: URL, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("watch-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CaptureError.tcpdumpLaunchFailed("cannot create temporary file")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return (status, text)
    }
}
