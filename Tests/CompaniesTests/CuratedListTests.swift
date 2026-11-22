import CryptoKit
import Foundation
import Testing
import Companies

// plain import (no @testable) so these also run under `swift test -c release`

private let header = "domain\tcompany\tparent\tcategory\tnote\n"

private func row(_ domain: String, company: String = "Co", parent: String = "Parent", category: String = "advertising") -> String {
    "\(domain)\t\(company)\t\(parent)\t\(category)\tnote\n"
}

@Test func categoryNamesAreStable() {
    // raw values are written into exports; this is the vocabulary table
    let expected = ["advertising", "analytics", "social", "contentDelivery", "cloudService", "appleSystem", "onlineService", "unclassified"]
    #expect(CompanyCategory.allCases.map(\.rawValue) == expected)
    #expect(CompanyCategory.allCases.map(\.label) == [
        "Advertising", "Analytics", "Social media", "Content delivery", "Cloud or app service", "Apple system", "Online service", "Not matched",
    ])
    #expect(CompanyCategory.allCases.filter(\.isAdvertisingOrTracking) == [.advertising, .analytics])
    #expect(LabelSource.allCases.map(\.rawValue) == ["curated", "trackerList", "appleOwner", "none"])
}

@Test func duplicateDomainFailsLoad() {
    #expect(throws: CuratedListError.duplicateDomain(line: 3)) {
        try CuratedList(parsing: header + row("example.com") + row("example.com", company: "Other"))
    }
}

@Test func unknownCategoryFailsLoad() {
    #expect(throws: CuratedListError.unknownCategory(line: 2)) {
        try CuratedList(parsing: header + row("example.com", category: "adverts"))
    }
    // unclassified is the absence of a row, never a row
    #expect(throws: CuratedListError.unknownCategory(line: 2)) {
        try CuratedList(parsing: header + row("example.com", category: "unclassified"))
    }
}

@Test func malformedRowsFailLoad() {
    #expect(throws: CuratedListError.missingHeader) { try CuratedList(parsing: "") }
    #expect(throws: CuratedListError.missingHeader) { try CuratedList(parsing: "domain\tcompany\n") }
    #expect(throws: CuratedListError.wrongColumnCount(line: 2)) { try CuratedList(parsing: header + "example.com\tCo\n") }
    #expect(throws: CuratedListError.emptyField(line: 2)) { try CuratedList(parsing: header + row("example.com", company: "")) }
    // a key must be registrable (or below one), lowercase, without a trailing dot
    for key in ["com", "localhost", "192.168.1.1", "Example.com", "example.com."] {
        #expect(throws: CuratedListError.notRegistrable(line: 2)) { try CuratedList(parsing: header + row(key)) }
    }
}

@Test func errorsDoNotEchoValues() {
    let secret = "secret-company-name"
    let text = header + row("example.com", company: secret, parent: secret, category: "nonsense")
    do {
        _ = try CuratedList(parsing: text)
        Issue.record("expected a load error")
    } catch {
        #expect(!String(describing: error).contains(secret))
        #expect(!String(describing: error).contains("example"))
        #expect(!error.localizedDescription.contains(secret))
    }
}

@Test func windowsLineEndingsAndTrailingBlankLinesLoad() throws {
    let list = try CuratedList(parsing: (header + row("example.com")).replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\n")
    #expect(list.count == 1)
}

@Test func everyRowIsRegistrableOrHostname() throws {
    let list = try CuratedList.loadBundled()
    #expect(list.count >= 200)
    for entry in list.entries {
        let registrable = try #require(registrableDomain(of: entry.domain), "\(entry.domain)")
        #expect(entry.domain == registrable || entry.domain.hasSuffix("." + registrable), "\(entry.domain)")
        #expect(!entry.company.isEmpty && !entry.parent.isEmpty && !entry.note.isEmpty, "\(entry.domain)")
        #expect(entry.category != .unclassified)
    }
}

@Test func bundledListMatchesManifest() throws {
    let manifest = try DatasetManifest.load()
    let entry = try #require(manifest.datasets.first { $0.file == "curated.tsv" })
    let url = try #require(DatasetManifest.resourceURL("curated.tsv"))
    let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    #expect(hash == entry.sha256)
    let list = try CuratedList.loadBundled()
    #expect(list.count == entry.rules)
    #expect(list.version == entry.version && list.sha256 == entry.sha256)
    // the manifest still carries the public suffix list beside it
    #expect(manifest.datasets.contains { $0.file == "psl.dat" })
}

@Test func onlineServiceIsProductNotInfrastructure() {
    #expect(!CompanyCategory.onlineService.isAdvertisingOrTracking)
    #expect(CompanyCategory.curatable.contains(.onlineService))
    let c = CompanyClassifier()
    #expect(c.classify(hostname: "www.youtube.com").category == .onlineService)
    #expect(c.classify(hostname: "rr1.googlevideo.com").category == .contentDelivery)
    #expect(c.classify(hostname: "sts.amazonaws.com").category == .cloudService)
}

@Test func operatedSuffixMustBePrivateRule() throws {
    let ok = "suffix:pages.dev\tCo\tParent\tcloudService\tplatform's own hosts\n"
    #expect(try CuratedList(parsing: header + ok).operatedSuffixes.count == 1)
    // an icann suffix, a name that is no rule, a wildcard, a registrable domain and an uppercase key all fail
    for key in ["suffix:co.uk", "suffix:com", "suffix:example.com", "suffix:*.compute.amazonaws.com", "suffix:Pages.dev", "suffix:"] {
        #expect(throws: CuratedListError.notPrivateSuffix(line: 2), "\(key)") {
            try CuratedList(parsing: header + "\(key)\tCo\tParent\tcloudService\tnote\n")
        }
    }
    // the bundled list marks only a small number
    let bundled = try CuratedList.loadBundled()
    #expect(bundled.operatedSuffixes.map(\.domain) == ["suffix:googleapis.com"])
    #expect(!bundled.entries.contains { $0.domain.hasPrefix("suffix:") })
}
