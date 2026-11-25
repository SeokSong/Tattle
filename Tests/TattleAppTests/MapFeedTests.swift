import Companies
import Foundation
import Summary
import Testing
import WorldMap

@testable import TattleApp

// the map's placement rules (owner, 2026-11-25). companies are real parents from the bundled head-office table;
// apps are made up

private func line(_ parent: String) -> CompanyLine { CompanyLine(parent: parent, text: parent, brands: [], seenIn: "captures") }

private func app(_ id: String, _ parents: [String], children: [SummaryRow] = []) -> SummaryRow {
    SummaryRow(id: id, kind: children.isEmpty ? .app : .appleApps, title: id, subtitle: "", description: nil,
               trackingCompanies: parents.prefix(1).map(line), otherCompanies: parents.dropFirst().map(line), untraced: "",
               traced: [], possible: nil, children: children)
}

@Test func summaryMapCountsAppsPerHeadOffice() throws {
    let screen = SummaryScreen(overview: [], rows: [
        app("test.one", ["Alphabet", "Meta Platforms"]),
        app("test.two", ["Alphabet", "Madeupco"]),
        // the merged Apple apps card: each app inside counts, the card itself does not
        app("apple", ["Apple"], children: [app("test.safari", ["Apple", "Alphabet"]), app("test.maps", ["Apple"])]),
    ], noProcess: nil)
    let map = MapFeed.summaryLines(screen)
    let alphabet = try #require(map.lines.lines.first { $0.companies == ["Alphabet"] })
    // three apps contacted Alphabet: the brightness counts apps, not rows or connections
    #expect(alphabet.count == 3)
    #expect(map.lines.lines.first { $0.companies == ["Apple"] }?.count == 2)
    // a company with no known head office is counted under the map, once
    #expect(map.notDrawn == 1)
    #expect(MapFeed.summaryLines(nil).lines.lines.isEmpty)
}

@Test func mapTextSaysWhatTheLinesAreAndWhenTheStartIsTheDefault() {
    #expect(MapText.notServers.contains("not to the servers"))
    #expect(MapStart.fallback.isDefault)
    #expect(MapText.defaultStart.hasPrefix("Default location: Colorado Springs"))
    #expect(MapText.notDrawn(0) == nil)
    #expect(MapText.notDrawn(1) == "1 connection is not on the map (company or head office unknown).")
    #expect(MapText.notDrawnApps(2) == "2 companies are not on the map (head office unknown).")
}

@Test func noLabelMeansNoPlace() {
    #expect(MapFeed.place(for: nil) == nil)
}
