import Attribution
import Companies
import Foundation

/// why the rest of an app's captured traffic was not identified, in tie-break order
public enum CaptureRestReason: CaseIterable, Sendable {
    case hiddenByApp, startedBeforeCapture, noName, unknownDestination, possibleOnly

    public var text: String {
        switch self {
        case .hiddenByApp: "was hidden by the app"
        case .startedBeforeCapture: "started before the capture"
        case .noName: "had no name to identify"
        case .unknownDestination: "went to destinations no list knows"
        case .possibleOnly: "has only a possible name"
        }
    }
}

/// the frozen summary sentences. pure text: every function takes the numbers it needs. no speaker ever appears
public enum SummaryText {
    // MARK: helpers

    public static func percent(_ numerator: Int, of denominator: Int) -> Int? {
        guard denominator > 0 else { return nil }
        return numerator * 100 / denominator
    }

    public static func period(from start: Date, to end: Date, timeZone: TimeZone) -> String {
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
        if m1 != m2 { return "\(d1) \(m1) to \(d2) \(m2)" }
        if d1 != d2 { return "\(d1) to \(d2) \(m1)" }
        return "\(d1) \(m1)"
    }

    // MARK: overview

    public static func overview(
        period: String, hasCaptures: Bool, hasReport: Bool, apps: Int, companies: Int, adTrack: Int, notIdentified: Int
    ) -> String {
        precondition(hasCaptures || hasReport, "an overview needs at least one source")
        let source: String
        if hasCaptures && hasReport {
            source = "In your captures and App Privacy Report"
        } else if hasCaptures {
            source = "In your captures"
        } else {
            source = "In your App Privacy Report"
        }
        let appsPart = apps == 1 ? "1 app" : "\(apps) apps"
        let companiesPart = companies == 1 ? "1 company" : "\(companies) companies"
        let notIdentifiedPart: String
        switch notIdentified {
        case 0: notIdentifiedPart = "Every destination was identified."
        case 1: notIdentifiedPart = "1 destination couldn't be identified."
        default: notIdentifiedPart = "\(notIdentified) destinations couldn't be identified."
        }
        return "\(source) (\(period)): \(appsPart) contacted \(companiesPart). \(adTrackSentence(adTrack)) \(notIdentifiedPart)"
    }

    // MARK: each app

    public static func companiesSentence(app: String, named: Int) -> String {
        switch named {
        case 0: "No companies were identified."
        case 1: "\(app) contacted 1 company."
        default: "\(app) contacted \(named) companies."
        }
    }

    public static func adTrackSentence(_ n: Int) -> String {
        switch n {
        case 0: "No advertising or tracking companies found."
        case 1: "1 does advertising or tracking."
        default: "\(n) do advertising or tracking."
        }
    }

    public static func notIdentifiedSentence(_ n: Int) -> String {
        switch n {
        case 0: "Every destination was identified."
        case 1: "1 more destination couldn't be identified."
        default: "\(n) more destinations couldn't be identified."
        }
    }

    public static func unnamedSentences(_ counts: [CompanyCategory: Int]) -> [String] {
        CompanyCategory.allCases.compactMap { category in
            guard let n = counts[category], n > 0 else { return nil }
            let words: (String, String)
            switch category {
            case .advertising: words = ("advertising service", "advertising services")
            case .analytics: words = ("analytics service", "analytics services")
            case .social: words = ("social media service", "social media services")
            case .contentDelivery: words = ("content delivery service", "content delivery services")
            case .cloudService: words = ("cloud or app service", "cloud or app services")
            case .onlineService: words = ("online service", "online services")
            case .appleSystem: words = ("Apple system service", "Apple system services")
            case .unclassified: return nil
            }
            return "Plus \(n) \(n == 1 ? words.0 : words.1) that couldn't be named."
        }
    }

    public static func headline(
        app: String, named: Int, adTrack: Int, notIdentified: Int, unnamed: [CompanyCategory: Int]
    ) -> [String] {
        [companiesSentence(app: app, named: named), adTrackSentence(adTrack), notIdentifiedSentence(notIdentified)]
            + unnamedSentences(unnamed)
    }

    // MARK: company rows

    public static func companyRow(parent: String, categories: [CompanyCategory], isOwnCompany: Bool) -> String {
        if isOwnCompany { return "\(parent) · the app's own company" }
        let labels = categories.filter { $0 != .unclassified }.map(\.label)
        return labels.isEmpty ? parent : "\(parent) · \(labels.joined(separator: ", "))"
    }

    public static func brandText(brand: String, parent: String) -> String? {
        brand == parent ? nil : "\(brand) (owned by \(parent))"
    }

    public static func seenIn(captures: Bool, report: Bool) -> String {
        precondition(captures || report, "seenIn needs at least one source")
        if captures && report { return "Seen in both" }
        return captures ? "Seen in captures" : "Seen in your App Privacy Report"
    }

    // MARK: possible

    public static let possibleHeading = "Possible (not counted)"
    public static let possibleExplanation = "A lookup for this name was seen, but the server is shared, so it may be a different service."

    // MARK: how much was identified

    public static func mainRestReason(summary: CaptureAppSummary) -> CaptureRestReason? {
        let bytes: [(CaptureRestReason, Int)] = [
            (.hiddenByApp, summary.unseen[.echHidden]?.bytes ?? 0),
            (.startedBeforeCapture, summary.unseen[.startedBeforeCapture]?.bytes ?? 0),
            (.noName, (summary.unseen[.noHandshakeUDP]?.bytes ?? 0) + (summary.unseen[.noDNSMatch]?.bytes ?? 0)),
            (.unknownDestination, summary.notIdentified.bytes),
            (.possibleOnly, summary.hinted.bytes),
        ]
        var best: (CaptureRestReason, Int)?
        for entry in bytes where entry.1 > 0 {
            if best == nil || entry.1 > best!.1 { best = entry }
        }
        return best?.0
    }

    public static func captureCoverage(period: String, identifiedBytes: Int, totalBytes: Int, mainReason: CaptureRestReason?) -> String? {
        guard let p = percent(identifiedBytes, of: totalBytes) else { return nil }
        var text = "Captures (\(period)): \(p)% of this app's traffic was identified."
        if p < 100, let mainReason { text += " Most of the rest \(mainReason.text)." }
        return text
    }

    public static func reportCoverage(period: String, identified: Int, total: Int) -> String? {
        guard total > 0 else { return nil }
        let middle = total == 1 ? "1 of 1 destination was identified." : "\(identified) of \(total) destinations were identified."
        return "App Privacy Report (\(period)): \(middle) The report doesn't show how much data was sent."
    }

    // MARK: rating lines

    public static let ratingThreshold = 70

    public static func captureRating(percent p: Int) -> String {
        if p >= ratingThreshold { return "Rated on \(p)% identified traffic." }
        return "Not enough data to rate: \(p)% of this app's traffic was identified. A rating needs at least \(ratingThreshold)%."
    }

    public static func reportRating(identified: Int, total: Int) -> String? {
        guard let p = percent(identified, of: total) else { return nil }
        if p >= ratingThreshold { return "Rated on \(identified) of \(total) identified destinations (\(p)%)." }
        return "Not enough data to rate: \(identified) of \(total) destinations (\(p)%) were identified. A rating needs at least \(ratingThreshold)%."
    }

    // MARK: special entries

    public static let systemDescription = "iOS background services. Apple servers are its own company."
    public static let appleAppsDescription = "Apple's own apps, together."
    public static let appleAppsBreakdownHeading = "Each Apple app on its own"

    public static func noProcessSentence(_ n: Int) -> String? {
        switch n {
        case 0: nil
        case 1: "1 connection had no app information from iOS."
        default: "\(n) connections had no app information from iOS."
        }
    }

    // MARK: data amounts

    public static func dataAmountSentence(captureDay: String, company: String) -> String {
        "In the capture from \(captureDay), most of the data went to \(company)."
    }
}
