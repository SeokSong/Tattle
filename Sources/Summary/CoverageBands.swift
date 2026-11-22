import Foundation

// band files for company coverage: numbers only, committed. the JSON shape is the quality report's band
// file (scenario, baselineLabel, totalsBand, metrics, notes) so one reader can open both. every coverage
// metric is "higher is better". the frozen curated-only baseline is the floor: a later source may raise
// coverage and must never lower it

public struct CoverageBand: Codable, Equatable, Sendable {
    public var baseline: Double
    public var floor: Double?
    public var ceiling: Double?
    /// small denominator: recorded but never enforced
    public var informational: Bool

    public init(baseline: Double, floor: Double? = nil, ceiling: Double? = nil, informational: Bool = false) {
        self.baseline = baseline
        self.floor = floor
        self.ceiling = ceiling
        self.informational = informational
    }

    private enum CodingKeys: String, CodingKey { case baseline, floor, ceiling, informational }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try c.decode(Double.self, forKey: .baseline)
        floor = try c.decodeIfPresent(Double.self, forKey: .floor)
        ceiling = try c.decodeIfPresent(Double.self, forKey: .ceiling)
        informational = try c.decodeIfPresent(Bool.self, forKey: .informational) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseline, forKey: .baseline)
        try c.encodeIfPresent(floor, forKey: .floor)
        try c.encodeIfPresent(ceiling, forKey: .ceiling)
        if informational { try c.encode(true, forKey: .informational) }
    }
}

public struct CoverageBandNote: Codable, Equatable, Sendable {
    public var metric: String
    public var reason: String

    public init(metric: String, reason: String) {
        self.metric = metric
        self.reason = reason
    }
}

public struct CoverageBands: Codable, Equatable, Sendable {
    public var scenario: String
    public var baselineLabel: String
    public var totalsBand: [String: String]
    public var metrics: [String: CoverageBand]
    public var notes: [CoverageBandNote]

    public init(
        scenario: String, baselineLabel: String, totalsBand: [String: String] = [:],
        metrics: [String: CoverageBand] = [:], notes: [CoverageBandNote] = []
    ) {
        self.scenario = scenario
        self.baselineLabel = baselineLabel
        self.totalsBand = totalsBand
        self.metrics = metrics
        self.notes = notes
    }

    public static func load(_ url: URL) throws -> CoverageBands {
        try JSONDecoder().decode(CoverageBands.self, from: Data(contentsOf: url))
    }

    /// sorted keys, pretty printed, newline at the end: a stable file for review
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    /// bytes below this are too few to enforce a byte ratio. domain ratios are always enforced: the data is
    /// exact and a handful of domains is all a short capture has
    public static let minBytes = 10_000
    /// how far below the baseline a value may fall. zero: coverage on a fixed capture and a fixed list is
    /// exact, so a lower value is a real loss. the M2 ratchet allows 0.5 points for measurement noise
    /// that does not exist here
    public static let tolerance = 0.0

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// a band per metric that has a value. floor is the exact value (minus `tolerance`), ceiling 1;
    /// the baseline beside it is rounded to 3 decimals for reading.
    /// `enforceSmall` enforces a byte ratio even when its denominator is small. notes of the
    /// previous file are kept
    public static func make(
        from report: CoverageReport, scenario: String, baselineLabel: String, previous: CoverageBands? = nil,
        enforceSmall: Bool = false
    ) -> CoverageBands {
        var metrics: [String: CoverageBand] = [:]
        for (key, ratio) in report.metrics {
            guard let value = ratio.value else { continue }
            // the share of each source is expected to move when a source is added: recorded, never a floor
            let small = key.hasPrefix("companyCoverage") && ratio.denominator < minBytes && !enforceSmall
            if small || key.hasPrefix("labelSourceShare.") {
                metrics[key] = CoverageBand(baseline: round3(value), informational: true)
            } else {
                metrics[key] = CoverageBand(
                    baseline: round3(value), floor: max(0, value - tolerance), ceiling: 1)
            }
        }
        return CoverageBands(
            scenario: scenario, baselineLabel: baselineLabel, metrics: metrics, notes: previous?.notes ?? [])
    }
}

public struct CoverageRegression: Equatable, Sendable {
    public var metric: String
    /// nil when the report has no value for the metric (missing, or a zero denominator)
    public var value: Double?
    public var floor: Double

    /// percentage points below the floor, counting no value as zero; always positive
    public var points: Double { (floor - (value ?? 0)) * 100 }

    /// numbers only
    public var description: String {
        guard let value else {
            return String(format: "%@  has no value (missing or zero denominator); floor is %.1f%%", metric, floor * 100)
        }
        return String(format: "%@  %.1f%% is below floor %.1f%% by %.1f points", metric, value * 100, floor * 100, points)
    }
}

public enum CoverageRatchet {
    /// a value equal to its floor passes. informational bands and bands without a floor, or with a
    /// floor of 0, are not enforced. an enforced band (floor above 0) fails when the report has no value
    /// for it: the metric is missing, or its denominator became 0 (a run that lost all its named
    /// domains must not pass)
    public static func check(report: CoverageReport, bands: CoverageBands) -> [CoverageRegression] {
        var found: [CoverageRegression] = []
        for key in bands.metrics.keys.sorted() {
            guard let band = bands.metrics[key], !band.informational, let floor = band.floor, floor > 0 else { continue }
            guard let value = report.metrics[key]?.value else {
                found.append(CoverageRegression(metric: key, value: nil, floor: floor))
                continue
            }
            if value < floor - 1e-12 { found.append(CoverageRegression(metric: key, value: value, floor: floor)) }
        }
        return found
    }
}
