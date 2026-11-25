import Foundation
import Summary
import Testing

// OD5 tips (owner, 2026-11-25): shown only on an app that contacted at least one advertising or tracking company

@Test func tipsShowOnlyWhereTheyApply() throws {
    let screen = SummaryDemo.screen()
    func row(_ title: String) throws -> SummaryRow { try #require(screen.rows.first { $0.title == title }) }
    let both = [
        "Limit background activity: Settings › General › Background App Refresh (may not stop every connection)",
        "Check tracking permission: Settings › Privacy & Security › Tracking",
    ]
    #expect(try row("Pinwheel").tips == both)
    #expect(try row("Quillnote").tips == both)
    // no advertising or tracking company: no tips
    #expect(try row("Bobbin").tips.isEmpty)
    #expect(try row("com.example.lantern").tips.isEmpty)
    // iOS system and the merged Apple apps row are not one app
    #expect(try row("iOS system").tips.isEmpty)
    let apple = try row("Apple apps")
    #expect(apple.tips.isEmpty)
    // Apple's own apps never ask to track: only the background tip
    let safari = try #require(apple.children.first { $0.title == "Safari" })
    #expect(safari.tips == [both[0]])
    #expect(try #require(apple.children.first { $0.title == "Maps" }).tips.isEmpty)
    #expect(SummaryScreen.tipsHeading == "What you can do")
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
    #expect(days < 365, "the tips' Settings paths were checked on iOS \(ios) on \(date): check them again on a current iOS")
}
