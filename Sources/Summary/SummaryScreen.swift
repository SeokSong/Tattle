import Companies
import Foundation

// read time only. turns the combined summary into the first screen: a list of apps, each row openable.
// every text comes from `SummaryText`, `Glossary` or `Wording`; nothing here is worded in code.

/// one company bullet inside an opened row
public struct CompanyLine: Sendable, Equatable, Identifiable {
    public var id: String { parent }
    public let parent: String
    /// `SummaryText.companyRow(parent:categories:isOwnCompany:)` (own company = relation .sameCompanyAsApp)
    public let text: String
    /// `SummaryText.brandText(brand:parent:)` for every brand that differs from the parent, in brand order
    public let brands: [String]
    /// `SummaryText.seenIn(captures:report:)`, shown on hover only (owner, 2026-11-24)
    public let seenIn: String
    /// 5.2: the company's share of the app's captured traffic ("12.3% of data", "under 1% of data"), shown only
    /// with "Show data amounts" on; nil when the company was not seen in captures
    public let dataShare: String?

    public init(parent: String, text: String, brands: [String], seenIn: String, dataShare: String? = nil) {
        self.parent = parent
        self.text = text
        self.brands = brands
        self.seenIn = seenIn
        self.dataShare = dataShare
    }
}

/// one bullet under "Traced", with its (i) text
public struct TracedLine: Sendable, Equatable, Identifiable {
    public var id: String { text }
    public let text: String
    /// the (i) text: the largest cause of the rest for captures, the no-data-amounts note for the report
    public let detail: String?

    public init(text: String, detail: String?) {
        self.text = text
        self.detail = detail
    }
}

/// one row of the list; opening it shows grouped bullets (owner, 2026-11-24: bullets, not sentences)
public struct SummaryRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: CardKind
    public let title: String
    /// the closed row's text: the rating when the app has one ("C · 3 advertising or tracking companies"),
    /// else the counts
    public let subtitle: String
    /// nil for iOS system, the merged Apple apps card, and an app with nothing to trace
    public let rating: RatingResult?
    /// `SummaryText.systemDescription` for iOS system, `appleAppsDescription` for Apple apps, else nil
    public let description: String?
    /// under "Advertising or tracking": the companies with an advertising or analytics category, own company first
    public let trackingCompanies: [CompanyLine]
    /// under "Other companies"
    public let otherCompanies: [CompanyLine]
    /// the one bullet under "Not traced" (always present: the unknown part is never left out)
    public let untraced: String
    /// the bullets under "Traced": captures first, then the report
    public let traced: [TracedLine]
    /// "Possible, not counted: ..." or nil; its (i) text is `SummaryScreen.possibleExplanation`
    public let possible: String?
    /// Apple apps only: one row per Apple app, ordered like the list
    public let children: [SummaryRow]

    public init(
        id: String, kind: CardKind, title: String, subtitle: String, rating: RatingResult? = nil, description: String?,
        trackingCompanies: [CompanyLine], otherCompanies: [CompanyLine], untraced: String, traced: [TracedLine],
        possible: String?, children: [SummaryRow]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.rating = rating
        self.description = description
        self.trackingCompanies = trackingCompanies
        self.otherCompanies = otherCompanies
        self.untraced = untraced
        self.traced = traced
        self.possible = possible
        self.children = children
    }
}

public struct SummaryScreen: Sendable, Equatable {
    /// the overview bullets; empty when there is nothing to show
    public let overview: [String]
    /// "What you can do" (OD5), once at the top (owner, 2026-11-24: the same tips on every app added nothing);
    /// empty unless at least one app contacted an advertising or tracking company
    public let tips: [String]
    public let rows: [SummaryRow]
    /// 5.2: the "Show data amounts" switch is offered only when there is captured data
    public let hasCaptures: Bool
    public static var dataAmountsToggle: String { Wording.bundled.text("toggle.dataAmounts") }
    /// `SummaryText.noProcessSentence(combined.noProcess.connections)`
    public let noProcess: String?
    public var isEmpty: Bool { rows.isEmpty }
    public static var emptyText: String { Wording.bundled.text("empty.state") }
    public static var howToReadHeading: String { Wording.bundled.text("howto.heading") }
    public static var possibleExplanation: String { SummaryText.possibleExplanation }
    public static var appleAppsBreakdownHeading: String { SummaryText.appleAppsBreakdownHeading }
    public static var trackingHeading: String { Wording.bundled.text("detail.heading.tracking") }
    public static var otherHeading: String { Wording.bundled.text("detail.heading.other") }
    public static var untracedHeading: String { Wording.bundled.text("detail.heading.untraced") }
    public static var tracedHeading: String { Wording.bundled.text("detail.heading.traced") }
    public static var tipsHeading: String { Wording.bundled.text("tips.heading") }

    public init(overview: [String], tips: [String] = [], rows: [SummaryRow], hasCaptures: Bool = false, noProcess: String?) {
        self.overview = overview
        self.tips = tips
        self.hasCaptures = hasCaptures
        self.rows = rows
        self.noProcess = noProcess
    }
}

public enum SummaryScreenBuilder {
    private static var w: Wording { Wording.bundled }

    public static func build(_ combined: CombinedSummary, timeZone: TimeZone = .current, now: Date = Date()) -> SummaryScreen {
        var overview: [String] = []
        if !combined.cards.isEmpty {
            overview.append(w.text(plural("count.app", combined.apps), ["count": String(combined.apps)]))
            let companies = w.text(plural("count.company", combined.companies), ["count": String(combined.companies)])
            overview.append(w.text(combined.adTrack == 0 ? "overview.bullet.companies.none" : plural("overview.bullet.companies", combined.adTrack),
                                   ["companies": companies, "count": String(combined.adTrack)]))
            overview.append(w.text(combined.untraced == 0 ? "overview.bullet.untraced.none" : plural("overview.bullet.untraced", combined.untraced),
                                   ["count": String(combined.untraced)]))
            var dates: [String] = []
            if let s = combined.captureStart, let e = combined.captureEnd {
                dates.append(w.text("overview.bullet.captures", ["period": SummaryText.period(from: s, to: e, timeZone: timeZone, now: now)]))
            }
            if let s = combined.reportStart, let e = combined.reportEnd {
                dates.append(w.text("overview.bullet.report", ["period": SummaryText.period(from: s, to: e, timeZone: timeZone, now: now)]))
            }
            if !dates.isEmpty { overview.append(dates.joined(separator: " · ")) }
        }
        let apps = ordered(combined.cards.filter { $0.kind == .app })
        let rest = combined.cards.filter { $0.kind == .appleApps } + combined.cards.filter { $0.kind == .system }
        let rows = (apps + rest).map { row($0) }
        // OD5 tips once at the top, when any single app (an Apple app inside the drop-down included) counts at
        // least one advertising or tracking company
        let anyTracking = combined.cards.contains { card in
            (card.kind == .app && !Rating.countedCompanies(card.companies).isEmpty)
                || card.members.contains { !Rating.countedCompanies($0.companies).isEmpty }
        }
        let tips = anyTracking ? [w.text("tip.backgroundRefresh"), w.text("tip.tracking")] : []
        return SummaryScreen(overview: overview, tips: tips, rows: rows, hasCaptures: combined.captureStart != nil,
                             noProcess: SummaryText.noProcessSentence(combined.noProcess.connections))
    }

    /// most advertising or tracking companies first, then by name (non-localized), then key
    private static func ordered(_ cards: [AppCard]) -> [AppCard] {
        cards.sorted { a, b in
            if a.adTrackNames.count != b.adTrackNames.count { return a.adTrackNames.count > b.adTrackNames.count }
            let order = a.name.compare(b.name, options: [.caseInsensitive, .numeric])
            return order == .orderedSame ? a.key < b.key : order == .orderedAscending
        }
    }

    private static func plural(_ base: String, _ n: Int) -> String { base + (n == 1 ? ".one" : ".other") }

    static func subtitle(_ card: AppCard) -> String {
        let count = card.companies.count
        if count > 0 {
            let adTrack = card.adTrackNames.count
            let tracking = adTrack == 0 ? w.text("list.tracking.none") : w.text(plural("list.tracking", adTrack), ["count": String(adTrack)])
            return w.text("list.row", [
                "companies": w.text(plural("count.company", count), ["count": String(count)]), "tracking": tracking,
            ])
        }
        let untraced = card.untracedDestinations
        if untraced > 0 { return w.text(plural("list.untraced", untraced), ["count": String(untraced)]) }
        return w.text("list.nothing")
    }

    /// 5.2: a company's share of the app's whole captured traffic (the base of the "Captures: N% of traffic"
    /// bullet), so the shares never add up to more than the traced part. one decimal, rounded down; a share under 1%
    /// says so, also at 0 bytes for a company seen in captures. nil only for a company not seen in captures
    public static func dataShare(bytes: Int, of total: Int, inCaptures: Bool = true) -> String? {
        guard inCaptures, total > 0 else { return nil }
        if bytes * 100 < total { return w.text("data.share.small") }
        return w.text("data.share", ["percent": SummaryText.percentText(bytes, of: total) ?? "0.0"])
    }

    /// the "Not traced" bullet: the count, and the types the AdGuard list knows (never more than the count)
    static func untracedBullet(_ card: AppCard) -> String {
        let n = card.untracedDestinations
        guard n > 0 else { return w.text("detail.untraced.none") }
        let destinations = w.text(plural("detail.untraced", n), ["count": String(n)])
        var left = n, kinds: [String] = []
        for category in CompanyCategory.allCases where category != .unclassified {
            guard let raw = card.typeKnown[category], raw > 0, left > 0 else { continue }
            let k = min(raw, left)
            left -= k
            kinds.append(w.text(plural("detail.untraced.kind", k), ["count": String(k), "kind": w.text(plural("kind.\(category.rawValue)", k))]))
        }
        return kinds.isEmpty ? destinations : w.text("detail.untraced.withkinds", ["destinations": destinations, "kinds": kinds.joined(separator: ", ")])
    }

    private static func row(_ card: AppCard) -> SummaryRow {
        var traced: [TracedLine] = []
        if let cap = card.capture, cap.coverage.denominator > 0 {
            let all = cap.coverage.numerator >= cap.coverage.denominator
            let text = all ? w.text("detail.traced.captures.all")
                : w.text("detail.traced.captures", ["percent": SummaryText.percentText(cap.coverage.numerator, of: cap.coverage.denominator) ?? "0.0"])
            traced.append(TracedLine(text: text, detail: SummaryText.captureRestDetail(coverage: cap.coverage, reason: SummaryText.mainRestReason(summary: cap))))
        }
        if let rep = card.report, rep.coverage.denominator > 0 {
            let total = rep.coverage.denominator, identified = min(rep.coverage.numerator, total)
            let text = total == 1 ? w.text("detail.traced.report.single", ["identified": String(identified)])
                : w.text("detail.traced.report", ["identified": String(identified), "total": String(total)])
            traced.append(TracedLine(text: text, detail: w.text("detail.traced.report.help")))
        }
        let total = card.capture?.coverage.denominator ?? 0
        let lines = card.companies.map { c in
            (c.isAdvertisingOrTracking, CompanyLine(
                parent: c.parent,
                text: SummaryText.companyRow(parent: c.parent, categories: c.categories, isOwnCompany: c.relation == .sameCompanyAsApp),
                brands: c.brands.compactMap { SummaryText.brandText(brand: $0, parent: c.parent) },
                seenIn: SummaryText.seenIn(captures: c.inCaptures, report: c.inReport),
                dataShare: dataShare(bytes: c.captureTraffic.bytes, of: total, inCaptures: c.inCaptures)))
        }
        let description: String? =
            card.kind == .system ? SummaryText.systemDescription : card.kind == .appleApps ? SummaryText.appleAppsDescription : nil
        let rating = Rating.rate(card: card)
        return SummaryRow(
            id: card.key, kind: card.kind, title: card.name, subtitle: rating.map(Rating.text) ?? subtitle(card),
            rating: rating, description: description,
            trackingCompanies: lines.filter(\.0).map(\.1), otherCompanies: lines.filter { !$0.0 }.map(\.1),
            untraced: untracedBullet(card), traced: traced,
            possible: card.possibleCompanies.isEmpty ? nil : w.text("detail.possible", ["names": card.possibleCompanies.joined(separator: ", ")]),
            children: ordered(card.members).map { row($0) })
    }
}
