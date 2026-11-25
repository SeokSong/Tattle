import Foundation
import Summary
import Testing

private let utc = TimeZone(identifier: "UTC")!

private func containsWord(_ text: String, _ phrase: String) -> Bool {
    let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
    let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

private func row(_ screen: SummaryScreen, _ title: String) throws -> SummaryRow {
    try #require(screen.rows.first { $0.title == title })
}

/// every string the screen shows
private func everyString(_ screen: SummaryScreen) -> [String] {
    func strings(_ r: SummaryRow) -> [String] {
        var out = [r.title, r.subtitle] + r.sentences + r.possibleNames
        out += [r.description, r.captureLine, r.captureDetail, r.reportLine].compactMap { $0 }
        for c in r.companies { out += [c.parent, c.text, c.seenIn] + c.brands }
        return out + r.children.flatMap(strings)
    }
    return screen.overview + screen.rows.flatMap(strings) + [screen.noProcess].compactMap { $0 }
}

@Test func screenRowsFollowTheOwnersOrder() throws {
    let screen = SummaryDemo.screen(timeZone: utc)
    #expect(screen.rows.map(\.title) == ["Quillnote", "Pinwheel", "Bobbin", "com.example.lantern", "Apple apps", "iOS system"])
    #expect(try row(screen, "Apple apps").children.map(\.title) == ["Safari", "Maps"])
}

@Test func screenSubtitles() throws {
    let screen = SummaryDemo.screen(timeZone: utc)
    #expect(try row(screen, "Pinwheel").subtitle == "4 companies · 2 advertising or tracking")
    #expect(try row(screen, "Bobbin").subtitle == "1 company · no advertising or tracking found")
    #expect(try row(screen, "com.example.lantern").subtitle == "3 destinations, none traced")
}

@Test func screenOpenedRowUsesTheApprovedSentences() throws {
    let combined = SummaryDemo.combined()
    let screen = SummaryScreenBuilder.build(combined, timeZone: utc)
    let card = try #require(combined.cards.first { $0.name == "Pinwheel" })
    let pinwheel = try row(screen, "Pinwheel")
    #expect(pinwheel.sentences == SummaryText.appSentences(
        app: "Pinwheel", companies: card.companyNames, adTrack: card.adTrackNames,
        untraced: card.untracedDestinations, typeKnown: card.typeKnown))
    #expect(try #require(pinwheel.captureLine).contains("77.7%"))
    #expect(try #require(pinwheel.reportLine).contains("9 of this app's 12 destinations"))
    #expect(pinwheel.captureDetail != nil)
    #expect(try row(screen, "com.example.lantern").captureLine == nil)
}

@Test func screenCompanyLines() throws {
    let pinwheel = try row(SummaryDemo.screen(timeZone: utc), "Pinwheel")
    let first = try #require(pinwheel.companies.first)
    #expect(first.text == "Pinwheel Labs · the app's own company · Online service")
    #expect(first.seenIn == "Seen in both")
    #expect(try #require(pinwheel.companies.first { $0.parent == "Cloudway" }).seenIn == "Seen in your App Privacy Report")
}

@Test func screenOverviewAndEmpty() {
    let screen = SummaryDemo.screen(timeZone: utc)
    #expect(screen.overview.count == 2)
    #expect(screen.overview[0].hasPrefix("In your captures and App Privacy Report ("))
    let empty = SummaryScreenBuilder.build(CombinedSummaryBuilder.build(capture: nil, report: nil), timeZone: utc)
    #expect(empty.isEmpty)
    #expect(empty.overview == [])
    #expect(empty.noProcess == nil)
}

@Test func screenDemoUsesOnlyMadeUpNames() {
    let screen = SummaryDemo.screen(timeZone: utc)
    let titles: Set<String> = ["Pinwheel", "Quillnote", "Bobbin", "com.example.lantern", "Safari", "Maps", "Apple apps", "iOS system"]
    let companies: Set<String> = ["Pinwheel Labs", "Adlantic", "Metricly", "Cloudway", "Quillnote Inc", "Trackwise", "Pixelbeam", "Apple"]
    let ip = try! NSRegularExpression(pattern: "\\d\\.\\d+\\.\\d")
    func check(_ r: SummaryRow) {
        #expect(titles.contains(r.title), "title \(r.title)")
        for c in r.companies {
            #expect(companies.contains(c.parent), "company \(c.parent)")
            for b in c.brands { #expect(companies.contains(b), "brand \(b)") }
        }
        r.children.forEach(check)
    }
    screen.rows.forEach(check)
    for s in everyString(screen) {
        for bad in [".com", ".net", ".org"] { #expect(!s.contains(bad), "\(bad) in \(s)") }
        #expect(ip.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil, "ip-like text: \(s)")
    }
}

@Test func screenTextPassesTheWordingLint() {
    let screen = SummaryDemo.screen(timeZone: utc)
    let shown = everyString(screen) + [SummaryScreen.emptyText, SummaryScreen.howToReadHeading]
    #expect(shown.count > 50)
    for s in shown {
        for phrase in Glossary.bannedPhrases { #expect(!containsWord(s, phrase), "banned \"\(phrase)\": \(s)") }
        for speaker in Glossary.bannedSpeakers { #expect(!containsWord(s, speaker), "speaker \"\(speaker)\": \(s)") }
        #expect(!s.contains("{") && !s.contains("}"), "unfilled placeholder: \(s)")
        #expect(!(s.hasPrefix("[") && s.hasSuffix("]")), "missing key: \(s)")
        #expect(!s.isEmpty)
    }
}

@Test func screenHasNoByteText() {
    for s in everyString(SummaryDemo.screen(timeZone: utc)) {
        for unit in ["bytes", "KB", "MB", "GB"] { #expect(!s.contains(unit), "\(unit) in \(s)") }
    }
}

@Test func screenDemoNeverSaysEveryDestinationWithAnUntracedReportLine() {
    // the demo once had a report entry with 1 untraced destination but an empty untraced list, so the card said
    // "Every named destination was traced" above "4 of this app's 5 destinations could be traced"
    func check(_ row: SummaryRow) {
        if row.sentences.contains(where: { $0.hasPrefix("Every named destination") }), let line = row.reportLine {
            #expect(!line.contains(" of this app's "), "\(row.title): \(line)")
        }
        row.children.forEach(check)
    }
    SummaryDemo.screen().rows.forEach(check)
}
