import Attribution
import Companies
import Foundation
import Summary
import Testing
import TestSupport

// the sentences come from Resources/wording.toml (owner, 2026-11-24). these tests pin the approved strings,
// check the file against the code's schema, and lint every sentence the code can produce

private func containsWord(_ text: String, _ phrase: String) -> Bool {
    let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
    let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

private let period = "14 to 21 November"
private let allCompanyLists: [[String]] = [[], ["AdCo Holdings"], ["Zappy Inc", "AdCo Holdings"],
    ["Zappy Inc", "AdCo Holdings", "CdnCo"], ["Zappy Inc", "AdCo Holdings", "CdnCo", "MetricCo", "Quill Corp"]]

/// every sentence the code can produce over a grid of inputs, plus every fixed text
private func sentences() -> [String] {
    var out: [String] = []
    for (c, k) in [(true, true), (true, false), (false, true)] {
        for n in [0, 1, 2, 31] {
            out += SummaryText.overview(period: period, hasCaptures: c, hasReport: k, apps: n, companies: n, adTrack: n, untraced: n)
        }
    }
    for companies in allCompanyLists {
        for adTrackCount in 0...min(companies.count, 4) {
            for untraced in [0, 1, 3] {
                for category in CompanyCategory.allCases {
                    for k in [0, 1, 2] {
                        out += SummaryText.appSentences(app: "Zappy", companies: companies, adTrack: Array(companies.prefix(adTrackCount)),
                                                        untraced: untraced, typeKnown: [category: k])
                    }
                }
            }
        }
    }
    for (n, d) in [(0, 100), (55, 100), (77, 100), (100, 100), (0, 0)] {
        if let s = SummaryText.captureCoverage(period: period, coverage: CoverageRatio(numerator: n, denominator: d)) { out.append(s) }
        for reason in CaptureRestReason.allCases {
            if let s = SummaryText.captureRestDetail(coverage: CoverageRatio(numerator: n, denominator: d), reason: reason) { out.append(s) }
        }
    }
    for (i, t) in [(0, 1), (1, 1), (6, 9), (7, 10), (0, 0)] {
        if let s = SummaryText.reportCoverage(period: period, identified: i, total: t) { out.append(s) }
        if let s = SummaryText.reportRating(identified: i, total: t) { out.append(s) }
    }
    for p in [0, 55, 69, 70, 82, 100] { out.append(SummaryText.captureRating(percent: p)) }
    for n in [0, 1, 2] { if let s = SummaryText.noProcessSentence(n) { out.append(s) } }
    out.append(SummaryText.dataAmountSentence(captureDay: "14 November", company: "Alphabet"))
    out += [SummaryText.possibleExplanation, SummaryText.systemDescription, SummaryText.appleAppsDescription]
    out += Glossary.terms.map(\.text) + Glossary.howToRead
    return out
}

/// labels: not sentences, so they need no full stop
private func labels() -> [String] {
    var out = [SummaryText.possibleHeading, SummaryText.appleAppsBreakdownHeading] + Glossary.terms.map(\.term)
    out.append(SummaryText.companyRow(parent: "AdCo Holdings", categories: [.advertising], isOwnCompany: false))
    out.append(SummaryText.companyRow(parent: "Zappy Inc", categories: [], isOwnCompany: true))
    out.append(SummaryText.seenIn(captures: true, report: true))
    out.append(SummaryText.brandText(brand: "YouTube", parent: "Alphabet") ?? "")
    return out
}

@Test func wordingFileLoadsAndMatchesTheSchema() throws {
    let file = try Wording.loadBundled()
    let keys = Set(file.entries.keys), wanted = Set(SummaryText.schema.keys)
    #expect(keys.subtracting(wanted).isEmpty, "keys in the file the code never uses: \(keys.subtracting(wanted).sorted())")
    #expect(wanted.subtracting(keys).isEmpty, "keys the code needs that the file lacks: \(wanted.subtracting(keys).sorted())")
    for (key, text) in file.entries {
        let extra = Wording.placeholders(in: text).subtracting(SummaryText.schema[key] ?? [])
        #expect(extra.isEmpty, "\(key) has placeholders the code never fills: \(extra.sorted())")
    }
    #expect(!Wording.bundled.entries.isEmpty)
}

@Test func wordingParserIsStrict() throws {
    let ok = try Wording(parsing: "# comment\n\n a.b = \"say \\\"hi\\\" \\\\ there\" \n")
    #expect(ok.entries == ["a.b": "say \"hi\" \\ there"])
    #expect(throws: WordingError.badLine(line: 1)) { try Wording(parsing: "a.b \"x\"") }
    #expect(throws: WordingError.badLine(line: 1)) { try Wording(parsing: "a.b = x") }
    #expect(throws: WordingError.badLine(line: 1)) { try Wording(parsing: "a.b = \"x\"y\"") }
    #expect(throws: WordingError.badEscape(line: 1)) { try Wording(parsing: "a.b = \"x\\n\"") }
    #expect(throws: WordingError.duplicateKey(line: 2)) { try Wording(parsing: "a = \"x\"\na = \"y\"") }
    #expect(ok.text("missing") == "[missing]")
    #expect(Wording.placeholders(in: "{a} and {b} or {a}") == ["a", "b"])
}

@Test func wordingAppSentencesExact() {
    #expect(SummaryText.appSentences(app: "Zappy", companies: ["Zappy Inc", "AdCo Holdings", "CdnCo"], adTrack: ["AdCo Holdings"],
                                     untraced: 3, typeKnown: [.advertising: 2]) == [
        "Zappy contacted Zappy Inc, AdCo Holdings and CdnCo.",
        "Of these, AdCo Holdings does advertising or tracking.",
        "It also contacted 3 destinations that could not be traced to any company.",
        "Among them, 2 are known advertising services whose owner is unknown.",
    ])
    #expect(SummaryText.appSentences(app: "Zappy", companies: ["Zappy Inc", "AdCo Holdings", "a", "b", "c", "d", "e", "f"],
                                     adTrack: ["AdCo Holdings", "a", "b", "c"], untraced: 1, typeKnown: [.analytics: 1]) == [
        "Zappy contacted 8 companies, including Zappy Inc and AdCo Holdings.",
        "Of these, 4 do advertising or tracking.",
        "It also contacted 1 destination that could not be traced to any company.",
        "It is a known analytics service whose owner is unknown.",
    ])
    #expect(SummaryText.appSentences(app: "Zappy", companies: ["AdCo Holdings"], adTrack: ["AdCo Holdings"], untraced: 0, typeKnown: [:]) == [
        "Zappy contacted AdCo Holdings.", "AdCo Holdings does advertising or tracking.", "Every destination was traced to a company.",
    ])
    #expect(SummaryText.appSentences(app: "Zappy", companies: ["Zappy Inc", "CdnCo"], adTrack: [], untraced: 2, typeKnown: [.social: 1]) == [
        "Zappy contacted Zappy Inc and CdnCo.", "No advertising or tracking companies were found.",
        "It also contacted 2 destinations that could not be traced to any company.",
        "Among them is a known social media service whose owner is unknown.",
    ])
    #expect(SummaryText.appSentences(app: "Zappy", companies: ["A", "B"], adTrack: ["A", "B"], untraced: 0, typeKnown: [:])[1]
            == "Of these, A and B do advertising or tracking.")
    #expect(SummaryText.appSentences(app: "Zappy", companies: [], adTrack: [], untraced: 3, typeKnown: [:])
            == ["Zappy contacted 3 destinations, but none could be traced to a company."])
    #expect(SummaryText.appSentences(app: "Zappy", companies: [], adTrack: [], untraced: 1, typeKnown: [.analytics: 1]) == [
        "Zappy contacted 1 destination, but it could not be traced to a company.", "It is a known analytics service whose owner is unknown.",
    ])
    #expect(SummaryText.appSentences(app: "Zappy", companies: [], adTrack: [], untraced: 0, typeKnown: [:]) == [])
    // a category without a type name never makes a sentence
    #expect(SummaryText.appSentences(app: "Zappy", companies: [], adTrack: [], untraced: 2, typeKnown: [.unclassified: 2]).count == 1)
}

@Test func wordingOtherStringsExact() {
    #expect(SummaryText.overview(period: period, hasCaptures: true, hasReport: true, apps: 12, companies: 31, adTrack: 9, untraced: 40) == [
        "In your captures and App Privacy Report (14 to 21 November), 12 apps contacted 31 companies, 9 of which do advertising or tracking.",
        "Another 40 destinations could not be traced to any company.",
    ])
    #expect(SummaryText.overview(period: "14 November", hasCaptures: true, hasReport: false, apps: 1, companies: 1, adTrack: 0, untraced: 0) == [
        "In your captures (14 November), 1 app contacted 1 company. No advertising or tracking companies were found.",
        "Every destination was traced to a company.",
    ])
    #expect(SummaryText.overview(period: period, hasCaptures: false, hasReport: true, apps: 2, companies: 3, adTrack: 1, untraced: 1) == [
        "In your App Privacy Report (14 to 21 November), 2 apps contacted 3 companies, 1 of which does advertising or tracking.",
        "Another destination could not be traced to any company.",
    ])
    #expect(SummaryText.companyRow(parent: "AdCo Holdings", categories: [.advertising, .analytics], isOwnCompany: false) == "AdCo Holdings · Advertising, Analytics")
    #expect(SummaryText.companyRow(parent: "Alphabet", categories: [.advertising], isOwnCompany: true) == "Alphabet · the app's own company · Advertising")
    #expect(SummaryText.companyRow(parent: "Zappy Inc", categories: [.unclassified], isOwnCompany: true) == "Zappy Inc · the app's own company")
    #expect(SummaryText.companyRow(parent: "Wexford", categories: [], isOwnCompany: false) == "Wexford")
    #expect(SummaryText.brandText(brand: "YouTube", parent: "Alphabet") == "YouTube (owned by Alphabet)")
    #expect(SummaryText.brandText(brand: "Alphabet", parent: "Alphabet") == nil)
    #expect(SummaryText.seenIn(captures: false, report: true) == "Seen in your App Privacy Report")
    #expect(SummaryText.captureCoverage(period: period, coverage: CoverageRatio(numerator: 77, denominator: 100))
            == "Captures (14 to 21 November): 77% of this app's traffic could be traced to a company.")
    #expect(SummaryText.captureCoverage(period: period, coverage: CoverageRatio(numerator: 5, denominator: 5))
            == "Captures (14 to 21 November): All of this app's traffic could be traced to a company.")
    #expect(SummaryText.captureCoverage(period: period, coverage: CoverageRatio(numerator: 0, denominator: 0)) == nil)
    #expect(SummaryText.captureRestDetail(coverage: CoverageRatio(numerator: 77, denominator: 100), reason: .hiddenByApp)
            == "Of the remaining 23%, the largest share went to destinations whose names the app kept hidden.")
    #expect(SummaryText.captureRestDetail(coverage: CoverageRatio(numerator: 5, denominator: 5), reason: .hiddenByApp) == nil)
    #expect(SummaryText.reportCoverage(period: "18 to 21 November", identified: 6, total: 9)
            == "App Privacy Report (18 to 21 November): 6 of this app's 9 destinations could be traced to a company. The report doesn't show how much data was sent.")
    // review of PR #9: the single case follows the real count
    #expect(SummaryText.reportCoverage(period: period, identified: 0, total: 1)
            == "App Privacy Report (14 to 21 November): this app's only destination could not be traced to a company. The report doesn't show how much data was sent.")
    #expect(SummaryText.reportCoverage(period: period, identified: 1, total: 1)?.contains("only destination could be traced") == true)
    #expect(SummaryText.captureRating(percent: 82) == "Rated on 82% traced traffic.")
    #expect(SummaryText.captureRating(percent: 55) == "Not enough data to rate: 55% of this app's traffic could be traced to a company. A rating needs at least 70%.")
    #expect(SummaryText.reportRating(identified: 6, total: 9) == "Not enough data to rate: 6 of 9 destinations (66%) could be traced to a company. A rating needs at least 70%.")
    #expect(SummaryText.reportRating(identified: 7, total: 10) == "Rated on 7 of 10 traced destinations (70%).")
    #expect(SummaryText.reportRating(identified: 1, total: 1) == "Rated on 1 of 1 traced destination (100%).")
    #expect(SummaryText.reportRating(identified: 0, total: 1) == "Not enough data to rate: 0 of 1 destination (0%) could be traced to a company. A rating needs at least 70%.")
    #expect(SummaryText.reportRating(identified: 0, total: 0) == nil)
    #expect(SummaryText.dataAmountSentence(captureDay: "14 November", company: "Alphabet")
            == "In the capture from 14 November, the largest share of the data went to Alphabet.")
    #expect(SummaryText.noProcessSentence(0) == nil)
    #expect(SummaryText.noProcessSentence(1) == "iOS gave no app information for 1 connection.")
    #expect(SummaryText.noProcessSentence(4) == "iOS gave no app information for 4 connections.")
    #expect(SummaryText.systemDescription == "iOS background services. Apple servers count as its own company.")
    #expect(SummaryText.possibleHeading == "Possible (not counted)")
}

@Test func wordingLintEverySentence() {
    let all = sentences(), shown = all + labels()
    #expect(all.count > 500)
    for s in shown {
        for phrase in Glossary.bannedPhrases { #expect(!containsWord(s, phrase), "banned \"\(phrase)\": \(s)") }
        for speaker in Glossary.bannedSpeakers { #expect(!containsWord(s, speaker), "speaker \"\(speaker)\": \(s)") }
        #expect(!s.contains("{") && !s.contains("}"), "unfilled placeholder: \(s)")
        #expect(!(s.hasPrefix("[") && s.hasSuffix("]")), "missing key: \(s)")
        #expect(!s.isEmpty)
    }
    for s in all {
        #expect(s.hasSuffix("."), "no full stop: \(s)")
        #expect(!(s.first?.isNumber ?? false), "starts with a number: \(s)")
    }
}

@Test func wordingCompaniesAndUntracedStayTogether() {
    for companies in allCompanyLists where !companies.isEmpty {
        for untraced in [0, 1, 2] {
            let s = SummaryText.appSentences(app: "Zappy", companies: companies, adTrack: [], untraced: untraced, typeKnown: [:])
            #expect(s.count == 3)
            #expect(s[2].contains("traced"), "the third sentence is always the untraced part: \(s)")
        }
    }
}

@Test func wordingPossibleNeverInCountSentences() {
    var counts: [String] = []
    for companies in allCompanyLists {
        counts += SummaryText.appSentences(app: "Zappy", companies: companies, adTrack: companies, untraced: 2, typeKnown: [.advertising: 1])
    }
    counts += SummaryText.overview(period: period, hasCaptures: true, hasReport: true, apps: 2, companies: 3, adTrack: 1, untraced: 4)
    for s in counts { #expect(!s.localizedCaseInsensitiveContains("possible"), "\(s)") }
}

@Test func wordingPercentRoundsDownAndClamps() {
    #expect(SummaryText.percent(2, of: 3) == 66)
    #expect(SummaryText.percent(1, of: 0) == nil)
    #expect(SummaryText.percent(0, of: 5) == 0)
    #expect(SummaryText.percent(7, of: 5) == 100)
    #expect(SummaryText.reportCoverage(period: period, identified: 12, total: 9)?.contains("9 of this app's 9") == true)
}

@Test func wordingRatingThreshold() {
    #expect(SummaryText.captureRating(percent: 69).hasPrefix("Not enough data to rate"))
    #expect(SummaryText.captureRating(percent: 70).hasPrefix("Rated on"))
    #expect(SummaryText.reportRating(identified: 7, total: 10)?.hasPrefix("Rated on") == true)
}

@Test func wordingPeriods() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    func day(_ y: Int, _ m: Int, _ d: Int) throws -> Date { try #require(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))) }
    #expect(SummaryText.period(from: try day(2026, 11, 14), to: try day(2026, 11, 14), timeZone: utc) == "14 November")
    #expect(SummaryText.period(from: try day(2026, 11, 14), to: try day(2026, 11, 21), timeZone: utc) == "14 to 21 November")
    #expect(SummaryText.period(from: try day(2026, 11, 28), to: try day(2026, 12, 3), timeZone: utc) == "28 November to 3 December")
    #expect(SummaryText.period(from: try day(2025, 12, 28), to: try day(2026, 1, 3), timeZone: utc) == "28 December 2025 to 3 January 2026")
}

@Test func wordingGlossaryHasSixTerms() {
    #expect(Glossary.terms.map(\.term) == ["Company", "Advertising or tracking", "The app's own company", "Apple system and Apple apps", "Not identified", "Possible"])
    #expect(Glossary.howToRead.count == 3)
    #expect(Glossary.terms[4].text == "A destination that could not be traced to any company. It stays in the count, so the numbers never look more complete than they are.")
}

@Test func wordingMainRestReasonUsesTheLargestCause() throws {
    // the 3.1 scenario's Zappy: hidden 700, started before 600, not identified 600, hinted 400
    let curated = try CuratedList(parsing: SummaryCorpus.curatedTSV)
    let trackers = try TrackerList(parsing: SummaryCorpus.trackerTSV,
        categories: try TrackerCategoryMap(parsing: SummaryCorpus.trackerCategoriesTSV),
        aliases: try TrackerOwnerAliases(parsing: SummaryCorpus.trackerAliasesTSV))
    let flows = SummaryCorpus.flows()
    let s = SummaryBuilder.build(flows: flows, index: HostnameIndex(SummaryCorpus.observations(), flows: flows),
        classifier: CompanyClassifier(curated: curated, trackers: trackers), apps: try AppTable(parsing: SummaryCorpus.appsTSV))
    let zappy = try #require(s.apps.first { $0.key == SummaryCorpus.Expected.Zappy.key })
    #expect(SummaryText.mainRestReason(summary: zappy) == .hiddenByApp)
    #expect(SummaryText.mainRestReason(summary: try #require(s.apps.first { $0.name == "Bobber" })) == .unknownDestination)
}
