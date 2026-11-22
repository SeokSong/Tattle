import Foundation
import Testing
import Companies

private func classifier(_ rows: String...) throws -> CompanyClassifier {
    let text = "domain\tcompany\tparent\tcategory\tnote\n" + rows.joined()
    return CompanyClassifier(curated: try CuratedList(parsing: text, version: "7", sha256: "abc"))
}

@Test func knownAdDomainIsAdvertising() {
    let label = CompanyClassifier().classify(hostname: "securepubads.g.doubleclick.net")
    #expect(label.category == .advertising)
    #expect(label.source == .curated)
    #expect(label.registrableDomain == "doubleclick.net")
    #expect(label.parent == "Alphabet")
    #expect(label.category.isAdvertisingOrTracking)
}

@Test func parentRollup() {
    let c = CompanyClassifier()
    let a = c.classify(hostname: "www.instagram.com")
    let b = c.classify(hostname: "static.xx.fbcdn.net")
    #expect(a.company != b.company)
    #expect(a.parent == "Meta Platforms" && a.parent == b.parent)
}

@Test func ladderMostSpecificWins() throws {
    let c = try classifier(
        "example.com\tExample\tExampleCo\tcloudService\tnote\n",
        "ads.example.com\tExample Ads\tExampleCo\tadvertising\tnote\n")
    #expect(c.classify(hostname: "example.com").category == .cloudService)
    #expect(c.classify(hostname: "www.example.com").rule == .curatedRegistrable)
    let ad = c.classify(hostname: "px.ads.example.com")
    #expect(ad.category == .advertising)
    #expect(ad.rule == .curatedHostname)
    #expect(ad.company == "Example Ads")
    // a sibling of the specific row falls back to the registrable domain
    #expect(c.classify(hostname: "cdn.example.com").category == .cloudService)
}

@Test func bundledLadderUsesHostnameRows() {
    let c = CompanyClassifier()
    #expect(c.classify(hostname: "analytics.google.com").category == .analytics)
    #expect(c.classify(hostname: "mail.google.com").category == .cloudService)
    #expect(c.classify(hostname: "iadsdk.apple.com").category == .advertising)
    #expect(c.classify(hostname: "gsp-ssl.ls.apple.com").category == .appleSystem)
}

@Test func unknownIsUnclassified() {
    let label = CompanyClassifier().classify(hostname: "no-such-company-here.example")
    #expect(label.category == .unclassified)
    #expect(label.source == .none)
    #expect(label.rule == .noMatch)
    #expect(label.company == nil && label.parent == nil)
    #expect(!label.isMatched)
    for odd in ["", "localhost", "192.168.1.1", "::1", "com"] {
        let l = CompanyClassifier().classify(hostname: odd)
        #expect(l.source == .none && l.category == .unclassified, "\(odd)")
    }
}

@Test func neverGuessesFromSubstring() {
    let c = CompanyClassifier()
    for name in ["notdoubleclick.net", "doubleclick.net.evil.example", "doubleclick-net.com", "xdoubleclick.net"] {
        #expect(c.classify(hostname: name).source == .none, "\(name)")
    }
    #expect(c.classify(hostname: "ad.doubleclick.net").source == .curated)
}

@Test func caseAndTrailingDotAreIgnored() {
    let label = CompanyClassifier().classify(hostname: "WWW.DoubleClick.NET.")
    #expect(label.source == .curated)
    #expect(label.hostname == "www.doubleclick.net")
}

@Test func labelCarriesDatasetVersion() throws {
    let c = try classifier("example.com\tExample\tExampleCo\tsocial\tnote\n")
    let label = c.classify(hostname: "a.example.com")
    #expect(label.datasetId == "tattle-curated")
    #expect(label.datasetVersion == "7")
    #expect(label.datasetSHA256 == "abc")
    #expect(label.relation == .unknown)
    // the bundled classifier carries the manifest's version and hash
    let entry = try #require(try DatasetManifest.load().datasets.first { $0.file == "curated.tsv" })
    let bundled = CompanyClassifier().classify(hostname: "doubleclick.net")
    #expect(bundled.datasetVersion == entry.version && bundled.datasetSHA256 == entry.sha256)
}

@Test func eachSourceRunsOnItsOwn() {
    let c = CompanyClassifier()
    // curated alone ignores the owner string; apple alone ignores the curated list
    let curated = c.label(hostname: "doubleclick.net", from: .curated, appleOwner: "Someone Else")
    #expect(curated.source == .curated && curated.parent == "Alphabet")
    let apple = c.label(hostname: "doubleclick.net", from: .appleOwner, appleOwner: " Someone Else ")
    #expect(apple.source == .appleOwner && apple.company == "Someone Else" && apple.rule == .appleOwner)
    #expect(apple.category == .unclassified && apple.parent == nil)
    #expect(c.label(hostname: "doubleclick.net", from: .appleOwner).source == .none)
    #expect(c.label(hostname: "doubleclick.net", from: .appleOwner, appleOwner: "  ").source == .none)
    #expect(c.label(hostname: "doubleclick.net", from: .trackerList).source == .none)
    #expect(c.label(hostname: "unknown.example", from: .curated).source == .none)
    let all = c.labelsBySource(hostname: "doubleclick.net", appleOwner: "Someone Else")
    #expect(all[.curated]?.source == .curated && all[.appleOwner]?.source == .appleOwner && all[.trackerList]?.source == LabelSource.none)
}

@Test func classifyOrderIsTheCallersChoice() {
    let c = CompanyClassifier()
    let both = c.classify(hostname: "doubleclick.net", appleOwner: "Someone Else")
    #expect(both.source == .curated)
    let reversed = c.classify(hostname: "doubleclick.net", appleOwner: "Someone Else", order: [.appleOwner, .curated])
    #expect(reversed.source == .appleOwner)
    // falls through to the next source when the first has nothing
    #expect(c.classify(hostname: "doubleclick.net", order: [.appleOwner, .curated]).source == .curated)
    #expect(c.classify(hostname: "doubleclick.net", appleOwner: "X", order: []).source == .none)
}

@Test func lookupCostIsPrinted() {
    let c = CompanyClassifier()
    _ = c.classify(hostname: "warm.example.com") // loads the list and the suffix list
    let names = ["securepubads.g.doubleclick.net", "www.instagram.com", "a.b.c.unknown-site.example", "px.ads.linkedin.com", "static.xx.fbcdn.net", "api.unknown.co.uk"]
    let rounds = 20_000
    var matched = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for i in 0..<rounds {
        if c.classify(hostname: names[i % names.count]).isMatched { matched += 1 }
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
    let perLookup = elapsed / Double(rounds)
    print("companies: classify costs \(Int(perLookup)) ns per hostname over \(rounds) lookups (matched \(matched))")
    #expect(matched > 0)
    #expect(perLookup < 200_000, "sanity floor 200 us per hostname")
}
