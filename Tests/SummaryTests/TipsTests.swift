import Foundation
import Summary
import Testing

// OD5 tips (owner, 2026-11-24): shown once at the top when at least one app contacted an advertising or tracking company

@Test func tipsShowOnceAtTheTop() throws {
    // owner, 2026-11-24: the same tips on every app added nothing, so they are shown once at the top
    let both = [
        "Limit background activity: Settings › General › Background App Refresh (may not stop every connection)",
        "Check tracking permission: Settings › Privacy & Security › Tracking",
    ]
    #expect(SummaryDemo.screen().tips == both)
    #expect(SummaryScreen.tipsHeading == "What you can do")
    // nothing to show, or no app with an advertising or tracking company: no tips
    #expect(SummaryScreenBuilder.build(CombinedSummaryBuilder.build(capture: nil, report: nil)).tips.isEmpty)
}

@Test func tipsSettingsPathsAreRecheckedEveryYear() throws {
    // OD5: each tip records the iOS version and date its Settings path was checked on the owner's phone.
    // this fails a year later on purpose: check both paths on a current iOS, then update tips.checked.*
    let file = try Wording.loadBundled()
    let ios = try #require(file.entries["tips.checked.ios"])
    let date = try #require(file.entries["tips.checked.date"])
    #expect(!ios.isEmpty)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    let checked = try #require(f.date(from: date))
    let days = Date().timeIntervalSince(checked) / 86400
    // never a future date: a typo there would switch the reminder off for years
    #expect(days >= 0, "tips.checked.date \(date) is after today")
    #expect(days < 365, "the tips' Settings paths were checked on iOS \(ios) on \(date): check them again on a current iOS")
}
