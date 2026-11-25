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
        var out = [r.title, r.subtitle, r.untraced] + [r.description, r.possible].compactMap { $0 }
        for t in r.traced { out += [t.text] + [t.detail].compactMap { $0 } }
        for c in r.trackingCompanies + r.otherCompanies { out += [c.parent, c.text, c.seenIn] + c.brands }
        return out + r.children.flatMap(strings)
    }
    let headings = [SummaryScreen.trackingHeading, SummaryScreen.otherHeading, SummaryScreen.untracedHeading,
                    SummaryScreen.tracedHeading, SummaryScreen.possibleExplanation, SummaryScreen.appleAppsBreakdownHeading]
    return screen.overview + screen.rows.flatMap(strings) + [screen.noProcess].compactMap { $0 } + headings
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

@Test func screenOpenedRowIsGroupedBullets() throws {
    // owner, 2026-11-24: bullets, not sentences; a reader spends 10 to 20 seconds per app at most
    let pinwheel = try row(SummaryDemo.screen(timeZone: utc), "Pinwheel")
    #expect(pinwheel.trackingCompanies.map(\.parent) == ["Adlantic", "Metricly"])
    #expect(pinwheel.otherCompanies.map(\.parent) == ["Pinwheel Labs", "Cloudway"])
    #expect(pinwheel.untraced == "4 destinations (1 advertising service, owner unknown)")
    #expect(pinwheel.traced.map(\.text) == ["Captures: 77.7% of traffic", "App Privacy Report: 9 of 12 destinations"])
    #expect(pinwheel.traced[0].detail != nil)
    #expect(pinwheel.traced[1].detail == "The report doesn't show how much data was sent.")
    let lantern = try row(SummaryDemo.screen(timeZone: utc), "com.example.lantern")
    #expect(lantern.traced.map(\.text) == ["App Privacy Report: 0 of 3 destinations"])
    #expect(lantern.untraced == "3 destinations")
    #expect(lantern.trackingCompanies.isEmpty && lantern.otherCompanies.isEmpty)
}

@Test func screenCompanyLines() throws {
    let pinwheel = try row(SummaryDemo.screen(timeZone: utc), "Pinwheel")
    let first = try #require(pinwheel.otherCompanies.first)
    #expect(first.text == "Pinwheel Labs · the app's own company · Online service")
    #expect(first.seenIn == "Seen in both")
    #expect(try #require(pinwheel.otherCompanies.first { $0.parent == "Cloudway" }).seenIn == "Seen in your App Privacy Report")
    #expect(pinwheel.trackingCompanies.first?.text == "Adlantic · Advertising")
}

@Test func screenOverviewAndEmpty() {
    let screen = SummaryDemo.screen(timeZone: utc)
    #expect(screen.overview.count == 4)
    #expect(screen.overview[0] == "6 apps")
    #expect(screen.overview[1].hasSuffix("of them advertising or tracking"))
    #expect(screen.overview[2].hasSuffix("destinations not traced"))
    #expect(screen.overview[3].hasPrefix("Captures ") && screen.overview[3].contains(" · App Privacy Report "))
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
        for c in r.trackingCompanies + r.otherCompanies {
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

@Test func screenDemoNeverSaysNoneWithAnUntracedReportLine() {
    // the demo once had a report entry with 1 untraced destination but an empty untraced list, so the card said
    // nothing was untraced above "4 of 5 destinations"
    let pattern = try! NSRegularExpression(pattern: "(\\d+) of (\\d+) destination")
    func check(_ row: SummaryRow) {
        if row.untraced == "None" {
            for t in row.traced {
                guard let m = pattern.firstMatch(in: t.text, range: NSRange(t.text.startIndex..., in: t.text)),
                      let a = Range(m.range(at: 1), in: t.text), let b = Range(m.range(at: 2), in: t.text) else { continue }
                #expect(t.text[a] == t.text[b], "\(row.title): \(t.text)")
            }
        }
        row.children.forEach(check)
    }
    SummaryDemo.screen().rows.forEach(check)
}
