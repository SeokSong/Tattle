import Companies
import Foundation

/// a letter grade for one app's advertising and tracking exposure (owner, 2026-11-24, revising OD4's word bands).
/// it counts companies the app contacted; it says nothing about what the app does with data, so it is always
/// shown with the count, never alone, and never called safe
public enum Grade: String, CaseIterable, Sendable, Equatable {
    case A, B, C, D, F
}

/// why the rating scale failed to load
public enum RatingScaleError: Error, Equatable, Sendable {
    case missingKey(String)
    case notANumber(String)
    /// the maximums must rise A < B < C < D (A may be 0), and the threshold must be 1 to 100
    case outOfOrder
    case fileMissing
    case file(WordingError)
}

/// the cut-offs, read from Resources/rating.toml so they can be changed without code
public struct RatingScale: Sendable, Equatable {
    public let aMax: Int, bMax: Int, cMax: Int, dMax: Int
    /// an app is rated only when every source with data for it is at least this percent traced
    public let thresholdPercent: Int

    public init(aMax: Int, bMax: Int, cMax: Int, dMax: Int, thresholdPercent: Int) throws(RatingScaleError) {
        guard aMax >= 0, aMax < bMax, bMax < cMax, cMax < dMax, (1...100).contains(thresholdPercent) else { throw .outOfOrder }
        self.aMax = aMax
        self.bMax = bMax
        self.cMax = cMax
        self.dMax = dMax
        self.thresholdPercent = thresholdPercent
    }

    public init(parsing text: String) throws(RatingScaleError) {
        let file: Wording
        do { file = try Wording(parsing: text) } catch { throw .file(error) }
        func number(_ key: String) throws(RatingScaleError) -> Int {
            guard let raw = file.entries[key] else { throw .missingKey(key) }
            guard let n = Int(raw) else { throw .notANumber(key) }
            return n
        }
        try self.init(aMax: number("grade.A.max"), bMax: number("grade.B.max"), cMax: number("grade.C.max"),
                      dMax: number("grade.D.max"), thresholdPercent: number("threshold.percent"))
    }

    public func grade(forCount n: Int) -> Grade {
        if n <= aMax { return .A }
        if n <= bMax { return .B }
        if n <= cMax { return .C }
        if n <= dMax { return .D }
        return .F
    }

    /// the exact ratio decides, never the shown text
    public func meetsThreshold(_ ratio: CoverageRatio) -> Bool {
        ratio.denominator > 0 && min(ratio.numerator, ratio.denominator) * 100 >= thresholdPercent * ratio.denominator
    }

    public static func loadBundled() throws -> RatingScale {
        guard let url = Wording.resourceURL("rating.toml") else { throw RatingScaleError.fileMissing }
        return try RatingScale(parsing: String(contentsOf: url, encoding: .utf8))
    }

    /// the owner's scale (A 0, B 1, C 2-3, D 4-5, F 6+, 70%), used only when the file cannot be read; a test
    /// checks the file loads, so this is a safety net, never a second place to change the scale
    public static let fallback: RatingScale = try! RatingScale(aMax: 0, bMax: 1, cMax: 3, dMax: 5, thresholdPercent: 70)

    /// a broken file is reported once on standard error (the app keeps working on the fallback scale)
    public static let bundled: RatingScale = {
        do { return try loadBundled() } catch {
            FileHandle.standardError.write(Data("rating.toml could not be read (\(error)); using the built-in scale\n".utf8))
            return fallback
        }
    }()
}

public enum RatingResult: Sendable, Equatable {
    /// the grade and the number of advertising or tracking companies it rests on
    case graded(Grade, count: Int)
    /// a source with data is under the threshold; the lowest traced share, as a coverage ratio
    case notEnoughData(CoverageRatio)
}

public enum Rating {
    /// the companies that count: every company with an advertising or analytics category, the app's own company
    /// included (owner, 2026-11-24, revising OD4: the closed row and the opened row must agree). content delivery,
    /// cloud, online and Apple system companies have no such category, so they never count
    public static func countedCompanies(_ companies: [CombinedCompany]) -> [CombinedCompany] {
        companies.filter(\.isAdvertisingOrTracking)
    }

    /// one grade from both sources together (owner, 2026-11-24). nil when no source has anything to trace.
    /// every source with data must meet the threshold (OD8); otherwise the lowest share is reported
    public static func rate(companies: [CombinedCompany], capture: CoverageRatio?, report: CoverageRatio?,
                            scale: RatingScale = .bundled) -> RatingResult? {
        let sources = [capture, report].compactMap { $0 }.filter { $0.denominator > 0 }
        guard !sources.isEmpty else { return nil }
        let short = sources.filter { !scale.meetsThreshold($0) }
        if let lowest = short.min(by: { $0.numerator * $1.denominator < $1.numerator * $0.denominator }) {
            return .notEnoughData(lowest)
        }
        let count = countedCompanies(companies).count
        return .graded(scale.grade(forCount: count), count: count)
    }

    /// the card's rating. iOS system and the merged Apple apps card get none: a grade judges one app
    public static func rate(card: AppCard, scale: RatingScale = .bundled) -> RatingResult? {
        guard card.kind == .app else { return nil }
        return rate(companies: card.companies, capture: card.capture?.coverage, report: card.report?.coverage, scale: scale)
    }

    /// the closed row's text: "C · 3 advertising or tracking companies" or "Not enough data to rate (65.0% traced)"
    public static func text(_ result: RatingResult) -> String {
        let w = Wording.bundled
        switch result {
        case .graded(let grade, let count):
            let key = count == 0 ? "rating.grade.none" : count == 1 ? "rating.grade.one" : "rating.grade.other"
            return w.text(key, ["grade": grade.rawValue, "count": String(count)])
        case .notEnoughData(let ratio):
            return w.text("rating.notenough", ["percent": SummaryText.percentText(ratio.numerator, of: ratio.denominator) ?? "0.0"])
        }
    }
}
