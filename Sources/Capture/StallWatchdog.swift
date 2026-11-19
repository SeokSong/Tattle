import Foundation

// decides whether a capture that stopped producing bytes has lost its link (see md/CAPTURE.md).
// it runs off the packet path: a timer asks for the time of the last bytes read, nothing is added per packet.
// the clock, the sleep and the link check are all injected, so tests never wait for 15 s.

public struct StallWatchdog: Sendable {
    public enum Verdict: Equatable, Sendable {
        /// bytes arrived recently, or the check was not due yet before the first stall
        case ok
        /// no bytes for longer than `stallAfter` but the link check passed: nothing ends
        case quietButAlive
        /// no bytes and the interface is gone or not up
        case linkDown
        /// the capture process is no longer running; its own exit handling decides the end
        case processExited
    }

    /// the message shown when the link is judged lost
    public static let linkLostMessage = "The iPhone link was lost (cable or phone disconnected)"

    /// no bytes for longer than this many seconds (wall clock) starts a link check. real captures never
    /// went silent for more than 3.07 s, also while the phone was locked
    public var stallAfter: TimeInterval
    /// minimum seconds between link checks, and the runner's polling period
    public var checkEvery: TimeInterval

    private var lastCheck: Date?

    public init(stallAfter: TimeInterval = 15, checkEvery: TimeInterval = 5) {
        self.stallAfter = stallAfter
        self.checkEvery = checkEvery
    }

    /// pure apart from its own rate limit: the link check runs only when the process is running and the
    /// last bytes are older than `stallAfter` (strictly), and not more often than every `checkEvery`
    public mutating func evaluate(
        now: Date, lastByteAt: Date, processRunning: Bool, linkUp: () async -> Bool
    ) async -> Verdict {
        guard processRunning else { return .processExited }
        guard now.timeIntervalSince(lastByteAt) > stallAfter else {
            lastCheck = nil
            return .ok
        }
        if let lastCheck, now.timeIntervalSince(lastCheck) < checkEvery {
            // the last check passed (a failed one ends the session), so the link is still believed alive
            return .quietButAlive
        }
        lastCheck = now
        return await linkUp() ? .quietButAlive : .linkDown
    }
}

@Sendable public func watchdogWallClock() -> Date { Date() }

@Sendable public func watchdogSleep(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
}

/// polls the watchdog until the task is cancelled, the process exits or the link is judged down. on
/// `.linkDown` it calls `onLinkDown` once (the caller stops the capture, then the pipeline as interrupted).
/// returns the verdict that ended the loop, nil when cancelled
@discardableResult
public func runStallWatchdog(
    _ watchdog: StallWatchdog,
    now: @escaping @Sendable () -> Date = watchdogWallClock,
    sleep: @escaping @Sendable (TimeInterval) async -> Void = watchdogSleep,
    lastByteAt: @escaping @Sendable () -> Date,
    processRunning: @escaping @Sendable () -> Bool,
    linkUp: @escaping @Sendable () async -> Bool,
    onLinkDown: @escaping @Sendable () async -> Void
) async -> StallWatchdog.Verdict? {
    var watchdog = watchdog
    while !Task.isCancelled {
        await sleep(watchdog.checkEvery)
        if Task.isCancelled { return nil }
        let verdict = await watchdog.evaluate(
            now: now(), lastByteAt: lastByteAt(), processRunning: processRunning(), linkUp: linkUp)
        switch verdict {
        case .linkDown:
            await onLinkDown()
            return verdict
        case .processExited:
            return verdict
        case .ok, .quietButAlive:
            continue
        }
    }
    return nil
}

/// the link check: `ifconfig <interface>` must exit 0 and list UP among the flags of its first line.
/// needs no root and prints nothing; the output holds no device id
public enum LinkProbe {
    public static func isUp(interface: String, tools: CaptureTools = .init()) async -> Bool {
        guard isPlainName(interface) else { return false }
        guard let result = try? await CaptureController.run(tools.ifconfig, [interface]), result.status == 0 else {
            return false
        }
        return hasUpFlag(result.output)
    }

    /// without a known interface name: any rvi interface listed by `ifconfig -l` counts as present
    public static func anyRVIPresent(tools: CaptureTools = .init()) async -> Bool {
        guard let result = try? await CaptureController.run(tools.ifconfig, ["-l"]), result.status == 0 else {
            return false
        }
        return result.output.split(whereSeparator: \.isWhitespace).contains { $0.hasPrefix("rvi") }
    }

    /// "rvi0: flags=8863<UP,BROADCAST,...> mtu 0" -> true
    public static func hasUpFlag(_ output: String) -> Bool {
        let first = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
        guard let open = first.firstIndex(of: "<"), let close = first[open...].firstIndex(of: ">") else { return false }
        return first[first.index(after: open)..<close].split(separator: ",").contains("UP")
    }

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
