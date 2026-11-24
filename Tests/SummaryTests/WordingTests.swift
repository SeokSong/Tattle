import Companies
import Foundation
import Summary
import Testing

private typealias T = SummaryText

private func containsWord(_ text: String, _ phrase: String) -> Bool {
    let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

private let counts = [0, 1, 2, 31]
private let apps = ["Zappy", "com.example.weather"]
private let sources: [(Bool, Bool)] = [(true, true), (true, false), (false, true)]
private let percents = [0, 55, 69, 70, 82, 100]
private let reasons: [CaptureRestReason?] = CaptureRestReason.allCases.map { Optional($0) } + [nil]

/// every sentence-shaped output (ends with a full stop)
private func sentenceOutputs() -> [String] {
    var out: [String] = []
    for (c, r) in sources {
        for a in counts { for co in counts { for ad in counts { for ni in counts {
            out.append(T.overview(period: "14 to 21 November", hasCaptures: c, hasReport: r, apps: a, companies: co, adTrack: ad, notIdentified: ni))
        } } } }
    }
    for app in apps { for n in counts { out.append(T.companiesSentence(app: app, named: n)) } }
    for n in counts {
        out.append(T.adTrackSentence(n))
        out.append(T.notIdentifiedSentence(n))
        if let s = T.noProcessSentence(n) { out.append(s) }
    }
    for category in CompanyCategory.allCases { for n in [1, 2] { out += T.unnamedSentences([category: n]) } }
    for reason in reasons {
        for (identified, total) in [(0, 0), (0, 100), (50, 100), (77, 100), (100, 100)] {
            if let s = T.captureCoverage(period: "14 to 21 November", identifiedBytes: identified, totalBytes: total, mainReason: reason) { out.append(s) }
        }
    }
    for total in counts { for identified in counts where identified <= total {
        if let s = T.reportCoverage(period: "18 to 21 November", identified: identified, total: total) { out.append(s) }
        if let s = T.reportRating(identified: identified, total: total) { out.append(s) }
    } }
    for p in percents { out.append(T.captureRating(percent: p)) }
    for app in apps { out.append(T.dataAmountSentence(captureDay: "14 November", company: app)) }
    return out
}

private func allSentences() -> [String] {
    var out = sentenceOutputs()
    for app in apps {
        for a in counts { for ad in counts { for ni in counts {
            out += T.headline(app: app, named: a, adTrack: ad, notIdentified: ni, unnamed: [.advertising: 2, .cloudService: 1])
        } } }
    }
    for parent in apps {
        for isOwn in [true, false] {
            out.append(T.companyRow(parent: parent, categories: [.advertising, .unclassified, .analytics], isOwnCompany: isOwn))
            out.append(T.companyRow(parent: parent, categories: [], isOwnCompany: isOwn))
        }
        out.append(T.brandText(brand: "YouTube", parent: parent) ?? "")
        _ = T.brandText(brand: parent, parent: parent)
    }
    for (c, r) in sources { out.append(T.seenIn(captures: c, report: r)) }
    out += [T.possibleHeading, T.possibleExplanation, T.systemDescription, T.appleAppsDescription, T.appleAppsBreakdownHeading]
    for term in Glossary.terms { out += [term.term, term.text] }
    out += Glossary.howToRead
    for reason in CaptureRestReason.allCases { out.append(reason.text) }
    return out
}

@Test func wordingExactStrings() {
    #expect(T.overview(period: "14 to 21 November", hasCaptures: true, hasReport: true, apps: 12, companies: 31, adTrack: 9, notIdentified: 40)
        == "In your captures and App Privacy Report (14 to 21 November): 12 apps contacted 31 companies. 9 do advertising or tracking. 40 destinations couldn't be identified.")
    #expect(T.headline(app: "Zappy", named: 3, adTrack: 1, notIdentified: 3, unnamed: [.advertising: 2])
        == ["Zappy contacted 3 companies.", "1 does advertising or tracking.", "3 more destinations couldn't be identified.", "Plus 2 advertising services that couldn't be named."])
    #expect(T.companyRow(parent: "AdCo Holdings", categories: [.advertising, .analytics], isOwnCompany: false) == "AdCo Holdings · Advertising, Analytics")
    #expect(T.companyRow(parent: "Zappy Inc", categories: [.onlineService], isOwnCompany: true) == "Zappy Inc · the app's own company")
    #expect(T.brandText(brand: "YouTube", parent: "Alphabet") == "YouTube (owned by Alphabet)")
    #expect(T.captureCoverage(period: "14 to 21 November", identifiedBytes: 77, totalBytes: 100, mainReason: .hiddenByApp)
        == "Captures (14 to 21 November): 77% of this app's traffic was identified. Most of the rest was hidden by the app.")
    #expect(T.reportCoverage(period: "18 to 21 November", identified: 6, total: 9)
        == "App Privacy Report (18 to 21 November): 6 of 9 destinations were identified. The report doesn't show how much data was sent.")
    #expect(T.captureRating(percent: 82) == "Rated on 82% identified traffic.")
    #expect(T.captureRating(percent: 55) == "Not enough data to rate: 55% of this app's traffic was identified. A rating needs at least 70%.")
    #expect(T.reportRating(identified: 6, total: 9) == "Not enough data to rate: 6 of 9 destinations (66%) were identified. A rating needs at least 70%.")
    #expect(T.dataAmountSentence(captureDay: "14 November", company: "Alphabet") == "In the capture from 14 November, most of the data went to Alphabet.")
}

@Test func wordingPluralsAndZeroCases() {
    #expect(T.companiesSentence(app: "Zappy", named: 0) == "No companies were identified.")
    #expect(T.companiesSentence(app: "Zappy", named: 1) == "Zappy contacted 1 company.")
    #expect(T.companiesSentence(app: "Zappy", named: 2) == "Zappy contacted 2 companies.")
    #expect(T.adTrackSentence(0) == "No advertising or tracking companies found.")
    #expect(T.adTrackSentence(1) == "1 does advertising or tracking.")
    #expect(T.adTrackSentence(2) == "2 do advertising or tracking.")
    #expect(T.notIdentifiedSentence(0) == "Every destination was identified.")
    #expect(T.notIdentifiedSentence(1) == "1 more destination couldn't be identified.")
    #expect(T.notIdentifiedSentence(2) == "2 more destinations couldn't be identified.")
    #expect(T.unnamedSentences([.analytics: 1]) == ["Plus 1 analytics service that couldn't be named."])
    #expect(T.unnamedSentences([.unclassified: 3]) == [])
    #expect(T.noProcessSentence(0) == nil)
    #expect(T.noProcessSentence(1) == "1 connection had no app information from iOS.")
    #expect(T.noProcessSentence(2) == "2 connections had no app information from iOS.")
    #expect(T.reportCoverage(period: "18 to 21 November", identified: 1, total: 1)
        == "App Privacy Report (18 to 21 November): 1 of 1 destination was identified. The report doesn't show how much data was sent.")
    #expect(T.overview(period: "14 November", hasCaptures: true, hasReport: false, apps: 1, companies: 1, adTrack: 0, notIdentified: 0)
        == "In your captures (14 November): 1 app contacted 1 company. No advertising or tracking companies found. Every destination was identified.")
}

@Test func wordingNoBannedPhraseAnywhere() {
    for sentence in allSentences() {
        for phrase in Glossary.bannedPhrases { #expect(!containsWord(sentence, phrase), "\"\(phrase)\" in: \(sentence)") }
    }
}

@Test func wordingNoSpeakerAnywhere() {
    #expect(!containsWord("The status is fine", "us"))
    for sentence in allSentences() {
        for speaker in Glossary.bannedSpeakers { #expect(!containsWord(sentence, speaker), "\"\(speaker)\" in: \(sentence)") }
    }
}

@Test func wordingCountsAndUnknownStayTogether() {
    for named in 0...2 { for adTrack in 0...2 { for notIdentified in 0...2 {
        let lines = T.headline(app: "Zappy", named: named, adTrack: adTrack, notIdentified: notIdentified, unnamed: [:])
        #expect(lines.count >= 3)
        #expect(lines.count > 2 && lines[2] == T.notIdentifiedSentence(notIdentified))
    } } }
}

@Test func wordingPossibleNeverInCountSentences() {
    var out: [String] = []
    for (c, r) in sources { out.append(T.overview(period: "14 November", hasCaptures: c, hasReport: r, apps: 3, companies: 2, adTrack: 1, notIdentified: 4)) }
    for n in counts {
        out.append(T.companiesSentence(app: "Zappy", named: n))
        out.append(T.adTrackSentence(n))
        out.append(T.notIdentifiedSentence(n))
    }
    for category in CompanyCategory.allCases { out += T.unnamedSentences([category: 2]) }
    for sentence in out { #expect(!sentence.lowercased().contains("possible"), "in: \(sentence)") }
}

@Test func wordingCoverageHasPercentAndReason() {
    for reason in CaptureRestReason.allCases {
        let half = T.captureCoverage(period: "14 November", identifiedBytes: 50, totalBytes: 100, mainReason: reason)
        #expect(half?.contains("50%") == true)
        #expect(half?.contains(reason.text) == true)
        let full = T.captureCoverage(period: "14 November", identifiedBytes: 100, totalBytes: 100, mainReason: reason)
        #expect(full?.hasSuffix("identified.") == true)
        #expect(full?.contains("Most of the rest") == false)
    }
}

@Test func wordingPercentRoundsDown() {
    #expect(T.percent(2, of: 3) == 66)
    #expect(T.percent(1, of: 0) == nil)
    #expect(T.percent(0, of: 5) == 0)
}

@Test func wordingRatingThreshold() {
    #expect(T.captureRating(percent: 69).hasPrefix("Not enough data to rate"))
    #expect(T.captureRating(percent: 70).hasPrefix("Rated on"))
    #expect(T.reportRating(identified: 7, total: 10)?.hasPrefix("Rated on") == true)
    #expect(T.reportRating(identified: 0, total: 0) == nil)
}

@Test func wordingPeriods() {
    let utc = TimeZone(identifier: "UTC")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(timeZone: utc, year: y, month: m, day: d, hour: 12))!
    }
    #expect(T.period(from: date(2026, 11, 14), to: date(2026, 11, 14), timeZone: utc) == "14 November")
    #expect(T.period(from: date(2026, 11, 14), to: date(2026, 11, 21), timeZone: utc) == "14 to 21 November")
    #expect(T.period(from: date(2026, 11, 28), to: date(2026, 12, 3), timeZone: utc) == "28 November to 3 December")
    #expect(T.period(from: date(2025, 12, 28), to: date(2026, 1, 3), timeZone: utc) == "28 December 2025 to 3 January 2026")
}

@Test func wordingGlossaryHasSixTerms() {
    #expect(Glossary.terms.count == 6)
    #expect(Glossary.terms.map(\.term) == ["Company", "Advertising or tracking", "The app's own company", "Apple system and Apple apps", "Not identified", "Possible"])
    #expect(Glossary.howToRead.count == 3)
}

@Test func wordingEverySentenceEndsWithAFullStop() {
    var sentences = sentenceOutputs()
    sentences += [T.possibleExplanation, T.systemDescription, T.appleAppsDescription]
    sentences += Glossary.terms.map(\.text)
    sentences += Glossary.howToRead
    #expect(!sentences.isEmpty)
    for sentence in sentences { #expect(sentence.hasSuffix("."), "no full stop: \(sentence)") }
}
