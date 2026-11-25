import Companies
import Foundation
import Summary
import Testing

// the test apps the owner approved on 2026-11-24, before the rating code was written (OD4). all made up.
// the scale is the owner's: A 0, B 1, C 2-3, D 4-5, F 6+, rated only at 70% traced or more

private func company(_ parent: String, _ categories: [CompanyCategory], own: Bool = false, brands: [String]? = nil,
                     captures: Bool = true, report: Bool = false) -> CombinedCompany {
    CombinedCompany(parent: parent, brands: brands ?? [parent], categories: categories,
                    relation: own ? .sameCompanyAsApp : .other, inCaptures: captures, inReport: report,
                    captureTraffic: TrafficCount(), reportCount: DomainCount(domains: 0, contacts: 0))
}

private func ad(_ n: Int) -> [CombinedCompany] { (0..<n).map { company("AdCo\($0)", [.advertising]) } }
private let traced95 = CoverageRatio(numerator: 95, denominator: 100)
private let scale = RatingScale.fallback

private func grade(_ companies: [CombinedCompany], capture: CoverageRatio? = traced95, report: CoverageRatio? = nil) -> RatingResult? {
    Rating.rate(companies: companies, capture: capture, report: report, scale: scale)
}

@Test func ratingApprovedTestApps() {
    // Clean: 0 tracking companies, 95% traced
    #expect(grade([]) == .graded(.A, count: 0))
    // OneAd
    #expect(grade([company("Adlantic", [.advertising])]) == .graded(.B, count: 1))
    // OwnAds: the own company does advertising. approved as A, changed to B by the owner on 2026-11-24 after the
    // review of PR #11: the own company counts, so the closed row never says "none found" above an advertiser
    #expect(grade([company("Zappy Inc", [.advertising], own: true)]) == .graded(.B, count: 1))
    // CDNHeavy: only content delivery and cloud
    #expect(grade([company("CdnCo", [.contentDelivery]), company("Cloudway", [.cloudService])]) == .graded(.A, count: 0))
    // TwoThree, FourFive, SixPlus
    #expect(grade(ad(2)) == .graded(.C, count: 2))
    #expect(grade(ad(3)) == .graded(.C, count: 3))
    #expect(grade(ad(4)) == .graded(.D, count: 4))
    #expect(grade(ad(5)) == .graded(.D, count: 5))
    #expect(grade(ad(6)) == .graded(.F, count: 6))
    #expect(grade(ad(12)) == .graded(.F, count: 12))
    // Brands: YouTube and Google Ads under one parent count once
    #expect(grade([company("Alphabet", [.advertising, .onlineService], brands: ["Google Ads", "YouTube"])]) == .graded(.B, count: 1))
    // LowCoverage: 65% traced, 0 companies
    #expect(grade([], capture: CoverageRatio(numerator: 65, denominator: 100)) == .notEnoughData(CoverageRatio(numerator: 65, denominator: 100)))
    // Edge70: exactly 70.0% is rated
    #expect(grade([], capture: CoverageRatio(numerator: 70, denominator: 100)) == .graded(.A, count: 0))
    #expect(grade([], capture: CoverageRatio(numerator: 6999, denominator: 10000)) == .notEnoughData(CoverageRatio(numerator: 6999, denominator: 10000)))
    // Mixed: captures 90%, report 60%: every source with data must be at 70%
    #expect(grade(ad(1), capture: CoverageRatio(numerator: 90, denominator: 100), report: CoverageRatio(numerator: 6, denominator: 10))
            == .notEnoughData(CoverageRatio(numerator: 6, denominator: 10)))
    // BothSources: Adlantic in captures, Trackwise in the report: 2 companies
    #expect(grade([company("Adlantic", [.advertising]), company("Trackwise", [.analytics], captures: false, report: true)],
                  report: CoverageRatio(numerator: 9, denominator: 10)) == .graded(.C, count: 2))
    // nothing to trace at all: no rating
    #expect(grade([], capture: nil) == nil)
    #expect(grade([], capture: CoverageRatio(numerator: 0, denominator: 0)) == nil)
}

@Test func ratingPossibleAndTypeOnlyNeverCount() {
    // PossibleOnly and TypeOnly: a possible name and "advertising, owner unknown" destinations are not companies on
    // the card, so the card's companies are empty and the grade is A
    let card = AppCard(key: "test.possible", name: "PossibleOnly", company: nil, kind: .app, companies: [],
                       possibleCompanies: ["MetricCo"], untracedDestinations: 2, typeKnown: [.advertising: 2],
                       capture: nil, report: nil, members: [])
    #expect(Rating.rate(companies: card.companies, capture: traced95, report: nil, scale: scale) == .graded(.A, count: 0))
}

@Test func ratingTextAlwaysCarriesTheCount() {
    #expect(Rating.text(.graded(.C, count: 3)) == "C · 3 advertising or tracking companies")
    #expect(Rating.text(.graded(.B, count: 1)) == "B · 1 advertising or tracking company")
    #expect(Rating.text(.graded(.A, count: 0)) == "A · no advertising or tracking found")
    #expect(Rating.text(.notEnoughData(CoverageRatio(numerator: 65, denominator: 100))) == "Not enough data to rate (65.0% traced)")
}

@Test func ratingScaleFileIsTheOwnersScale() throws {
    let bundled = try RatingScale.loadBundled()
    #expect(bundled == RatingScale.fallback)
    #expect([0, 1, 2, 3, 4, 5, 6, 40].map(bundled.grade(forCount:)) == [.A, .B, .C, .C, .D, .D, .F, .F])
}

@Test func ratingScaleRejectsBadFiles() {
    let good = "grade.A.max = \"0\"\ngrade.B.max = \"1\"\ngrade.C.max = \"3\"\ngrade.D.max = \"5\"\nthreshold.percent = \"70\"\n"
    #expect(throws: RatingScaleError.missingKey("grade.D.max")) { try RatingScale(parsing: good.replacingOccurrences(of: "grade.D.max = \"5\"\n", with: "")) }
    #expect(throws: RatingScaleError.notANumber("grade.C.max")) { try RatingScale(parsing: good.replacingOccurrences(of: "\"3\"", with: "\"three\"")) }
    #expect(throws: RatingScaleError.outOfOrder) { try RatingScale(parsing: good.replacingOccurrences(of: "\"3\"", with: "\"1\"")) }
    #expect(throws: RatingScaleError.outOfOrder) { try RatingScale(parsing: good.replacingOccurrences(of: "\"70\"", with: "\"0\"")) }
    // the scale can be changed in the file: a stricter one
    let strict = try? RatingScale(parsing: good.replacingOccurrences(of: "grade.C.max = \"3\"", with: "grade.C.max = \"2\"")
        .replacingOccurrences(of: "grade.D.max = \"5\"", with: "grade.D.max = \"4\""))
    #expect(strict?.grade(forCount: 5) == .F)
}

@Test func ratingOnlyForSingleApps() {
    // a grade judges one app: iOS system and the merged Apple apps card get none; an Apple app inside does
    let screen = SummaryDemo.screen()
    for row in screen.rows {
        switch row.kind {
        case .app: #expect(row.rating != nil, "\(row.title)")
        case .appleApps, .system: #expect(row.rating == nil, "\(row.title)")
        }
    }
    let apple = screen.rows.first { $0.kind == .appleApps }
    #expect(apple?.children.allSatisfy { $0.rating != nil } == true)
}

@Test func ratingRowShowsTheGradeAndCount() throws {
    let pinwheel = try #require(SummaryDemo.screen().rows.first { $0.title == "Pinwheel" })
    #expect(pinwheel.subtitle == "C · 2 advertising or tracking companies")
}
