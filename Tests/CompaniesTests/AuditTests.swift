import Foundation
import Testing
import Companies

// made-up domains, made-up companies and made-up references only. plain import (no @testable)

private let aliases = ReferenceAliases(pairs: [
    (name: "Zorblax Worldwide Ltd", parent: "Zorblax Holdings"),
    (name: "Quillnet Edge Inc", parent: "Quillnet"),
])

private func subject(_ domain: String, _ parent: String, company: String? = nil) -> AuditSubject {
    AuditSubject(domain: domain, parent: parent, company: company, category: .advertising)
}

private func entity(_ name: String, _ others: [String] = []) -> EntityEntry { EntityEntry(entity: name, names: [name] + others) }

@Test func entityMapAgreementConfirms() {
    let refs = ReferenceMaps(entities: ["zorblax.com": entity("Zorblax Holdings, Inc.")])
    let row = Audit.score(subject("zorblax.com", "Zorblax Holdings"), references: refs, aliases: aliases)
    #expect(row.entity == .agrees)
    #expect(row.outcome == .confirmed)
}

@Test func aliasNormalisationMapsReferenceNamesToOurParent() {
    // the reference says "Zorblax Worldwide Ltd"; only the alias row makes it our parent
    let refs = ReferenceMaps(entities: ["zorblax.com": entity("Zorblax Worldwide Ltd")])
    let s = subject("zorblax.com", "Zorblax Holdings")
    #expect(Audit.score(s, references: refs, aliases: aliases).outcome == .confirmed)
    #expect(Audit.score(s, references: refs, aliases: ReferenceAliases()).outcome == .contradicted)
}

@Test func normalisationIgnoresCaseAndPunctuationAndLegalWords() {
    #expect(Audit.normalise("Quillnet, Inc.") == Audit.normalise("QUILLNET"))
    #expect(Audit.normalise("The Mumble & Bee Co.") == Audit.normalise("mumble and bee"))
    #expect(Audit.normalise("Inc") == "inc")
    #expect(Audit.normalise("Quillnet") != Audit.normalise("Quillnet Labs"))
}

@Test func anyOfTheEntitysOtherNamesCanAgree() {
    let refs = ReferenceMaps(entities: ["pipwick.com": entity("Pipwick Group GmbH", ["Pipwick", "Pip Wick Labs"])])
    #expect(Audit.score(subject("pipwick.com", "Pipwick"), references: refs, aliases: aliases).outcome == .confirmed)
}

@Test func differentEntityIsContradicted() {
    let refs = ReferenceMaps(entities: ["frobnitz.net": entity("Wexford Systems Corp")])
    let row = Audit.score(subject("frobnitz.net", "Frobnitz"), references: refs, aliases: aliases)
    #expect(row.outcome == .contradicted)
    #expect(row.entityName == "Wexford Systems Corp")
}

@Test func referenceIsFoundByTheDomainOrAParentOfIt() {
    let refs = ReferenceMaps(entities: ["quillnet.com": entity("Quillnet")])
    #expect(Audit.score(subject("cdn.quillnet.com", "Quillnet"), references: refs, aliases: aliases).entity == .agrees)
}

@Test func noOrganisationIsUnverifiableNotContradicted() {
    let refs = ReferenceMaps(certificates: ["mumblebee.io": .noOrganisation, "pipwick.com": .failed])
    for domain in ["mumblebee.io", "pipwick.com", "absent.example"] {
        let row = Audit.score(subject(domain, "Mumblebee"), references: refs, aliases: aliases)
        #expect(row.certificate == .noAnswer)
        #expect(row.outcome == .unverifiable)
    }
}

@Test func certificateOrganisationScores() {
    let refs = ReferenceMaps(certificates: ["quillnet.com": .organisation("Quillnet Edge Inc"), "frobnitz.net": .organisation("Someone Else LLC")])
    #expect(Audit.score(subject("quillnet.com", "Quillnet"), references: refs, aliases: aliases).outcome == .confirmed)
    let other = Audit.score(subject("frobnitz.net", "Frobnitz"), references: refs, aliases: aliases)
    #expect(other.outcome == .contradicted)
    #expect(other.organisation == "Someone Else LLC")
}

@Test func oneAgreeingReferenceConfirmsEvenWhenTheOtherDiffers() {
    let refs = ReferenceMaps(
        entities: ["zorblax.com": entity("Zorblax Holdings")], certificates: ["zorblax.com": .organisation("A Hosting Company")])
    let row = Audit.score(subject("zorblax.com", "Zorblax Holdings"), references: refs, aliases: aliases)
    #expect(row.outcome == .confirmed)
    let s = Audit.summarise(name: "x", rows: [row])
    #expect(s.confirmedByEntityOnly == 1 && s.confirmedWhileOtherDiffers == 1)
}

@Test func strataCountAndBound() throws {
    let refs = ReferenceMaps(
        entities: ["a.test": entity("Aco"), "b.test": entity("Bco"), "c.test": entity("Other Company")],
        certificates: ["b.test": .organisation("Bco Inc")])
    let subjects = [subject("a.test", "Aco"), subject("b.test", "Bco"), subject("c.test", "Cco"), subject("d.test", "Dco"), subject("a.test", "Aco")]
    let s = Audit.summarise(name: "made up", rows: Audit.rows(subjects, references: refs, aliases: aliases))
    #expect(s.n == 4)  // the duplicate counts once
    #expect(s.confirmed == 2 && s.confirmedByBoth == 1 && s.confirmedByEntityOnly == 1)
    #expect(s.contradicted == 1 && s.unverifiable == 1)
    #expect(s.verifiable == 3)
    #expect(s.upperBound == Audit.upperBound(failures: 1, of: 3))
    let rate = try #require(s.agreementRate)
    #expect(abs(rate - 2.0 / 3.0) < 1e-12)
}

@Test func nothingVerifiableHasNoBound() {
    let s = Audit.summarise(name: "none", rows: Audit.rows([subject("a.test", "Aco")], references: ReferenceMaps(), aliases: aliases))
    #expect(s.unverifiable == 1 && s.upperBound == nil && s.agreementRate == nil)
}

@Test func boundMatchesKnownValues() {
    // exact one-sided 95% Clopper-Pearson upper limits, computed independently
    #expect(abs(Audit.upperBound(failures: 0, of: 200) - 0.014867) < 1e-5)
    #expect(abs(Audit.upperBound(failures: 0, of: 50) - 0.058155) < 1e-5)
    #expect(abs(Audit.upperBound(failures: 1, of: 10) - 0.394163) < 1e-5)
    #expect(abs(Audit.upperBound(failures: 2, of: 20) - 0.282619) < 1e-5)
    #expect(abs(Audit.upperBound(failures: 3, of: 100) - 0.075711) < 1e-5)
    #expect(abs(Audit.upperBound(failures: 5, of: 200) - 0.051843) < 1e-5)
}

@Test func boundIsMonotoneInFailuresAndIsOneWhenAllFail() {
    var last = 0.0
    for k in 0...40 {
        let b = Audit.upperBound(failures: k, of: 40)
        #expect(b > last || k == 40)
        last = b
    }
    #expect(Audit.upperBound(failures: 40, of: 40) == 1)
    #expect(Audit.upperBound(failures: 3, of: 400) < Audit.upperBound(failures: 3, of: 40))
}

@Test func certificateCacheParsing() {
    let text = "a.test\torg\tAco Inc\nb.test\tnone\nc.test\tfail\nd.test\torg\t\nbad line\ne.test\tmaybe\n"
    let map = ReferenceMaps.parseCertificateCache(text)
    #expect(map["a.test"] == .organisation("Aco Inc"))
    #expect(map["b.test"] == .noOrganisation)
    #expect(map["c.test"] == .failed)
    #expect(map["d.test"] == nil && map["e.test"] == nil && map.count == 3)
}

@Test func entityMapParsing() throws {
    let json = """
        {"a.test": {"entityName": "Aco, Inc.", "aliases": ["Aco, Inc.", "Aco Labs"], "displayName": "Aco"},
         "b.test": {"nothing": 1}}
        """
    let map = try ReferenceMaps.parseEntityMap(Data(json.utf8))
    #expect(map.count == 1)
    #expect(map["a.test"]?.entity == "Aco, Inc.")
    #expect(map["a.test"]?.names.contains("Aco Labs") == true)
}

@Test func aliasTableParsingIsStrict() throws {
    let ok = try ReferenceAliases(parsing: "referenceName\tparent\tnote\nZorblax Worldwide Ltd\tZorblax Holdings\tn\n")
    #expect(ok.parent(forReferenceName: "zorblax worldwide") == "Zorblax Holdings")
    #expect(throws: ReferenceAliasError.missingHeader) { try ReferenceAliases(parsing: "a\tb\n") }
    #expect(throws: ReferenceAliasError.wrongColumnCount(line: 2)) { try ReferenceAliases(parsing: "referenceName\tparent\tnote\nx\ty\n") }
}

@Test func bundledReferenceAliasesMatchTheManifestAndOurParents() throws {
    let manifest = try DatasetManifest.load()
    let entry = try #require(manifest.datasets.first { $0.file == "reference-aliases.tsv" })
    let url = try #require(DatasetManifest.resourceURL("reference-aliases.tsv"))
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(entry.rules == text.split(separator: "\n").count - 1)
    // every alias stands for a parent the curated list really uses
    let parents = Set(CuratedList.bundled.entries.map(\.parent))
    for line in text.split(separator: "\n").dropFirst() {
        let parent = String(line.split(separator: "\t", omittingEmptySubsequences: false)[1])
        #expect(parents.contains(parent))
    }
    #expect(ReferenceAliases.loadBundled().parent(forReferenceName: "Google LLC") == "Alphabet")
}

@Test func contradictionLinesHoldOnlyContradictedRowsOnce() {
    let refs = ReferenceMaps(
        entities: ["c.test": entity("Other Company"), "a.test": entity("Aco")], certificates: ["c.test": .organisation("Third Co")])
    let rows = Audit.rows([subject("c.test", "Cco"), subject("a.test", "Aco"), subject("z.test", "Zco")], references: refs, aliases: aliases)
    let lines = Audit.contradictionLines(rows)
    #expect(lines.count == 2)
    #expect(lines[1] == "c.test\tCco (advertising)\tOther Company\tThird Co")
}

@Test func reportHasNumbersOnly() {
    let refs = ReferenceMaps(entities: ["zorblax.com": entity("Wexford Systems Corp")])
    let rows = Audit.rows([subject("zorblax.com", "Zorblax Holdings")], references: refs, aliases: aliases)
    let text = Audit.report([Audit.summarise(name: "captures", rows: rows)])
    #expect(!text.contains("zorblax") && !text.contains("Zorblax") && !text.contains("Wexford"))
    #expect(text.contains("contradicted: 1"))
    #expect(text.contains("upper bound"))
}

@Test func curatedRowsSharingADomainAndParentCountOnce() {
    let refs = ReferenceMaps(entities: ["zorblax.com": entity("Zorblax Holdings")])
    let a = AuditSubject(domain: "zorblax.com", parent: "Zorblax Holdings", company: nil, category: .advertising)
    let b = AuditSubject(domain: "Zorblax.com", parent: "Zorblax Holdings, Inc.", company: "Zorblax Ads", category: .analytics)
    let c = AuditSubject(domain: "zorblax.com", parent: "Other Parent", company: nil, category: .advertising)
    let rows = Audit.rows([a, b, c], references: refs, aliases: aliases)
    #expect(rows.count == 2)  // a and b merge; a different parent is a different subject
    let merged = rows.first { $0.subject.parent == "Zorblax Holdings" }
    #expect(merged?.subject.category == .advertising)  // the first category is kept
    #expect(merged?.subject.company == "Zorblax Ads")  // a missing company name is filled in
}
