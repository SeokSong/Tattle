import CryptoKit
import Foundation
import Testing
import Companies

// plain import (no @testable) so these also run under `swift test -c release`. made-up companies and places only

private let header = "parent\tcity\tcountry\tlatitude\tlongitude\twikidata\tmatch\n"

private func row(_ parent: String = "Adlantic", city: String = "Springfield", country: String = "Freedonia",
                 lat: String = "38.8", lon: String = "-104.8", item: String = "Q1", match: String = "website") -> String {
    "\(parent)\t\(city)\t\(country)\t\(lat)\t\(lon)\t\(item)\t\(match)\n"
}

@Test func headOfficeTableReadsRows() throws {
    let table = try HeadOfficeTable(parsing: header + row() + row("Trackwise", country: "", lat: "-33.9", lon: "151.2", match: "hand"))
    #expect(table.count == 2)
    let a = try #require(table.office(forParent: "Adlantic"))
    #expect(a.city == "Springfield" && a.latitude == 38.8 && a.longitude == -104.8 && a.match == .website)
    // a place with no country in Wikidata still has coordinates, so it is kept
    #expect(table.office(forParent: "Trackwise")?.country == "")
    // the table is keyed by the parent name exactly: a brand is looked up by its parent
    #expect(table.office(forParent: "adlantic") == nil)
}

@Test func headOfficeTableRejectsBadFiles() {
    #expect(throws: HeadOfficeError.missingHeader) { try HeadOfficeTable(parsing: row()) }
    #expect(throws: HeadOfficeError.wrongColumnCount(line: 2)) { try HeadOfficeTable(parsing: header + "Adlantic\tSpringfield\n") }
    #expect(throws: HeadOfficeError.emptyField(line: 2)) { try HeadOfficeTable(parsing: header + row(city: "")) }
    #expect(throws: HeadOfficeError.badCoordinate(line: 2)) { try HeadOfficeTable(parsing: header + row(lat: "91")) }
    #expect(throws: HeadOfficeError.badCoordinate(line: 2)) { try HeadOfficeTable(parsing: header + row(lon: "east")) }
    #expect(throws: HeadOfficeError.unknownMatch(line: 2)) { try HeadOfficeTable(parsing: header + row(match: "name")) }
    #expect(throws: HeadOfficeError.duplicateParent(line: 3)) { try HeadOfficeTable(parsing: header + row() + row(city: "Shelbyville")) }
}

@Test func headOfficeFilesCombineWithoutOverlap() throws {
    let table = try HeadOfficeTable(parsing: header + row(), tracker: header + row("Pixelbeam", match: "pinned"))
    #expect(table.count == 2 && table.office(forParent: "Pixelbeam") != nil)
    // a parent in both files is a build error, never a silent choice
    #expect(throws: HeadOfficeError.duplicateParent(line: 0)) { try HeadOfficeTable(parsing: header + row(), tracker: header + row()) }
}

@Test func bundledHeadOfficesMatchManifest() throws {
    let manifest = try DatasetManifest.load()
    var rows = 0
    // the curated parents' file is ours (MIT); the AdGuard companies' file stays CC BY-SA in the tracker folder
    for (file, licence) in [("hq.tsv", "MIT (own selection; head offices from Wikidata, CC0-1.0)"), ("tracker/hq.tsv", "CC-BY-SA-4.0")] {
        let entry = try #require(manifest.datasets.first { $0.file == file })
        let url = try #require(DatasetManifest.resourceURL(file))
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        #expect(hash == entry.sha256, "\(file)")
        #expect(entry.licence == licence, "\(file)")
        rows += entry.rules
    }
    #expect(try HeadOfficeTable.loadBundled().count == rows)
}
