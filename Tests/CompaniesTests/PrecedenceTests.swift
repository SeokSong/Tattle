import CryptoKit
import Foundation
import Testing
import Companies

// plain import (no @testable) so these also run under `swift test -c release`

private let header = "field\torder\texception\tnote\n"
private let ownerRow = "owner\tcurated,appleOwner\tskip:appleOwner:cdnOperator\tn\n"
private let categoryRow = "category\tcurated\tnone\tn\n"

@Test func bundledPrecedenceMatchesManifest() throws {
    let manifest = try DatasetManifest.load()
    for file in ["precedence.tsv", "apple-owner-aliases.tsv"] {
        let entry = try #require(manifest.datasets.first { $0.file == file })
        let url = try #require(DatasetManifest.resourceURL(file))
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        #expect(hash == entry.sha256)
    }
    let table = try PrecedenceTable.loadBundled()
    #expect(table.version == manifest.datasets.first { $0.file == "precedence.tsv" }?.version)
    #expect(table.rows.count == manifest.datasets.first { $0.file == "precedence.tsv" }?.rules)
    let aliases = try AppleOwnerTable.loadBundled()
    #expect(aliases.count == manifest.datasets.first { $0.file == "apple-owner-aliases.tsv" }?.rules)
}

@Test func bundledOrderIsCuratedThenAppleThenTracker() {
    let table = PrecedenceTable.bundled
    #expect(table.order(for: .owner) == [.curated, .appleOwner, .trackerList])
    #expect(table.row(for: .owner).exceptions == [PrecedenceException(skip: .appleOwner, when: .cdnOperator)])
    #expect(table.order(for: .category) == [.curated, .trackerList])
    #expect(CompanyClassifier.provisionalOrder == [.curated, .appleOwner, .trackerList])
}

@Test func bundledAliasesPointAtCuratedParents() {
    let parents = Set(CuratedList.bundled.entries.map(\.parent))
    let aliases = AppleOwnerTable.bundled
    #expect(aliases.count > 20)
    for row in aliases.rows {
        #expect(parents.contains(row.parent), "alias row: parent is not a parent of the curated list")
        #expect(!row.note.isEmpty)
    }
    #expect(aliases.aliasedParent(forOwner: "Google LLC") == "Alphabet")
    #expect(aliases.isCDNOperator("Akamai Technologies, Inc."))
    #expect(!aliases.isCDNOperator("Google LLC"))
}

@Test func unknownFieldInTableFailsLoad() {
    #expect(throws: PrecedenceError.unknownField(line: 2)) {
        try PrecedenceTable(parsing: header + "colour\tcurated\tnone\tn\n")
    }
    #expect(throws: PrecedenceError.unknownSource(line: 2)) {
        try PrecedenceTable(parsing: header + "owner\tcurated,guess\tnone\tn\n")
    }
    #expect(throws: PrecedenceError.unknownSource(line: 2)) {
        try PrecedenceTable(parsing: header + "owner\tcurated,curated\tnone\tn\n")
    }
    #expect(throws: PrecedenceError.unknownSource(line: 2)) {
        try PrecedenceTable(parsing: header + "owner\tnone\tnone\tn\n")
    }
    #expect(throws: PrecedenceError.unknownException(line: 2)) {
        try PrecedenceTable(parsing: header + "owner\tcurated,appleOwner\tskip:appleOwner:rich\tn\n" + categoryRow)
    }
    #expect(throws: PrecedenceError.exceptionSourceNotInOrder(line: 2)) {
        try PrecedenceTable(parsing: header + "owner\tcurated\tskip:appleOwner:cdnOperator\tn\n" + categoryRow)
    }
    #expect(throws: PrecedenceError.duplicateField(line: 3)) {
        try PrecedenceTable(parsing: header + ownerRow + ownerRow)
    }
    #expect(throws: PrecedenceError.missingField(field: "category")) { try PrecedenceTable(parsing: header + ownerRow) }
    #expect(throws: PrecedenceError.missingHeader) { try PrecedenceTable(parsing: "a\tb\n") }
    #expect(throws: PrecedenceError.wrongColumnCount(line: 2)) { try PrecedenceTable(parsing: header + "owner\tcurated\n") }
    #expect(throws: PrecedenceError.emptyField(line: 2)) { try PrecedenceTable(parsing: header + "owner\t\tnone\tn\n") }
}

@Test func categoryRowCannotListAppleOwner() {
    // Apple gives an owner and never a category: a table that asks it for one does not load
    #expect(throws: PrecedenceError.sourceCannotAnswer(line: 3)) {
        try PrecedenceTable(parsing: header + ownerRow + "category\tcurated,appleOwner\tnone\tn\n")
    }
}

@Test func badAppleOwnerRowsFailLoad() {
    let h = "appleOwner\tkind\tparent\tnote\n"
    #expect(throws: AppleOwnerTableError.missingHeader) { try AppleOwnerTable(parsing: "x\n") }
    #expect(throws: AppleOwnerTableError.unknownKind(line: 2)) { try AppleOwnerTable(parsing: h + "A Corp\tmaybe\tA\tn\n") }
    #expect(throws: AppleOwnerTableError.emptyField(line: 2)) { try AppleOwnerTable(parsing: h + "A Corp\talias\t\tn\n") }
    #expect(throws: AppleOwnerTableError.wrongColumnCount(line: 2)) { try AppleOwnerTable(parsing: h + "A Corp\talias\n") }
    #expect(throws: AppleOwnerTableError.duplicateOwner(line: 3)) {
        try AppleOwnerTable(parsing: h + "A Corp\talias\tA\tn\n" + "a   CORP\tcdn\tA\tn\n")
    }
}

@Test func ownerMatchingIgnoresCaseAndSpacingOnly() throws {
    let t = try AppleOwnerTable(parsing: "appleOwner\tkind\tparent\tnote\nQuill Net Inc\tcdn\tQuillnet\tn\n")
    #expect(t.isCDNOperator("  quill   NET inc "))
    // no fuzzy matching: a different spelling is a different owner
    #expect(!t.isCDNOperator("Quill Net"))
    #expect(!t.isCDNOperator("Quill Net Inc."))
    #expect(t.comparableParent(forOwner: "Other Co ") == "Other Co")
}

@Test func orderIsADataEdit() throws {
    let curated = try CuratedList(parsing: "domain\tcompany\tparent\tcategory\tnote\nzorblax.com\tZorblax\tZorblax Holdings\tadvertising\tn\n")
    let aliases = try AppleOwnerTable(parsing: "appleOwner\tkind\tparent\tnote\n")
    let flipped = try PrecedenceTable(parsing: header + "owner\tappleOwner,curated\tnone\tn\n" + categoryRow)
    let c = CompanyClassifier(curated: curated, precedence: flipped, appleOwners: aliases, trackers: .empty)
    let label = c.classify(hostname: "zorblax.com", appleOwner: "Somebody Ltd")
    #expect(label.source == .appleOwner && label.company == "Somebody Ltd")
    // the category still comes from the list, not from Apple
    #expect(label.category == .advertising)
    // and the same names with the bundled order give the curated answer
    let normal = CompanyClassifier(curated: curated, appleOwners: aliases, trackers: .empty)
    #expect(normal.classify(hostname: "zorblax.com", appleOwner: "Somebody Ltd").source == .curated)
}

@Test func categoryComesFromListNotApple() throws {
    let curated = try CuratedList(parsing: "domain\tcompany\tparent\tcategory\tnote\nzorblax.com\tZorblax\tZorblax Holdings\tadvertising\tn\n")
    let aliases = try AppleOwnerTable(parsing: "appleOwner\tkind\tparent\tnote\nZorblax Holdings Ltd\talias\tZorblax Holdings\tn\n")
    let c = CompanyClassifier(curated: curated, appleOwners: aliases, trackers: .empty)
    // Apple alone never gives a category, even for an owner that aliases to a curated parent
    let apple = c.classify(hostname: "unlisted.test", appleOwner: "Zorblax Holdings Ltd")
    #expect(apple.source == .appleOwner && apple.category == .unclassified && apple.parent == nil)
    #expect(c.label(hostname: "unlisted.test", from: .appleOwner, appleOwner: "Zorblax Holdings Ltd").category == .unclassified)
    #expect(c.resolve(hostname: "unlisted.test", appleOwner: "Zorblax Holdings Ltd").categorySource == .none)
    // a listed name keeps the list's category whatever Apple says
    let listed = c.resolve(hostname: "zorblax.com", appleOwner: "Zorblax Holdings Ltd")
    #expect(listed.label.category == .advertising && listed.categorySource == .curated)
}

@Test func exceptionSkipsCDNOwner() throws {
    let curated = try CuratedList(parsing: "domain\tcompany\tparent\tcategory\tnote\nzorblax.com\tZorblax\tZorblax Holdings\tadvertising\tn\n")
    let aliases = try AppleOwnerTable(parsing: "appleOwner\tkind\tparent\tnote\nQuillnet Edge Inc\tcdn\tQuillnet\tn\nWexford Corp\talias\tWexford\tn\n")
    let c = CompanyClassifier(curated: curated, appleOwners: aliases, trackers: .empty)
    let skipped = c.resolve(hostname: "customer-site.test", appleOwner: "Quillnet Edge Inc")
    #expect(skipped.label.source == .none && skipped.label.company == nil)
    #expect(skipped.skipped == [SkippedSource(source: .appleOwner, condition: .cdnOperator)])
    // an ordinary owner is not skipped
    let kept = c.resolve(hostname: "customer-site.test", appleOwner: "Wexford Corp")
    #expect(kept.label.source == .appleOwner && kept.skipped.isEmpty)
    // the exception sets the answer aside; asking the source alone still returns it (the matrix needs that)
    #expect(c.label(hostname: "customer-site.test", from: .appleOwner, appleOwner: "Quillnet Edge Inc").isMatched)
    // a curated answer is never skipped
    #expect(c.resolve(hostname: "zorblax.com", appleOwner: "Quillnet Edge Inc").skipped.isEmpty)
}

@Test func capturePathNeverSeesApple() throws {
    // without an owner string (every capture flow) Apple plays no part
    let c = CompanyClassifier()
    #expect(c.resolve(hostname: "unlisted-made-up-name.test").label.source == .none)
    #expect(c.classify(hostname: "unlisted-made-up-name.test", appleOwner: nil).source == .none)
}

// MARK: agreement matrix

private func syntheticClassifier() throws -> CompanyClassifier {
    let curated = try CuratedList(parsing: """
        domain\tcompany\tparent\tcategory\tnote
        zorblax.com\tZorblax\tZorblax Holdings\tadvertising\tn
        mumblebee.io\tMumblebee\tMumblebee\tanalytics\tn
        pipwick.com\tPipwick\tPipwick\tsocial\tn
        frobnitz.net\tFrobnitz\tFrobnitz\tonlineService\tn

        """)
    let aliases = try AppleOwnerTable(parsing: """
        appleOwner\tkind\tparent\tnote
        Zorblax Holdings Ltd\talias\tZorblax Holdings\tn
        Quillnet Edge Inc\tcdn\tQuillnet\tn

        """)
    return CompanyClassifier(curated: curated, appleOwners: aliases, trackers: .empty)
}

private let observations: [(domain: String, appleOwner: String?)] = [
    ("zorblax.com", "Zorblax Holdings Ltd"),      // same, through an alias
    ("mumblebee.io", "mumblebee"),                  // same, no alias needed
    ("pipwick.com", "Somebody Else LLC"),           // different
    ("frobnitz.net", "Quillnet Edge Inc"),          // different, owner is a CDN operator
    ("only-curated.test", nil),                     // placeholder replaced below
    ("only-apple.test", "Wexford Corp"),            // only Apple
    ("cdn-customer.test", "Quillnet Edge Inc"),     // only Apple, CDN owner
    ("nobody.test", nil),                           // neither
    ("203.0.113.7", "Wexford Corp"),                // IP address: excluded
    ("2001:db8::1", nil),                           // IP address: excluded
]

@Test func matrixCountsAreSymmetricWhereExpected() throws {
    let c = try syntheticClassifier()
    var obs = observations
    obs[4] = ("ads.zorblax.com", nil)               // only curated
    let (m, rows) = Agreement.measure(obs, classifier: c)
    #expect(m.domains == 8 && m.ipAddresses == 2)
    #expect(m.onlyFirst == 1 && m.onlySecond == 2 && m.bothSame == 2 && m.bothDifferent == 2 && m.neither == 1)
    #expect(m.onlyFirst + m.onlySecond + m.bothSame + m.bothDifferent + m.neither == m.domains)
    #expect(m.sameThroughAlias == 1)
    #expect(m.differentCDNOwner == 1 && m.onlySecondCDNOwner == 1)
    // every disagreement and every name only Apple named has a local row; nothing else does
    #expect(rows.count == m.bothDifferent + m.onlySecond)
    // asking from the other side swaps the two one-sided counts and nothing else
    let other = Agreement.measure(obs, classifier: c, first: .appleOwner, second: .curated).matrix
    #expect(other.onlyFirst == m.onlySecond && other.onlySecond == m.onlyFirst)
    #expect(other.bothSame == m.bothSame && other.bothDifferent == m.bothDifferent && other.neither == m.neither)
    #expect(other.domains == m.domains && other.ipAddresses == m.ipAddresses)
    #expect(m.swapped.onlyFirst == other.onlyFirst && m.swapped.bothSame == other.bothSame)
}

@Test func matrixTextHasNumbersOnly() throws {
    let c = try syntheticClassifier()
    let (m, _) = Agreement.measure(observations, classifier: c)
    let text = m.text()
    for name in ["zorblax", "mumblebee", "pipwick", "frobnitz", "wexford", "quillnet"] {
        #expect(!text.lowercased().contains(name))
    }
    #expect(text.contains("IP addresses excluded: 2"))
}
