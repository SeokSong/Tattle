import Foundation
import Testing

import Capture

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func hit() { lock.lock(); value += 1; lock.unlock() }
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func verdict(
    _ watchdog: inout StallWatchdog, silence: TimeInterval, at now: Date? = nil, running: Bool = true, link: Bool,
    calls: Calls
) async -> StallWatchdog.Verdict {
    await watchdog.evaluate(
        now: now ?? t0.addingTimeInterval(silence), lastByteAt: t0, processRunning: running
    ) {
        calls.hit()
        return link
    }
}

@Suite struct StallWatchdogTests {
    @Test func okWhenBytesRecent() async {
        var w = StallWatchdog()
        let calls = Calls()
        #expect(await verdict(&w, silence: 3, link: false, calls: calls) == .ok)
        #expect(calls.count == 0)
    }

    @Test func quietButAliveWhenLinkUp() async {
        var w = StallWatchdog()
        let calls = Calls()
        #expect(await verdict(&w, silence: 20, link: true, calls: calls) == .quietButAlive)
        #expect(calls.count == 1)
    }

    @Test func linkDownWhenInterfaceGone() async {
        var w = StallWatchdog()
        let calls = Calls()
        #expect(await verdict(&w, silence: 20, link: false, calls: calls) == .linkDown)
    }

    @Test func processExitedWins() async {
        var w = StallWatchdog()
        let calls = Calls()
        #expect(await verdict(&w, silence: 60, running: false, link: false, calls: calls) == .processExited)
        #expect(calls.count == 0)
    }

    @Test func boundaryAtFifteenSeconds() async {
        var w = StallWatchdog()
        let calls = Calls()
        #expect(await verdict(&w, silence: 15, link: false, calls: calls) == .ok)
        #expect(calls.count == 0)
        #expect(await verdict(&w, silence: 15.001, link: false, calls: calls) == .linkDown)
        #expect(calls.count == 1)
    }

    @Test func linkCheckIsRateLimited() async {
        var w = StallWatchdog()
        let calls = Calls()
        #expect(await verdict(&w, silence: 16, link: true, calls: calls) == .quietButAlive)
        #expect(await verdict(&w, silence: 17, link: true, calls: calls) == .quietButAlive)
        #expect(calls.count == 1)
        // 5 s after the first check it runs again
        #expect(await verdict(&w, silence: 21, link: true, calls: calls) == .quietButAlive)
        #expect(calls.count == 2)
    }

    @Test func rateLimitResetsWhenBytesResume() async {
        var w = StallWatchdog()
        let calls = Calls()
        _ = await verdict(&w, silence: 16, link: true, calls: calls)
        #expect(await verdict(&w, silence: 1, link: true, calls: calls) == .ok)
        _ = await verdict(&w, silence: 16, link: true, calls: calls)
        #expect(calls.count == 2)
    }

    @Test func upFlagParsing() {
        #expect(LinkProbe.hasUpFlag("rvi0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 0\n\tether 1"))
        #expect(!LinkProbe.hasUpFlag("rvi0: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 0"))
        #expect(!LinkProbe.hasUpFlag(""))
    }

    @Test func runnerWithFakeClockEndsOnLinkDown() async {
        // a fake clock that advances 5 s per sleep, so 15 s of silence costs no real time
        let clock = FakeClock()
        let down = Calls()
        let result = await runStallWatchdog(
            StallWatchdog(),
            now: { clock.now },
            sleep: { clock.advance($0) },
            lastByteAt: { t0 },
            processRunning: { true },
            linkUp: { false },
            onLinkDown: { down.hit() })
        #expect(result == .linkDown)
        #expect(down.count == 1)
        #expect(clock.now.timeIntervalSince(t0) > 15)
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = t0
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}
