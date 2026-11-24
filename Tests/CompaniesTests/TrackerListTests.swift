import Testing
import Foundation
import CryptoKit
import Companies

private let mapText = "adguardCategory\tcategory\tnote\nads\tadvertising\tn\nstats\tanalytics\tn\nmisc\tunclassified\tn\n"
private let aliasText = "adguardCompany\tparent\tnote\nExample Ads Inc.\tExample Parent\tn\n"
private let listHeader = "domain\tcompany\tadguardCategory\n"

private func list(_ rows: String) throws -> TrackerList {
    try TrackerList(parsing: listHeader + rows,
                    categories: TrackerCategoryMap(parsing: mapText),
                    aliases: TrackerOwnerAliases(parsing: aliasText))
}

@Test func trackerLookupFindsRegistrableRow() throws {
    let l = try list("example.com\tExample Ads Inc.\tads\n")
    let (entry, rule) = try #require(l.lookup("example.com", registrable: "example.com"))
    #expect(entry.company == "Example Ads Inc.")
    #expect(entry.parent == "Example Parent")
    #expect(entry.category == .advertising)
    #expect(rule == .trackerRegistrable)
}

@Test func trackerSubdomainWalksUpAndMostSpecificWins() throws {
    let l = try list("ads.example.com\tAds Co\tads\nexample.com\tSite Co\tstats\n")
    let (a, ruleA) = try #require(l.lookup("x.ads.example.com", registrable: "example.com"))
    #expect(a.company == "Ads Co" && ruleA == .trackerHostname)
    let (b, ruleB) = try #require(l.lookup("www.example.com", registrable: "example.com"))
    #expect(b.company == "Site Co" && ruleB == .trackerRegistrable)
}

@Test func trackerMissingIsNil() throws {
    let l = try list("example.com\tSite Co\tads\n")
    #expect(l.lookup("example.net", registrable: "example.net") == nil)
}

@Test func trackerUnmappedOwnerKeepsOwnString() throws {
    let l = try list("example.com\tOther Co\tads\n")
    let (entry, _) = try #require(l.lookup("example.com", registrable: "example.com"))
    #expect(entry.parent == "Other Co")
}

@Test func trackerEmptyCompanyKeepsCategory() throws {
    let l = try list("example.org\t\tads\n")
    let (entry, _) = try #require(l.lookup("example.org", registrable: "example.org"))
    #expect(entry.company == nil && entry.parent == nil)
    #expect(entry.category == .advertising)
}

@Test func trackerUnclassifiedCategoryIsKept() throws {
    let l = try list("example.com\tSite Co\tmisc\n")
    let (entry, _) = try #require(l.lookup("example.com", registrable: "example.com"))
    #expect(entry.category == .unclassified)
}

@Test func trackerPublicSuffixRowIsSkippedAndCounted() throws {
    let l = try list("co.uk\tSite Co\tads\nexample.com\tSite Co\tads\n")
    #expect(l.count == 1)
    #expect(l.skippedNotRegistrable == 1)
    #expect(l.lookup("example.co.uk", registrable: "example.co.uk") == nil)
}

@Test func trackerBadFilesFailWithLineNumbers() throws {
    #expect(throws: TrackerDataError.missingHeader) { try TrackerList(parsing: "domain\tcompany\n", categories: TrackerCategoryMap(parsing: mapText), aliases: TrackerOwnerAliases(parsing: aliasText)) }
    #expect(throws: TrackerDataError.wrongColumnCount(line: 2)) { try list("example.com\tads\n") }
    #expect(throws: TrackerDataError.emptyField(line: 2)) { try list("\tSite Co\tads\n") }
    #expect(throws: TrackerDataError.invalidDomain(line: 2)) { try list("Example.com\tSite Co\tads\n") }
    #expect(throws: TrackerDataError.invalidDomain(line: 2)) { try list("example.com.\tSite Co\tads\n") }
    #expect(throws: TrackerDataError.notSorted(line: 3)) { try list("example.net\tSite Co\tads\nexample.com\tSite Co\tads\n") }
    #expect(throws: TrackerDataError.duplicate(line: 3)) { try list("example.com\tSite Co\tads\nexample.com\tSite Co\tads\n") }
    #expect(throws: TrackerDataError.unknownCategory(line: 2)) { try list("example.com\tSite Co\tnope\n") }
}

@Test func trackerMapsRejectBadRows() throws {
    #expect(throws: TrackerDataError.unknownCategory(line: 2)) {
        try TrackerCategoryMap(parsing: "adguardCategory\tcategory\tnote\nads\tadverts\tn\n")
    }
    #expect(throws: TrackerDataError.duplicate(line: 3)) {
        try TrackerOwnerAliases(parsing: aliasText + "Example Ads Inc.\tExample Parent\tn\n")
    }
}

@Test func bundledTrackerListMatchesManifest() throws {
    let manifest = try DatasetManifest.load()
    let entry = try #require(manifest.datasets.first { $0.file == "tracker/tracker.tsv" })
    let url = try #require(DatasetManifest.resourceURL("tracker/tracker.tsv"))
    let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    #expect(hash == entry.sha256)
    #expect(entry.licence == "CC-BY-SA-4.0")
    #expect(entry.sourceURL == "https://github.com/AdguardTeam/companiesdb")
    let l = try TrackerList.loadBundled()
    #expect(l.count + l.skippedNotRegistrable == entry.rules)
    #expect(l.skippedNotRegistrable > 0 && l.skippedNotRegistrable < 100)
    #expect(l.version == entry.version)
}

@Test func bundledTrackerCategoryMapIsTheOwnersChoice() throws {
    let url = try #require(DatasetManifest.resourceURL("tracker-categories.tsv"))
    let map = try TrackerCategoryMap(parsing: String(contentsOf: url, encoding: .utf8))
    let expected: [(String, CompanyCategory)] = [
        ("advertising", .advertising), ("pornvertising", .advertising),
        ("site_analytics", .analytics), ("mobile_analytics", .analytics), ("telemetry", .analytics),
        ("social_media", .social), ("cdn", .contentDelivery),
        ("hosting", .cloudService), ("customer_interaction", .cloudService), ("essential", .cloudService),
        ("consent", .cloudService), ("email", .cloudService),
        ("audio_video_player", .onlineService), ("comments", .onlineService),
        ("misc", .unclassified), ("unknown", .unclassified), ("extensions", .unclassified),
    ]
    #expect(map.count == 17)
    for (name, category) in expected { #expect(map.category(for: name) == category) }
}

@Test func bundledTrackerAliasParentsAreCuratedParents() throws {
    let aliasURL = try #require(DatasetManifest.resourceURL("tracker-owner-aliases.tsv"))
    let aliases = try TrackerOwnerAliases(parsing: String(contentsOf: aliasURL, encoding: .utf8))
    let mapURL = try #require(DatasetManifest.resourceURL("tracker-categories.tsv"))
    let map = try TrackerCategoryMap(parsing: String(contentsOf: mapURL, encoding: .utf8))
    #expect(aliases.parents.isSubset(of: Set(CuratedList.bundled.entries.map(\.parent))))
    let manifest = try DatasetManifest.load()
    let aliasEntry = try #require(manifest.datasets.first { $0.file == "tracker-owner-aliases.tsv" })
    let mapEntry = try #require(manifest.datasets.first { $0.file == "tracker-categories.tsv" })
    #expect(aliasEntry.rules == aliases.count)
    #expect(mapEntry.rules == map.count)
}

@Test func bundledTrackerLicenceShips() throws {
    let licence = try #require(DatasetManifest.resourceURL("tracker/LICENSE"))
    #expect(try String(contentsOf: licence, encoding: .utf8).contains("Attribution-ShareAlike 4.0 International"))
    #expect(DatasetManifest.resourceURL("tracker/README.md") != nil)
}

// MARK: classifier

private func trackerClassifier(curated: String, trackers: String) throws -> CompanyClassifier {
    CompanyClassifier(curated: try CuratedList(parsing: "domain\tcompany\tparent\tcategory\tnote\n" + curated),
                      trackers: try list(trackers))
}

@Test func classifierUsesTrackerListAfterCurated() throws {
    let c = try trackerClassifier(curated: "zorblax.com\tZorblax\tZorblax Holdings\tadvertising\tn\n",
                                  trackers: "ads.zorblax.com\tZorblax Tracker\tads\ntrk-only.test\tBlinkerly\tads\n")
    #expect(c.classify(hostname: "ads.zorblax.com").source == .curated)
    let label = c.classify(hostname: "x.trk-only.test")
    #expect(label.source == .trackerList)
    #expect(label.rule == .trackerRegistrable)
    #expect(label.datasetId == TrackerList.datasetId)
}

@Test func trackerLabelWithoutCompanyIsNotIdentified() throws {
    let c = try trackerClassifier(curated: "", trackers: "nocompany.test\t\tads\n")
    let label = c.label(hostname: "nocompany.test", from: .trackerList)
    #expect(!label.isMatched)
    #expect(label.category == .unclassified)
    #expect(c.classify(hostname: "nocompany.test").source == .none)
}

@Test func trackerUnclassifiedCategoryStaysUnclassified() throws {
    let c = try trackerClassifier(curated: "", trackers: "x.test\tSome Co\tmisc\n")
    let label = c.classify(hostname: "x.test")
    #expect(label.source == .trackerList)
    #expect(label.company == "Some Co")
    #expect(label.category == .unclassified)
}

@Test func curatedOnlyOrderIgnoresTrackers() throws {
    let c = try trackerClassifier(curated: "", trackers: "trk-only.test\tBlinkerly\tads\n")
    #expect(c.classify(hostname: "trk-only.test", order: [.curated]).source == .none)
    #expect(c.classify(hostname: "trk-only.test", order: [.curated, .trackerList]).source == .trackerList)
}
