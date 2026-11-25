import Companies
import Foundation

// read time only. turns the combined summary into the first screen: a list of apps, each row openable.
// every text comes from `SummaryText`, `Glossary` or `Wording`; nothing here is worded in code.

/// one company line inside an opened row
public struct CompanyLine: Sendable, Equatable, Identifiable {
    public var id: String { parent }
    public let parent: String
    /// `SummaryText.companyRow(parent:categories:isOwnCompany:)` (own company = relation .sameCompanyAsApp)
    public let text: String
    /// `SummaryText.brandText(brand:parent:)` for every brand that differs from the parent, in brand order
    public let brands: [String]
    /// `SummaryText.seenIn(captures:report:)`
    public let seenIn: String

    public init(parent: String, text: String, brands: [String], seenIn: String) {
        self.parent = parent
        self.text = text
        self.brands = brands
        self.seenIn = seenIn
    }
}

/// one row of the list; opening it shows everything below `subtitle`
public struct SummaryRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: CardKind
    public let title: String
    /// the closed row's text
    public let subtitle: String
    /// `SummaryText.systemDescription` for iOS system, `appleAppsDescription` for Apple apps, else nil
    public let description: String?
    public let sentences: [String]
    /// `captureCoverage` for the card's capture summary, nil without captures
    public let captureLine: String?
    /// the (i) icon text; nil when none
    public let captureDetail: String?
    /// `reportCoverage`, nil without a report entry
    public let reportLine: String?
    public let companies: [CompanyLine]
    /// the card's possible names; empty when none. the heading and explanation are shown only when non-empty
    public let possibleNames: [String]
    /// Apple apps only: one row per Apple app, ordered like the list
    public let children: [SummaryRow]

    public init(
        id: String, kind: CardKind, title: String, subtitle: String, description: String?, sentences: [String],
        captureLine: String?, captureDetail: String?, reportLine: String?, companies: [CompanyLine],
        possibleNames: [String], children: [SummaryRow]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.sentences = sentences
        self.captureLine = captureLine
        self.captureDetail = captureDetail
        self.reportLine = reportLine
        self.companies = companies
        self.possibleNames = possibleNames
        self.children = children
    }
}

public struct SummaryScreen: Sendable, Equatable {
    /// `SummaryText.overview(...)`; empty when there is nothing to show
    public let overview: [String]
    public let rows: [SummaryRow]
    /// `SummaryText.noProcessSentence(combined.noProcess.connections)`
    public let noProcess: String?
    public var isEmpty: Bool { rows.isEmpty }
    public static var emptyText: String { Wording.bundled.text("empty.state") }
    public static var howToReadHeading: String { Wording.bundled.text("howto.heading") }
    public static var possibleHeading: String { SummaryText.possibleHeading }
    public static var possibleExplanation: String { SummaryText.possibleExplanation }
    public static var appleAppsBreakdownHeading: String { SummaryText.appleAppsBreakdownHeading }

    public init(overview: [String], rows: [SummaryRow], noProcess: String?) {
        self.overview = overview
        self.rows = rows
        self.noProcess = noProcess
    }
}

public enum SummaryScreenBuilder {
    private static var w: Wording { Wording.bundled }

    public static func build(_ combined: CombinedSummary, timeZone: TimeZone = .current, now: Date = Date()) -> SummaryScreen {
        var overview: [String] = []
        let starts = [combined.captureStart, combined.reportStart].compactMap { $0 }
        let ends = [combined.captureEnd, combined.reportEnd].compactMap { $0 }
        if !combined.cards.isEmpty, let start = starts.min(), let end = ends.max() {
            overview = SummaryText.overview(
                period: SummaryText.period(from: start, to: end, timeZone: timeZone, now: now),
                hasCaptures: combined.captureStart != nil, hasReport: combined.reportStart != nil,
                apps: combined.apps, companies: combined.companies, adTrack: combined.adTrack, untraced: combined.untraced)
        }
        let apps = ordered(combined.cards.filter { $0.kind == .app })
        let rest = combined.cards.filter { $0.kind == .appleApps } + combined.cards.filter { $0.kind == .system }
        let rows = (apps + rest).map { row($0, combined: combined, timeZone: timeZone, now: now) }
        return SummaryScreen(overview: overview, rows: rows, noProcess: SummaryText.noProcessSentence(combined.noProcess.connections))
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

    private static func row(_ card: AppCard, combined: CombinedSummary, timeZone: TimeZone, now: Date) -> SummaryRow {
        var captureLine: String?, captureDetail: String?, reportLine: String?
        if let cap = card.capture {
            captureLine = SummaryText.captureCoverage(
                period: SummaryText.period(from: cap.windowStart, to: cap.windowEnd, timeZone: timeZone, now: now), coverage: cap.coverage)
            captureDetail = SummaryText.captureRestDetail(coverage: cap.coverage, reason: SummaryText.mainRestReason(summary: cap))
        }
        if let rep = card.report, let start = rep.firstSeen ?? combined.reportStart, let end = rep.lastSeen ?? combined.reportEnd {
            reportLine = SummaryText.reportCoverage(
                period: SummaryText.period(from: start, to: end, timeZone: timeZone, now: now),
                identified: rep.coverage.numerator, total: rep.coverage.denominator)
        }
        let lines = card.companies.map { c in
            CompanyLine(
                parent: c.parent,
                text: SummaryText.companyRow(parent: c.parent, categories: c.categories, isOwnCompany: c.relation == .sameCompanyAsApp),
                brands: c.brands.compactMap { SummaryText.brandText(brand: $0, parent: c.parent) },
                seenIn: SummaryText.seenIn(captures: c.inCaptures, report: c.inReport))
        }
        let description: String? =
            card.kind == .system ? SummaryText.systemDescription : card.kind == .appleApps ? SummaryText.appleAppsDescription : nil
        return SummaryRow(
            id: card.key, kind: card.kind, title: card.name, subtitle: subtitle(card), description: description,
            sentences: SummaryText.appSentences(
                app: card.name, companies: card.companyNames, adTrack: card.adTrackNames,
                untraced: card.untracedDestinations, typeKnown: card.typeKnown),
            captureLine: captureLine, captureDetail: captureDetail, reportLine: reportLine, companies: lines,
            possibleNames: card.possibleCompanies,
            children: ordered(card.members).map { row($0, combined: combined, timeZone: timeZone, now: now) })
    }
}
