import Attribution
import Companies
import Foundation

/// the largest cause of the part of an app's captured traffic that could not be traced, in tie-break order.
/// shown only behind the (i) icon (owner, 2026-11-24)
public enum CaptureRestReason: String, CaseIterable, Sendable {
    case hiddenByApp, startedBeforeCapture, noName, unknownDestination, possibleOnly
}

/// the summary sentences. the words live in Resources/wording.toml (`Wording`); this code only chooses which
/// sentence applies and fills in numbers and names. no speaker ever appears (owner, 2026-11-24)
public enum SummaryText {
    private static var w: Wording { Wording.bundled }

    // MARK: helpers

    /// tenths of a percent, rounded down, so a percent never overstates. nil when there is nothing to divide by
    public static func permille(_ numerator: Int, of denominator: Int) -> Int? {
        guard denominator > 0 else { return nil }
        return min(max(numerator, 0), denominator) * 1000 / denominator
    }

    /// the percent with one decimal (owner, 2026-11-24): "77.3", "0.5", "100.0"
    public static func percentText(_ numerator: Int, of denominator: Int) -> String? {
        permille(numerator, of: denominator).map(tenths)
    }

    static func tenths(_ value: Int) -> String { "\(value / 10).\(value % 10)" }

    /// the exact ratio decides, never the shown text: 69.98% is not rated
    public static func meetsRatingThreshold(_ numerator: Int, of denominator: Int) -> Bool {
        denominator > 0 && min(numerator, denominator) * 100 >= ratingThreshold * denominator
    }

    /// the year is shown when the two dates are in different years, or not in the current year (`now`)
    public static func period(from start: Date, to end: Date, timeZone: TimeZone, now: Date = Date()) -> String {
        func format(_ pattern: String, _ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = pattern
            return f.string(from: date)
        }
        let (d1, m1, y1) = (format("d", start), format("MMMM", start), format("yyyy", start))
        let (d2, m2, y2) = (format("d", end), format("MMMM", end), format("yyyy", end))
        if y1 != y2 { return "\(d1) \(m1) \(y1) to \(d2) \(m2) \(y2)" }
        let year = y2 == format("yyyy", now) ? "" : " \(y2)"
        if m1 != m2 { return "\(d1) \(m1) to \(d2) \(m2)\(year)" }
        if d1 != d2 { return "\(d1) to \(d2) \(m1)\(year)" }
        return "\(d1) \(m1)\(year)"
    }

    /// "A", "A and B", "A, B and C". callers pass at most three names
    public static func names(_ list: [String]) -> String {
        switch list.count {
        case 0: return ""
        case 1: return list[0]
        case 2: return w.text("join.two", ["a": list[0], "b": list[1]])
        default: return w.text("join.three", ["a": list[0], "b": list[1], "c": list[2]])
        }
    }

    private static func plural(_ base: String, _ n: Int) -> String { base + (n == 1 ? ".one" : ".other") }

    // MARK: overview

    /// two sentences: the companies with the advertising or tracking part, then the untraced part
    public static func overview(
        period: String, hasCaptures: Bool, hasReport: Bool, apps: Int, companies: Int, adTrack: Int, untraced: Int
    ) -> [String] {
        precondition(hasCaptures || hasReport, "an overview needs a source")
        let source = w.text(hasCaptures && hasReport ? "overview.source.both" : hasCaptures ? "overview.source.captures" : "overview.source.report")
        let values = [
            "source": source, "period": period, "count": String(adTrack),
            "apps": w.text(plural("count.app", apps), ["count": String(apps)]),
            "companies": w.text(plural("count.company", companies), ["count": String(companies)]),
        ]
        let tracking = w.text(adTrack == 0 ? "overview.tracking.none" : plural("overview.tracking", adTrack), values)
        let rest = w.text(untraced == 0 ? "overview.untraced.none" : plural("overview.untraced", untraced), ["count": String(untraced)])
        return [tracking, rest]
    }

    // MARK: each app

    /// the sentences shown when the reader opens an app. `companies` are the parent names in display order (own
    /// company first, then advertising or tracking, then the rest); `adTrack` the advertising or tracking ones in
    /// the same order; `untraced` the destinations that could not be traced; `typeKnown` how many of those the
    /// AdGuard list knows by type. the company part and the untraced part always come together
    public static func appSentences(
        app: String, companies: [String], adTrack: [String], untraced: Int, typeKnown: [CompanyCategory: Int]
    ) -> [String] {
        var out: [String] = []
        if companies.isEmpty {
            guard untraced > 0 else { return [] }
            out.append(w.text(plural("app.untraced.all", untraced), ["app": app, "count": String(untraced)]))
        } else {
            if companies.count <= 3 {
                out.append(w.text("app.companies.named", ["app": app, "names": names(companies)]))
            } else {
                out.append(w.text("app.companies.many", [
                    "app": app, "count": String(companies.count), "first": companies[0], "second": companies[1],
                ]))
            }
            if adTrack.isEmpty {
                out.append(w.text("app.tracking.none"))
            } else if companies.count == 1 {
                out.append(w.text("app.tracking.only", ["names": adTrack[0]]))
            } else if adTrack.count <= 3 {
                out.append(w.text(plural("app.tracking.named", adTrack.count), ["names": names(adTrack)]))
            } else {
                out.append(w.text("app.tracking.many", ["count": String(adTrack.count)]))
            }
            out.append(w.text(untraced == 0 ? "app.untraced.none" : plural("app.untraced", untraced), ["count": String(untraced)]))
        }
        // never more known-type destinations than untraced ones, in each category or in total
        var left = untraced
        for category in CompanyCategory.allCases where category != .unclassified {
            guard let raw = typeKnown[category], raw > 0, left > 0 else { continue }
            let k = min(raw, left)
            left -= k
            let kind = w.text(plural("kind.\(category.rawValue)", k))
            let key = untraced == 1 && k == 1 ? "app.typeknown.only" : plural("app.typeknown", k)
            out.append(w.text(key, ["kind": kind, "count": String(k)]))
        }
        return out
    }

    // MARK: company rows

    /// the own company keeps its categories, so the advertising or tracking count always has a row to point to
    public static func companyRow(parent: String, categories: [CompanyCategory], isOwnCompany: Bool) -> String {
        let labels = categories.filter { $0 != .unclassified }.map(\.label).joined(separator: ", ")
        let values = ["parent": parent, "categories": labels]
        if isOwnCompany { return w.text(labels.isEmpty ? "company.row.own" : "company.row.own.categories", values) }
        return w.text(labels.isEmpty ? "company.row.plain" : "company.row", values)
    }

    public static func brandText(brand: String, parent: String) -> String? {
        brand == parent ? nil : w.text("company.brand", ["brand": brand, "parent": parent])
    }

    public static func seenIn(captures: Bool, report: Bool) -> String {
        precondition(captures || report, "a company is seen in at least one source")
        return w.text(captures && report ? "seen.both" : captures ? "seen.captures" : "seen.report")
    }

    // MARK: possible

    public static var possibleHeading: String { w.text("possible.heading") }
    public static var possibleExplanation: String { w.text("possible.explanation") }

    // MARK: how much could be traced

    /// the reason with the most bytes; ties go to the earlier case; nil when nothing is left over
    public static func mainRestReason(summary: CaptureAppSummary) -> CaptureRestReason? {
        let bytes: [(CaptureRestReason, Int)] = [
            (.hiddenByApp, summary.unseen[.echHidden]?.bytes ?? 0),
            (.startedBeforeCapture, summary.unseen[.startedBeforeCapture]?.bytes ?? 0),
            (.noName, (summary.unseen[.noHandshakeUDP]?.bytes ?? 0) + (summary.unseen[.noDNSMatch]?.bytes ?? 0)),
            (.unknownDestination, summary.notIdentified.bytes),
            (.possibleOnly, summary.hinted.bytes),
        ]
        var best: (CaptureRestReason, Int)?
        for entry in bytes where entry.1 > 0 && entry.1 > (best?.1 ?? 0) { best = entry }
        return best?.0
    }

    /// nil when the app has no traffic to trace
    public static func captureCoverage(period: String, coverage: CoverageRatio) -> String? {
        guard let p = percentText(coverage.numerator, of: coverage.denominator) else { return nil }
        if coverage.numerator >= coverage.denominator { return w.text("coverage.captures.all", ["period": period]) }
        return w.text("coverage.captures", ["period": period, "percent": p])
    }

    /// the (i) text: the largest cause of the rest. nil when everything was traced or there is no cause
    public static func captureRestDetail(coverage: CoverageRatio, reason: CaptureRestReason?) -> String? {
        guard let reason, let p = permille(coverage.numerator, of: coverage.denominator), coverage.numerator < coverage.denominator else { return nil }
        return w.text("coverage.reason.\(reason.rawValue)", ["percent": tenths(1000 - p)])
    }

    public static func reportCoverage(period: String, identified: Int, total: Int) -> String? {
        guard total > 0 else { return nil }
        if total == 1 { return w.text(identified >= 1 ? "coverage.report.single.traced" : "coverage.report.single.untraced", ["period": period]) }
        return w.text("coverage.report", ["period": period, "identified": String(min(identified, total)), "total": String(total)])
    }

    // MARK: rating lines (the band itself is Part 4)

    public static let ratingThreshold = 70

    public static func captureRating(coverage: CoverageRatio) -> String? {
        guard let p = percentText(coverage.numerator, of: coverage.denominator) else { return nil }
        let shown = meetsRatingThreshold(coverage.numerator, of: coverage.denominator)
        return w.text(shown ? "rating.captures.shown" : "rating.captures.hidden", ["percent": p, "threshold": String(ratingThreshold)])
    }

    public static func reportRating(identified: Int, total: Int) -> String? {
        guard let p = percentText(identified, of: total) else { return nil }
        let shown = meetsRatingThreshold(identified, of: total)
        if total == 1 { return w.text(shown ? "rating.report.shown.single" : "rating.report.hidden.single", ["threshold": String(ratingThreshold)]) }
        return w.text(shown ? "rating.report.shown" : "rating.report.hidden", [
            "identified": String(min(identified, total)), "total": String(total), "percent": p,
            "threshold": String(ratingThreshold),
        ])
    }

    // MARK: special entries

    public static var systemDescription: String { w.text("special.system") }
    public static var appleAppsDescription: String { w.text("special.apple") }
    public static var appleAppsBreakdownHeading: String { w.text("special.apple.breakdown") }

    public static func noProcessSentence(_ n: Int) -> String? {
        n == 0 ? nil : w.text(plural("noprocess", n), ["count": String(n)])
    }

    // MARK: data amounts (captures only, with "Show data amounts" on)

    /// the capture day is required, so a bytes sentence can never be made without its date; the report side
    /// has no such function
    public static func dataAmountSentence(captureDay: String, company: String) -> String {
        w.text("data.amount", ["day": captureDay, "company": company])
    }

    // MARK: the file's schema

    /// every key the code uses and the placeholders it may contain. a test checks the file against it both ways
    public static let schema: [String: Set<String>] = {
        var s: [String: Set<String>] = [
            "count.app.one": [], "count.app.other": ["count"], "count.company.one": [], "count.company.other": ["count"],
            "join.two": ["a", "b"], "join.three": ["a", "b", "c"],
            "overview.source.both": [], "overview.source.captures": [], "overview.source.report": [],
            "overview.tracking.none": ["source", "period", "apps", "companies"],
            "overview.tracking.one": ["source", "period", "apps", "companies"],
            "overview.tracking.other": ["source", "period", "apps", "companies", "count"],
            "overview.untraced.none": [], "overview.untraced.one": [], "overview.untraced.other": ["count"],
            "app.companies.named": ["app", "names"], "app.companies.many": ["app", "count", "first", "second"],
            "app.tracking.none": [], "app.tracking.only": ["names"], "app.tracking.named.one": ["names"],
            "app.tracking.named.other": ["names"], "app.tracking.many": ["count"],
            "app.untraced.none": [], "app.untraced.one": [], "app.untraced.other": ["count"],
            "app.untraced.all.one": ["app"], "app.untraced.all.other": ["app", "count"],
            "app.typeknown.only": ["kind"], "app.typeknown.one": ["kind"], "app.typeknown.other": ["kind", "count"],
            "company.row": ["parent", "categories"], "company.row.plain": ["parent"], "company.row.own": ["parent"],
            "company.row.own.categories": ["parent", "categories"], "company.brand": ["brand", "parent"],
            "seen.both": [], "seen.captures": [], "seen.report": [],
            "possible.heading": [], "possible.explanation": [],
            "coverage.captures": ["period", "percent"], "coverage.captures.all": ["period"],
            "coverage.report": ["period", "identified", "total"],
            "coverage.report.single.traced": ["period"], "coverage.report.single.untraced": ["period"],
            "rating.captures.shown": ["percent"], "rating.captures.hidden": ["percent", "threshold"],
            "rating.report.shown": ["identified", "total", "percent"], "rating.report.shown.single": [],
            "rating.report.hidden": ["identified", "total", "percent", "threshold"],
            "rating.report.hidden.single": ["threshold"],
            "special.system": [], "special.apple": [], "special.apple.breakdown": [],
            "noprocess.one": [], "noprocess.other": ["count"], "data.amount": ["day", "company"],
            "howto.1": [], "howto.2": [], "howto.3": [], "howto.heading": [],
            "list.row": ["companies", "tracking"], "list.tracking.none": [], "list.tracking.one": [],
            "list.tracking.other": ["count"], "list.untraced.one": [], "list.untraced.other": ["count"],
            "list.nothing": [], "empty.state": [],
            "overview.bullet.companies.none": ["companies"], "overview.bullet.companies.one": ["companies"],
            "overview.bullet.companies.other": ["companies", "count"], "overview.bullet.untraced.none": [],
            "overview.bullet.untraced.one": [], "overview.bullet.untraced.other": ["count"],
            "overview.bullet.captures": ["period"], "overview.bullet.report": ["period"],
            "detail.heading.tracking": [], "detail.heading.other": [], "detail.heading.untraced": [], "detail.heading.traced": [],
            "detail.untraced.none": [], "detail.untraced.one": [], "detail.untraced.other": ["count"],
            "detail.untraced.kind.one": ["kind"], "detail.untraced.kind.other": ["kind", "count"],
            "detail.untraced.withkinds": ["destinations", "kinds"],
            "detail.traced.captures": ["percent"], "detail.traced.captures.all": [],
            "detail.traced.report": ["identified", "total"], "detail.traced.report.single": ["identified"],
            "detail.traced.report.help": [], "detail.possible": ["names"],
            "rating.grade.none": ["grade"], "rating.grade.one": ["grade"], "rating.grade.other": ["grade", "count"],
            "rating.notenough": ["percent"],
        ]
        for reason in CaptureRestReason.allCases { s["coverage.reason.\(reason.rawValue)"] = ["percent"] }
        for category in CompanyCategory.allCases where category != .unclassified {
            s["kind.\(category.rawValue).one"] = []
            s["kind.\(category.rawValue).other"] = []
        }
        for n in 1...Glossary.termCount {
            s["glossary.\(n).term"] = []
            s["glossary.\(n).text"] = []
        }
        return s
    }()
}
