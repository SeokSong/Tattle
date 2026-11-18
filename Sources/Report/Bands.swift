import Foundation

// band files hold numbers only, never names or addresses: they are committed (Tests/Expected/<id>.json).
// a band is a floor and a ceiling around a baseline measured on a real capture. the ratchet fails a
// report that drops below a floor or rises above a ceiling.

public struct MetricBand: Codable, Equatable, Sendable {
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

public struct BandNote: Codable, Equatable, Sendable {
    public var metric: String
    public var reason: String

    public init(metric: String, reason: String) {
        self.metric = metric
        self.reason = reason
    }
}

public struct BandsFile: Codable, Equatable, Sendable {
    public var scenario: String
    public var baselineLabel: String
    /// free-form numeric ranges such as "ipBytes": "1-2 MB"; information only, not enforced
    public var totalsBand: [String: String]
    public var metrics: [String: MetricBand]
    public var notes: [BandNote]

    public init(
        scenario: String, baselineLabel: String, totalsBand: [String: String] = [:],
        metrics: [String: MetricBand] = [:], notes: [BandNote] = []
    ) {
        self.scenario = scenario
        self.baselineLabel = baselineLabel
        self.totalsBand = totalsBand
        self.metrics = metrics
        self.notes = notes
    }

    public static func load(_ url: URL) throws -> BandsFile {
        try JSONDecoder().decode(BandsFile.self, from: Data(contentsOf: url))
    }

    /// sorted keys, pretty printed, newline at the end: a stable file for review
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }
}

extension QualityReport {
    /// the metrics a band file can name, by key
    public var metrics: [String: Ratio] {
        [
            "attributedShare": attribution.attributedShare,
            "noProcessShare": attribution.noProcessShare,
            "mixedFlowShare": attribution.mixedFlowShare,
            "hostnameCoverageSniOnly": hostnames.hostnameCoverageSniOnly,
        ]
    }
}

public enum Bands {
    /// a denominator below this (bytes) is too small to enforce
    public static let minDenominator = 10_000
    public static let tolerance = 0.005
    /// metrics where a smaller value is better; the rest are "higher is better"
    public static let lowerIsBetter: Set<String> = ["noProcessShare", "mixedFlowShare"]

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// tolerance rule, used when a band file is created or updated:
    /// - lower is better: floor 0.0, ceiling = baseline + 0.005
    /// - higher is better: floor = baseline - 0.005, ceiling 1.0
    /// values are rounded to 3 decimals and kept inside [0, 1]. metrics with a denominator under
    /// `minDenominator` or no value are marked informational with no floor or ceiling.
    /// notes of the previous file are kept
    public static func make(
        from report: QualityReport, scenario: String, baselineLabel: String, previous: BandsFile? = nil
    ) -> BandsFile {
        var metrics: [String: MetricBand] = [:]
        for (name, ratio) in report.metrics {
            guard let value = ratio.value else { continue }
            let baseline = round3(value)
            if ratio.denominator < minDenominator {
                metrics[name] = MetricBand(baseline: baseline, informational: true)
            } else if lowerIsBetter.contains(name) {
                metrics[name] = MetricBand(baseline: baseline, floor: 0, ceiling: min(1, round3(value + tolerance)))
            } else {
                metrics[name] = MetricBand(baseline: baseline, floor: max(0, round3(value - tolerance)), ceiling: 1)
            }
        }
        return BandsFile(
            scenario: scenario, baselineLabel: baselineLabel,
            totalsBand: ["ipBytes": megabyteRange(report.totals.ipBytes)],
            metrics: metrics, notes: previous?.notes ?? [])
    }

    /// "1-2 MB" for 1.4 MB; "under 1 MB" below that
    static func megabyteRange(_ bytes: Int) -> String {
        let mb = bytes / 1_000_000
        return mb < 1 ? "under 1 MB" : "\(mb)-\(mb + 1) MB"
    }
}

public struct Regression: Equatable, Sendable {
    public enum Kind: String, Sendable { case belowFloor, aboveCeiling }

    public var metric: String
    public var kind: Kind
    public var value: Double
    public var limit: Double

    /// percentage points past the limit; always positive
    public var points: Double { abs(value - limit) * 100 }

    /// numbers only: the metric key, the value, the limit and the distance
    public var description: String {
        let side = kind == .belowFloor ? "below floor" : "above ceiling"
        return String(
            format: "%@  %.1f%% is %@ %.1f%% by %.1f points", metric, value * 100, side, limit * 100, points)
    }
}

public enum Ratchet {
    /// a value equal to its floor or ceiling passes. informational bands, metrics missing from the report,
    /// and metrics whose denominator is under `Bands.minDenominator` or zero are not enforced
    public static func check(report: QualityReport, bands: BandsFile) -> [Regression] {
        let eps = 1e-9
        var found: [Regression] = []
        let measured = report.metrics
        for name in bands.metrics.keys.sorted() {
            guard let band = bands.metrics[name], !band.informational,
                  let ratio = measured[name], ratio.denominator >= Bands.minDenominator,
                  let value = ratio.value else { continue }
            if let floor = band.floor, value < floor - eps {
                found.append(Regression(metric: name, kind: .belowFloor, value: value, limit: floor))
            }
            if let ceiling = band.ceiling, value > ceiling + eps {
                found.append(Regression(metric: name, kind: .aboveCeiling, value: value, limit: ceiling))
            }
        }
        return found
    }
}
