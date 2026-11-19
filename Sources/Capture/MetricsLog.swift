import Foundation
import Pipeline

// the --metrics file: one csv row every few seconds, numbers only (no hostnames, addresses or device
// ids). the writer is a plain value the cli calls from its own task; nothing here runs per packet.
// the analysis half reads such a file back and judges whether memory is flat.

public enum MetricsLog {
    public static let columns = [
        "elapsedSeconds", "packets", "openFlows", "peakOpenFlows", "pendingDomains", "handshakeStates",
        "evictedFlows", "droppedClosedFlows", "tallyRowsFolded", "droppedDomains", "handshakeStatesDropped",
        "retainedDropped", "retainedDomainsDropped", "interfacesFolded", "gapCount", "maxGapMs",
        "kernelDropped", "residentBytes",
    ]
    public static var header: String { columns.joined(separator: ",") }
    public static let defaultInterval: TimeInterval = 2

    /// one csv line (no newline). kernelDropped is empty when not known yet
    public static func row(elapsed: TimeInterval, stats s: PipelineStats, kernelDropped: Int?, residentBytes: UInt64) -> String {
        let fields: [String] = [
            String(Int(elapsed.rounded())), "\(s.packets)", "\(s.openFlows)", "\(s.peakOpenFlows)",
            "\(s.pendingDomains)", "\(s.handshakeStates)", "\(s.evictedFlows)", "\(s.droppedClosedFlows)",
            "\(s.tallyRowsFolded)", "\(s.droppedDomains)", "\(s.handshakeStatesDropped)", "\(s.retainedDropped)",
            "\(s.retainedDomainsDropped)", "\(s.interfacesFolded)", "\(s.gapCount)",
            "\(Int((s.maxGap * 1000).rounded()))", kernelDropped.map(String.init) ?? "", "\(residentBytes)",
        ]
        return fields.joined(separator: ",")
    }

    /// resident memory of this process in bytes (mach_task_basic_info), nil if the call fails
    public static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}

/// writes the header at creation, then one row per time slot: slot k is due `k * interval` seconds after
/// the first row. the schedule is fixed to those slots, not to when the previous row happened to be
/// written, so a late wake-up delays one row and never the ones after it (a timer that waited
/// `interval` after each actual write drifted: 873 rows in 1,800 s instead of 900). a slot missed
/// completely (the process was stalled for more than an interval) is counted in `skippedSlots` and not
/// back-filled: a row repeating stale stats says nothing. every row carries its real elapsed time, so
/// gaps are visible in the file. the clock is injected (seconds since the capture started)
public struct MetricsWriter: Sendable {
    private let handle: FileHandle
    private let interval: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let resident: @Sendable () -> UInt64?
    private var firstWritten: TimeInterval?
    private var lastSlot = 0
    private var nextDue: TimeInterval?
    public private(set) var rows = 0
    /// slots that passed without any row
    public private(set) var skippedSlots = 0

    public init(
        handle: FileHandle, interval: TimeInterval = MetricsLog.defaultInterval,
        clock: @escaping @Sendable () -> TimeInterval, resident: @escaping @Sendable () -> UInt64? = MetricsLog.residentBytes
    ) {
        self.handle = handle
        self.interval = interval
        self.clock = clock
        self.resident = resident
        try? handle.write(contentsOf: Data((MetricsLog.header + "\n").utf8))
    }

    /// true when the row is due now; the caller then reads the stats and calls `write`
    public func isDue() -> Bool {
        guard let nextDue else { return true }
        return clock() >= nextDue
    }

    /// seconds until the next row is due (0 when due now), for a caller that sleeps until then
    public func secondsUntilDue() -> TimeInterval {
        guard let nextDue else { return 0 }
        return max(0, nextDue - clock())
    }

    /// writes a row now, whatever the cadence (the final row at stop)
    public mutating func write(stats: PipelineStats, kernelDropped: Int?) {
        let now = clock()
        let line = MetricsLog.row(
            elapsed: now, stats: stats, kernelDropped: kernelDropped, residentBytes: resident() ?? 0)
        try? handle.write(contentsOf: Data((line + "\n").utf8))
        rows += 1
        guard interval > 0 else { return }
        let start = firstWritten ?? now
        firstWritten = start
        let slot = Int(((now - start) / interval).rounded(.down))
        if rows > 1 { skippedSlots += max(0, slot - lastSlot - 1) }
        lastSlot = max(lastSlot, slot)
        nextDue = start + Double(lastSlot + 1) * interval
    }
}

/// result of reading a metrics file back
public struct MetricsSummary: Equatable, Sendable {
    public var rows = 0
    public var durationSeconds = 0.0
    public var minResident: UInt64 = 0
    public var maxResident: UInt64 = 0
    public var lastResident: UInt64 = 0
    /// least-squares slope of resident bytes over the last two thirds of the run, bytes per minute
    public var slopeBytesPerMinute = 0.0
    public var peakOpenFlows = 0
    public var totalGaps = 0
    public var longestGapMs = 0
    public var lastPackets = 0
    /// number of rows the slope used
    public var slopeRows = 0

    /// a slope under this is "flat": 1 MB per 10 minutes. the plan gives no threshold for the
    /// 30-minute run (it asks for a number in MB per hour), so this one is ours
    public static let flatBytesPerMinute = 1_000_000.0 / 10

    public var isFlat: Bool { slopeRows >= 3 && slopeBytesPerMinute < Self.flatBytesPerMinute }
}

public enum MetricsAnalysis {
    public enum ParseError: Error, Equatable { case header, noRows }

    public static func summarize(csv: String) throws -> MetricsSummary {
        var lines = csv.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty, lines.removeFirst().split(separator: ",").map(String.init) == MetricsLog.columns
        else { throw ParseError.header }
        func column(_ name: String) -> Int { MetricsLog.columns.firstIndex(of: name)! }
        let iT = column("elapsedSeconds"), iR = column("residentBytes"), iF = column("peakOpenFlows")
        let iG = column("gapCount"), iM = column("maxGapMs"), iP = column("packets")
        var points: [(t: Double, r: Double)] = []
        var s = MetricsSummary()
        for line in lines {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == MetricsLog.columns.count, let t = Double(f[iT]), let r = UInt64(f[iR]),
                let flows = Int(f[iF]), let gaps = Int(f[iG]), let maxGap = Int(f[iM]), let packets = Int(f[iP])
            else { continue }
            points.append((t, Double(r)))
            s.minResident = points.count == 1 ? r : min(s.minResident, r)
            s.maxResident = max(s.maxResident, r)
            s.lastResident = r
            s.peakOpenFlows = max(s.peakOpenFlows, flows)
            s.totalGaps = max(s.totalGaps, gaps)
            s.longestGapMs = max(s.longestGapMs, maxGap)
            s.lastPackets = packets
        }
        guard let first = points.first, let last = points.last else { throw ParseError.noRows }
        s.rows = points.count
        s.durationSeconds = last.t
        let from = first.t + (last.t - first.t) / 3
        let tail = points.filter { $0.t >= from }
        s.slopeRows = tail.count
        s.slopeBytesPerMinute = slope(tail) * 60
        return s
    }

    /// least squares of r against t, bytes per second; 0 for fewer than 2 points or equal times
    static func slope(_ p: [(t: Double, r: Double)]) -> Double {
        guard p.count >= 2 else { return 0 }
        let n = Double(p.count)
        let mt = p.map(\.t).reduce(0, +) / n, mr = p.map(\.r).reduce(0, +) / n
        let den = p.map { ($0.t - mt) * ($0.t - mt) }.reduce(0, +)
        guard den > 0 else { return 0 }
        return p.map { ($0.t - mt) * ($0.r - mr) }.reduce(0, +) / den
    }

    public static func render(_ s: MetricsSummary) -> String {
        func mb(_ b: UInt64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }
        let mins = s.durationSeconds / 60
        var out = [
            String(format: "Duration: %.0f s (%.1f min), rows: %d, packets: %d", s.durationSeconds, mins, s.rows, s.lastPackets),
            "Resident memory: min \(mb(s.minResident)), max \(mb(s.maxResident)), last \(mb(s.lastResident))",
            String(format: "Slope over the last two thirds (%d rows): %.0f bytes/min (%.2f MB/hour)",
                   s.slopeRows, s.slopeBytesPerMinute, s.slopeBytesPerMinute * 60 / 1_048_576),
            "Peak open flows: \(s.peakOpenFlows)",
            "Gaps: \(s.totalGaps), longest \(String(format: "%.1f", Double(s.longestGapMs) / 1000)) s",
        ]
        if s.isFlat {
            out.append("Verdict: memory flat (slope under 1 MB per 10 minutes)")
        } else if s.slopeRows < 3 {
            out.append("Verdict: too few rows to judge")
        } else {
            out.append("Verdict: memory growing (slope at or over 1 MB per 10 minutes)")
        }
        return out.joined(separator: "\n")
    }
}
