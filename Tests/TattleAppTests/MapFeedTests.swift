import Companies
import Flows
import PacketDecoder
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

// found in the owner's phone test (2026-11-25): a connection reached the live snapshot before its name was read,
// was counted as not drawn at once and never looked at again, so lines appeared only after Stop
@MainActor
@Test func aConnectionWithoutANameYetIsTriedAgain() {
    let key = FlowKey(transport: .tcp, localAddress: .v4(0x0A00_0002), localPort: 40001,
                      remoteAddress: .v4(0xC000_0201), remotePort: 443)
    let now = Date()
    var young = Flow(key: key, interface: "en0", at: now.addingTimeInterval(-1))
    young.tally[ProcessPair("Zappyx", 1, nil, nil)] = 3
    let feed = MapFeed()
    feed.ingest(flows: [young], dns: [], now: now)
    #expect(feed.live.lines.isEmpty && feed.live.notDrawn == 0)
    // the next refresh: the name has been read (google.com: Alphabet, a curated parent with a head office)
    var named = young
    named.serverName = "google.com"
    feed.ingest(flows: [named], dns: [], now: now.addingTimeInterval(2))
    #expect(feed.live.lines.count == 1 && feed.live.lines[0].companies == ["Alphabet"])
    // a connection that never gets a name counts as not drawn once it is old enough, and only once
    var nameless = young
    nameless = Flow(key: FlowKey(transport: .tcp, localAddress: .v4(0x0A00_0002), localPort: 40002,
                                 remoteAddress: .v4(0xC000_0202), remotePort: 443), interface: "en0", at: now)
    nameless.tally[ProcessPair("Zappyx", 1, nil, nil)] = 3
    feed.ingest(flows: [nameless], dns: [], now: now.addingTimeInterval(1))
    #expect(feed.live.notDrawn == 0)
    feed.ingest(flows: [nameless], dns: [], now: now.addingTimeInterval(MapFeed.nameWait + 1))
    feed.ingest(flows: [nameless], dns: [], now: now.addingTimeInterval(MapFeed.nameWait + 3))
    #expect(feed.live.notDrawn == 1)
}

@MainActor
@Test func nameLookupsAreNeitherDrawnNorCounted() {
    let now = Date()
    var lookup = Flow(key: FlowKey(transport: .udp, localAddress: .v4(0x0A00_0002), localPort: 50000,
                                   remoteAddress: .v4(0x0A00_0001), remotePort: 53), interface: "en0", at: now.addingTimeInterval(-30))
    lookup.tally[ProcessPair("mDNSResponder", 1, nil, nil)] = 2
    let feed = MapFeed()
    feed.ingest(flows: [lookup], dns: [], now: now)
    feed.ingest(flows: [lookup], dns: [], now: now.addingTimeInterval(20))
    #expect(feed.live.lines.isEmpty && feed.live.notDrawn == 0)
}
