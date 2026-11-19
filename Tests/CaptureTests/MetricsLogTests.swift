import Foundation
import Pipeline
import Testing

import Capture

// a clock the test moves by hand
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 0.0
    func set(_ value: Double) { lock.lock(); t = value; lock.unlock() }
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return t }
}

private func tempFile() -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("metrics-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("m.csv").path
}

private func lines(_ path: String) throws -> [String] {
    try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
}

@Test func rowHasAllColumns() {
    var s = PipelineStats()
    s.packets = 120
    s.openFlows = 7
    s.peakOpenFlows = 9
    s.gapCount = 2
    s.maxGap = 12.5
    let row = MetricsLog.row(elapsed: 10, stats: s, kernelDropped: nil, residentBytes: 5_000_000)
    let fields = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    #expect(MetricsLog.header.split(separator: ",").count == fields.count)
    #expect(fields[0] == "10" && fields[1] == "120" && fields[2] == "7" && fields[3] == "9")
    #expect(fields[MetricsLog.columns.firstIndex(of: "maxGapMs")!] == "12500")
    #expect(fields[MetricsLog.columns.firstIndex(of: "kernelDropped")!] == "")
    #expect(fields.last == "5000000")
    let known = MetricsLog.row(elapsed: 1, stats: s, kernelDropped: 3, residentBytes: 1)
    #expect(known.split(separator: ",", omittingEmptySubsequences: false)[MetricsLog.columns.firstIndex(of: "kernelDropped")!] == "3")
}

@Test func writerWritesHeaderThenRowsOnCadence() throws {
    let path = tempFile()
    let clock = FakeClock()
    var writer = MetricsWriter(
        handle: try FileOwnership.openForWriting(path: path), interval: 2, clock: { clock.now() }, resident: { 42 })
    let stats = PipelineStats()
    var due: [Double] = []
    for t in stride(from: 0.0, through: 7.0, by: 1.0) {
        clock.set(t)
        if writer.isDue() {
            due.append(t)
            writer.write(stats: stats, kernelDropped: nil)
        }
    }
    #expect(due == [0, 2, 4, 6])
    let out = try lines(path)
    #expect(out.first == MetricsLog.header)
    #expect(out.count == 5)
    #expect(out[2].hasPrefix("2,") && out[2].hasSuffix(",42"))
}

@Test func writerKeepsItsSlotsWhenWakeUpsAreLate() throws {
    // the real task woke every 1.031 s (sleep overshoot plus the stats read): waiting `interval` after each
    // actual write gave a 2.06 s period, 873 rows in 1,800 s. fixed slots give 900
    let path = tempFile()
    let clock = FakeClock()
    var writer = MetricsWriter(
        handle: try FileOwnership.openForWriting(path: path), interval: 2, clock: { clock.now() }, resident: { 1 })
    var t = 0.0
    while t <= 1800 {
        clock.set(t)
        if writer.isDue() { writer.write(stats: PipelineStats(), kernelDropped: nil) }
        t += 1.031
    }
    #expect(writer.rows >= 899 && writer.rows <= 901)
    #expect(writer.skippedSlots == 0)
}

@Test func writerCountsASlotMissedCompletely() throws {
    let path = tempFile()
    let clock = FakeClock()
    var writer = MetricsWriter(
        handle: try FileOwnership.openForWriting(path: path), interval: 2, clock: { clock.now() }, resident: { 1 })
    for t in [0.0, 2.0, 4.0, 11.5, 12.0, 14.0] {
        clock.set(t)
        #expect(writer.secondsUntilDue() >= 0)
        if writer.isDue() { writer.write(stats: PipelineStats(), kernelDropped: nil) }
    }
    // rows at 0, 2, 4, 11.5, 12, 14: slots 3 and 4 (6 and 8) passed unwritten, slot 5 (10) was caught late
    #expect(writer.rows == 6)
    #expect(writer.skippedSlots == 2)
    // the real elapsed time is in each row (rounded to a second), so the 7.5 s gap shows
    let out = try lines(path)
    #expect(out[3].hasPrefix("4,") && out[4].hasPrefix("12,"))
}

@Test func footprintIsPositive() {
    #expect((MetricsLog.residentBytes() ?? 0) > 0)
}

@Test func metricsFileIsPrivateAndNeverOverwritten() throws {
    let path = tempFile()
    _ = try FileOwnership.openForWriting(path: path)
    var info = stat()
    #expect(stat(path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(throws: FileOwnership.OpenError.failed(errno: EEXIST)) { try FileOwnership.openForWriting(path: path) }
}

@Test func metricsFileRefusesSymlink() throws {
    let path = tempFile()
    let link = path + ".link"
    #expect(symlink(path + ".target", link) == 0)
    #expect(throws: FileOwnership.OpenError.self) { try FileOwnership.openForWriting(path: link) }
    #expect(!FileManager.default.fileExists(atPath: path + ".target"))
}

// minutes of synthetic samples, one per 10 s, resident = base + perMinute * minutes (+ a warm-up ramp)
private func synthetic(minutes: Int, perMinute: Double, warmup: Double = 0) -> String {
    var out = [MetricsLog.header]
    for i in 0...(minutes * 6) {
        let t = Double(i * 10)
        let ramp = warmup * (1 - exp(-t / 120))
        let r = 50_000_000 + ramp + perMinute * t / 60
        var s = PipelineStats()
        s.packets = i * 100
        s.peakOpenFlows = min(i, 300)
        s.gapCount = i >= 60 ? 1 : 0
        s.maxGap = i >= 60 ? 600 : 0
        out.append(MetricsLog.row(elapsed: t, stats: s, kernelDropped: nil, residentBytes: UInt64(r)))
    }
    return out.joined(separator: "\n") + "\n"
}

@Test func analysisFlatRunIsFlat() throws {
    // a ramp in the first minutes (warm-up) must not count: only the last two thirds are fitted
    let s = try MetricsAnalysis.summarize(csv: synthetic(minutes: 30, perMinute: 0, warmup: 20_000_000))
    #expect(s.rows == 181)
    #expect(s.durationSeconds == 1800)
    #expect(abs(s.slopeBytesPerMinute) < 100_000)
    #expect(s.isFlat)
    #expect(s.peakOpenFlows == 181 - 1 && s.peakOpenFlows <= 300)
    #expect(s.totalGaps == 1 && s.longestGapMs == 600_000)
    #expect(MetricsAnalysis.render(s).contains("memory flat"))
}

@Test func analysisGrowingRunIsNotFlat() throws {
    let s = try MetricsAnalysis.summarize(csv: synthetic(minutes: 30, perMinute: 500_000))
    #expect(abs(s.slopeBytesPerMinute - 500_000) < 5_000)
    #expect(!s.isFlat)
    #expect(s.maxResident > s.minResident)
    #expect(!MetricsAnalysis.render(s).contains("memory flat"))
}

@Test func analysisRejectsOtherFiles() {
    #expect(throws: MetricsAnalysis.ParseError.header) { try MetricsAnalysis.summarize(csv: "a,b\n1,2\n") }
    #expect(throws: MetricsAnalysis.ParseError.noRows) { try MetricsAnalysis.summarize(csv: MetricsLog.header + "\n") }
}
