import CryptoKit
import Companies
import Foundation
import Testing

private let header = "bundleId\tdisplayName\tprocessName\tcompany\tnote\n"

private func table(_ rows: String) throws -> AppTable {
    try AppTable(parsing: header + rows)
}

/// fake ids only: nothing here names a real app
private let sample = """
    com.example.photos\tExample Photos\tExamplePhotos\tExample Corp\tfake row for tests
    com.example.suite.\tExample Suite\t\tExample Corp\tfake prefix row
    com.example.suite.mail\tExample Mail\tExampleMailClientApp\tExample Mail Inc\tfake exact row under a prefix
    com.other.\tOther app\t\tOther Co\tfake prefix row
    """

@Test func exactBundleIdJoins() throws {
    let t = try table(sample)
    #expect(t.row(forBundleId: "com.example.photos")?.displayName == "Example Photos")
    #expect(t.company(forBundleId: "com.example.photos") == "Example Corp")
    // an exact row beats the prefix row above it
    #expect(t.company(forBundleId: "com.example.suite.mail") == "Example Mail Inc")
    // case does not matter in a bundle id
    #expect(t.row(forBundleId: "COM.Example.Photos") != nil)
}

@Test func prefixJoins() throws {
    let t = try table(sample)
    #expect(t.company(forBundleId: "com.example.suite.calendar") == "Example Corp")
    #expect(t.company(forBundleId: "com.other.anything.deep") == "Other Co")
    // the prefix itself is not an app id, and a prefix ends at a dot: no partial component match
    #expect(t.row(forBundleId: "com.other.") == nil)
    #expect(t.row(forBundleId: "com.otherwise.app") == nil)
}

@Test func noFuzzyJoin() throws {
    let t = try table(sample)
    // same last component, a prefix of the id, a longer id, another namespace: none of them join
    #expect(t.row(forBundleId: "org.example.photos") == nil)
    #expect(t.row(forBundleId: "com.example.photo") == nil)
    #expect(t.row(forBundleId: "com.example.photos2") == nil)
    #expect(t.row(forBundleId: "com.example.photos.extension") == nil)
    #expect(t.row(forBundleId: "com.example") == nil)
    // a process name never joins by prefix or by case
    #expect(t.row(forProcessName: "ExampleP") == nil)
    #expect(t.row(forProcessName: "examplephotos") == nil)
}

@Test func cutProcessNameMatchesFullName() throws {
    let t = try table(sample)
    // the kernel reports 16 characters: ExampleMailClien
    #expect(t.row(forProcessName: "ExampleMailClientApp")?.displayName == "Example Mail")
    #expect(t.row(forProcessName: "ExampleMailClien")?.displayName == "Example Mail")
    #expect(t.company(for: "ExampleMailClien") == "Example Mail Inc")
    // a shorter prefix of the cut form is a different name
    #expect(t.row(forProcessName: "ExampleMailClie") == nil)
    #expect(t.row(forProcessName: "ExamplePhotos")?.company == "Example Corp")
}

@Test func unjoinedStaysUnjoined() throws {
    let t = try table(sample)
    let rate = t.joinRate(bundleIds: ["com.example.photos", "com.unknown.thing", "net.nobody.app"])
    #expect(rate.joined == 1 && rate.total == 3)
    #expect(rate.notJoined == ["com.unknown.thing", "net.nobody.app"])
    #expect(t.company(for: "mystery") == nil)
}

@Test func joinRateIsExactOnSyntheticReport() throws {
    let t = try table(sample)
    // duplicates count once; one prefix join, one exact join, two misses
    let ids = ["com.example.photos", "com.example.photos", "com.example.suite.calendar", "com.x.y", "com.x.z", "com.x.y"]
    let rate = t.joinRate(bundleIds: ids)
    #expect(rate.joined == 2 && rate.total == 4)
    #expect(rate.rate == 0.5)
    #expect(t.joinRate(bundleIds: [String]()).total == 0)
    let names = t.joinRate(processNames: ["ExamplePhotos", "ExampleMailClien", "launchd", "launchd"])
    #expect(names.joined == 2 && names.total == 3 && names.notJoined == ["launchd"])
}

@Test func relationIsUnknownWhenAppCompanyUnknown() {
    #expect(AppTable.relation(appCompany: nil, labelParent: "Alphabet") == .unknown)
    #expect(AppTable.relation(appCompany: "", labelParent: "Alphabet") == .unknown)
    // a label with no parent says nothing about sameness
    #expect(AppTable.relation(appCompany: "Alphabet", labelParent: nil) == .unknown)
}

@Test func relationSameCompanyWhenParentsEqual() {
    #expect(AppTable.relation(appCompany: "Alphabet", labelParent: "Alphabet") == .sameCompanyAsApp)
    #expect(AppTable.relation(appCompany: "Alphabet", labelParent: "alphabet") == .sameCompanyAsApp)
    #expect(AppTable.relation(appCompany: "Alphabet", labelParent: "Meta Platforms") == .other)
    // whole text only: a longer name is another company
    #expect(AppTable.relation(appCompany: "Meta", labelParent: "Meta Platforms") == .other)
}

@Test func labelRelationFollowsTheApp() {
    let classifier = CompanyClassifier()
    let label = classifier.classify(hostname: "securepubads.g.doubleclick.net")
    #expect(label.relation == .unknown)
    #expect(label.relative(toAppCompany: "Alphabet").relation == .sameCompanyAsApp)
    #expect(label.relative(toAppCompany: "Netflix").relation == .other)
    #expect(label.relative(toAppCompany: nil).relation == .unknown)
    // a name no source knows has no parent: unknown, never "other"
    #expect(classifier.classify(hostname: "unknown.example").relative(toAppCompany: "Alphabet").relation == .unknown)
}

@Test func duplicateBundleIdFailsLoad() {
    #expect(throws: AppTableError.duplicateBundleId(line: 3)) {
        try table("com.example.a\tA\t\tX\tn\ncom.example.a\tB\t\tY\tn\n")
    }
    // case does not make a different id
    #expect(throws: AppTableError.duplicateBundleId(line: 3)) {
        try table("com.example.a\tA\t\tX\tn\ncom.Example.A\tB\t\tY\tn\n")
    }
    // the same process name on two rows, also through the cut form
    #expect(throws: AppTableError.duplicateProcessName(line: 3)) {
        try table("com.example.a\tA\tSameName\tX\tn\ncom.example.b\tB\tSameName\tY\tn\n")
    }
    #expect(throws: AppTableError.duplicateProcessName(line: 3)) {
        try table("com.example.a\tA\tABCDEFGHIJKLMNOPQ\tX\tn\ncom.example.b\tB\tABCDEFGHIJKLMNOP\tY\tn\n")
    }
}

@Test func badRowsFailLoad() {
    #expect(throws: AppTableError.missingHeader) { try AppTable(parsing: "a\tb\n") }
    #expect(throws: AppTableError.wrongColumnCount(line: 2)) { try table("com.example.a\tA\tX\n") }
    #expect(throws: AppTableError.emptyField(line: 2)) { try table("com.example.a\t\t\tX\tn\n") }
    #expect(throws: AppTableError.emptyField(line: 2)) { try table("com.example.a\tA\t\t\tn\n") }
    #expect(throws: AppTableError.badBundleId(line: 2)) { try table("example\tA\t\tX\tn\n") }
    #expect(throws: AppTableError.badBundleId(line: 2)) { try table("com.example.a b\tA\t\tX\tn\n") }
    #expect(throws: AppTableError.badBundleId(line: 2)) { try table("com..a\tA\t\tX\tn\n") }
}

// MARK: the bundled table

@Test func bundledTableMatchesManifest() throws {
    let manifest = try DatasetManifest.load()
    let entry = try #require(manifest.datasets.first { $0.file == "apps.tsv" })
    let url = try #require(DatasetManifest.resourceURL("apps.tsv"))
    let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    #expect(hash == entry.sha256)
    let t = try AppTable.loadBundled()
    #expect(t.count == entry.rules)
    #expect(t.version == entry.version && t.sha256 == entry.sha256)
    #expect(t.count > 50)
}

@Test func bundledCompaniesAreCuratedParents() throws {
    let parents = Set(CuratedList.bundled.entries.map(\.parent))
    for row in AppTable.bundled.rows {
        #expect(parents.contains(row.company), "\(row.bundleId): company is not a parent of the curated list")
        #expect(!row.note.isEmpty)
    }
}

@Test func bundledRealAppsJoin() {
    let t = AppTable.bundled
    #expect(t.company(forBundleId: "com.google.ios.youtube") == "Alphabet")
    #expect(t.company(forBundleId: "com.burbn.instagram") == "Meta Platforms")
    #expect(t.company(forBundleId: "net.whatsapp.WhatsApp") == "Meta Platforms")
    #expect(t.company(forBundleId: "com.apple.mobilesafari") == "Apple")
    // a prefix covers an app the table has no exact row for
    #expect(t.company(forBundleId: "com.apple.example.unlisted") == "Apple")
    // process names join the same rows: the full name and the cut form
    #expect(t.company(for: "YouTube") == "Alphabet")
    #expect(t.row(forProcessName: "MobileSafari")?.bundleId == "com.apple.mobilesafari")
    #expect(t.row(forProcessName: "MobileSafari")?.displayName == "Safari")
    // similar text does not join
    #expect(t.row(forBundleId: "com.example.youtube") == nil)
    #expect(t.row(forBundleId: "com.example.ios.youtube") == nil)
}

@Test func bundledRowsAreWellFormed() {
    for row in AppTable.bundled.rows {
        for name in row.processNames { #expect(!name.contains("\t") && !name.isEmpty) }
        #expect(row.bundleId == row.bundleId.trimmingCharacters(in: .whitespaces))
    }
}
