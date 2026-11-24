import Foundation
import Testing
import Companies

// the golden synthetic conflict set: made-up names and made-up source answers (curated, Apple owner and AdGuard rows), committed. every case says who
// must win and by which rule. changing the precedence table is a data edit and changes some of these on purpose

private let curatedText = """
    domain\tcompany\tparent\tcategory\tnote
    zorblax.com\tZorblax Ads\tZorblax Holdings\tadvertising\tn
    zorblax-cdn.com\tZorblax Delivery\tZorblax Holdings\tcontentDelivery\tn
    quillnet.com\tQuillnet\tQuillnet\tcontentDelivery\tn
    mumblebee.io\tMumblebee\tMumblebee\tanalytics\tn
    pipwick.com\tPipwick\tPipwick\tsocial\tn
    api.pipwick.com\tPipwick API\tPipwick\tcloudService\tn
    frobnitz.net\tFrobnitz\tFrobnitz\tonlineService\tn

    """

private let aliasText = """
    appleOwner\tkind\tparent\tnote
    Zorblax Holdings Ltd\talias\tZorblax Holdings\tn
    Quillnet Edge Inc\tcdn\tQuillnet\tn
    Mumblebee Labs, Inc.\talias\tMumblebee\tn
    Wexford Systems Corp\talias\tWexford\tn

    """

private let trackerMapText = "adguardCategory\tcategory\tnote\nads\tadvertising\tn\nstats\tanalytics\tn\nmisc\tunclassified\tn\n"
private let trackerAliasText = "adguardCompany\tparent\tnote\nZorblax Holdings Inc.\tZorblax Holdings\tn\n"
private let trackerText = "domain\tcompany\tadguardCategory\n"
    + "apple-and-tracker.test\tWexford Trackers\tads\n"
    + "quillnet-edge-only.test\tQuillnet Edge Trackers\tstats\n"
    + "trk-only.test\tBlinkerly\tads\n"
    + "zorblax.com\tZorblax Holdings Inc.\tstats\n"
    + "zz-nocompany.test\t\tads\n"

private struct Case {
    let name: String
    let host: String
    let owner: String?
    let source: LabelSource
    let company: String?
    let parent: String?
    let category: CompanyCategory
    let rule: LabelRule
    var skipped = false
}

private let cases: [Case] = [
    Case(name: "curated registrable, no owner", host: "zorblax.com", owner: nil, source: .curated, company: "Zorblax Ads", parent: "Zorblax Holdings", category: .advertising, rule: .curatedRegistrable),
    Case(name: "curated by subdomain", host: "ads.zorblax.com", owner: nil, source: .curated, company: "Zorblax Ads", parent: "Zorblax Holdings", category: .advertising, rule: .curatedRegistrable),
    Case(name: "curated beats an agreeing owner", host: "zorblax.com", owner: "Zorblax Holdings Ltd", source: .curated, company: "Zorblax Ads", parent: "Zorblax Holdings", category: .advertising, rule: .curatedRegistrable),
    Case(name: "curated beats a disagreeing owner", host: "zorblax.com", owner: "Somebody Else LLC", source: .curated, company: "Zorblax Ads", parent: "Zorblax Holdings", category: .advertising, rule: .curatedRegistrable),
    Case(name: "curated with a blank owner", host: "zorblax.com", owner: "   ", source: .curated, company: "Zorblax Ads", parent: "Zorblax Holdings", category: .advertising, rule: .curatedRegistrable),
    Case(name: "hostname row beats registrable row", host: "api.pipwick.com", owner: "Pipwick Inc", source: .curated, company: "Pipwick API", parent: "Pipwick", category: .cloudService, rule: .curatedHostname),
    Case(name: "registrable row for another host", host: "www.pipwick.com", owner: "Other Co", source: .curated, company: "Pipwick", parent: "Pipwick", category: .social, rule: .curatedRegistrable),
    Case(name: "curated beats a CDN owner", host: "frobnitz.net", owner: "Quillnet Edge Inc", source: .curated, company: "Frobnitz", parent: "Frobnitz", category: .onlineService, rule: .curatedRegistrable),
    Case(name: "curated delivery name with a CDN owner", host: "zorblax-cdn.com", owner: "Quillnet Edge Inc", source: .curated, company: "Zorblax Delivery", parent: "Zorblax Holdings", category: .contentDelivery, rule: .curatedRegistrable),
    Case(name: "curated CDN company with its own owner", host: "quillnet.com", owner: "Quillnet Edge Inc", source: .curated, company: "Quillnet", parent: "Quillnet", category: .contentDelivery, rule: .curatedRegistrable),
    Case(name: "mixed case and trailing dot", host: "UPPER.Zorblax.COM.", owner: nil, source: .curated, company: "Zorblax Ads", parent: "Zorblax Holdings", category: .advertising, rule: .curatedRegistrable),
    Case(name: "curated analytics beats an alias owner", host: "mumblebee.io", owner: "Mumblebee Labs, Inc.", source: .curated, company: "Mumblebee", parent: "Mumblebee", category: .analytics, rule: .curatedRegistrable),
    Case(name: "Apple fills a name the list lacks", host: "unlisted-a.test", owner: "Wexford Systems Corp", source: .appleOwner, company: "Wexford Systems Corp", parent: nil, category: .unclassified, rule: .appleOwner),
    Case(name: "Apple owner is kept as written", host: "deep.sub.unlisted-b.org", owner: "Some Unlisted Ltd", source: .appleOwner, company: "Some Unlisted Ltd", parent: nil, category: .unclassified, rule: .appleOwner),
    Case(name: "alias owner gives no category", host: "unlisted-c.net", owner: "Zorblax Holdings Ltd", source: .appleOwner, company: "Zorblax Holdings Ltd", parent: nil, category: .unclassified, rule: .appleOwner),
    Case(name: "alias owner of an analytics parent gives no category", host: "unlisted-d.net", owner: "Mumblebee Labs, Inc.", source: .appleOwner, company: "Mumblebee Labs, Inc.", parent: nil, category: .unclassified, rule: .appleOwner),
    Case(name: "unlisted name under a listed suffix text", host: "zorblax.com.unlisted-e.test", owner: "Wexford Systems Corp", source: .appleOwner, company: "Wexford Systems Corp", parent: nil, category: .unclassified, rule: .appleOwner),
    Case(name: "CDN owner skipped", host: "unlisted-f.com", owner: "Quillnet Edge Inc", source: .none, company: nil, parent: nil, category: .unclassified, rule: .noMatch, skipped: true),
    Case(name: "CDN owner skipped, case and spacing", host: "unlisted-f.com", owner: "  quillnet   EDGE inc ", source: .none, company: nil, parent: nil, category: .unclassified, rule: .noMatch, skipped: true),
    Case(name: "near-miss CDN spelling is not skipped", host: "unlisted-g.com", owner: "Quillnet Edge Inc.", source: .appleOwner, company: "Quillnet Edge Inc.", parent: nil, category: .unclassified, rule: .appleOwner),
    Case(name: "no source, no owner", host: "unlisted-h.test", owner: nil, source: .none, company: nil, parent: nil, category: .unclassified, rule: .noMatch),
    Case(name: "no source, blank owner", host: "unlisted-h.test", owner: "", source: .none, company: nil, parent: nil, category: .unclassified, rule: .noMatch),
    Case(name: "no substring match on a list name", host: "notzorblax.com", owner: nil, source: .none, company: nil, parent: nil, category: .unclassified, rule: .noMatch),
    Case(name: "list name inside another name", host: "zorblax.com.example.test", owner: nil, source: .none, company: nil, parent: nil, category: .unclassified, rule: .noMatch),
    Case(name: "hostname row only below its own name", host: "pipwick.com.au", owner: "Pipwick Pty", source: .appleOwner, company: "Pipwick Pty", parent: nil, category: .unclassified, rule: .appleOwner),
    Case(name: "AdGuard fills a name curated and Apple lack", host: "trk-only.test", owner: nil, source: .trackerList, company: "Blinkerly", parent: "Blinkerly", category: .advertising, rule: .trackerRegistrable),
    Case(name: "curated beats AdGuard on the same domain", host: "www.zorblax.com", owner: nil, source: .curated, company: "Zorblax Ads", parent: "Zorblax Holdings", category: .advertising, rule: .curatedRegistrable),
    Case(name: "Apple owner beats AdGuard, AdGuard gives the category", host: "apple-and-tracker.test", owner: "Wexford Systems Corp", source: .appleOwner, company: "Wexford Systems Corp", parent: nil, category: .advertising, rule: .appleOwner),
    Case(name: "AdGuard row without a company is not identified", host: "zz-nocompany.test", owner: nil, source: .none, company: nil, parent: nil, category: .unclassified, rule: .noMatch),
    Case(name: "CDN owner skipped, AdGuard answers", host: "quillnet-edge-only.test", owner: "Quillnet Edge Inc", source: .trackerList, company: "Quillnet Edge Trackers", parent: "Quillnet Edge Trackers", category: .analytics, rule: .trackerRegistrable, skipped: true),
]

private func classifier() throws -> CompanyClassifier {
    let trackers = try TrackerList(
        parsing: trackerText, categories: TrackerCategoryMap(parsing: trackerMapText),
        aliases: TrackerOwnerAliases(parsing: trackerAliasText))
    return CompanyClassifier(
        curated: try CuratedList(parsing: curatedText), appleOwners: try AppleOwnerTable(parsing: aliasText), trackers: trackers)
}

@Test func goldenConflictsResolveAsExpected() throws {
    #expect(cases.count >= 20 && cases.count <= 30)
    let c = try classifier()
    for k in cases {
        let r = c.resolve(hostname: k.host, appleOwner: k.owner)
        #expect(r.label.source == k.source, "\(k.name): source")
        #expect(r.label.company == k.company, "\(k.name): company")
        #expect(r.label.parent == k.parent, "\(k.name): parent")
        #expect(r.label.category == k.category, "\(k.name): category")
        #expect(r.label.rule == k.rule, "\(k.name): rule")
        #expect(r.skipped.isEmpty == !k.skipped, "\(k.name): skipped")
        // classify is resolve's label
        #expect(c.classify(hostname: k.host, appleOwner: k.owner) == r.label, "\(k.name): classify")
    }
}

@Test func eachRowOfPrecedenceTableIsExercised() throws {
    let c = try classifier()
    var seen = Set<String>()
    for k in cases { seen.formUnion(c.resolve(hostname: k.host, appleOwner: k.owner).rowTags) }
    // every source of every order and every exception of the bundled table is used by at least one case
    let wanted = Set(PrecedenceTable.bundled.allRowTags)
    #expect(!wanted.isEmpty)
    #expect(wanted.subtracting(seen).isEmpty, "table tags no golden case uses: \(wanted.subtracting(seen).sorted())")
    #expect(wanted.contains("owner:exception:skip:appleOwner:cdnOperator"))
}
