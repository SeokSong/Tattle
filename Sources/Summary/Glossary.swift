import Foundation

public struct GlossaryTerm: Sendable, Equatable {
    public let term: String
    public let text: String

    public init(term: String, text: String) {
        self.term = term
        self.text = text
    }
}

public enum Glossary {
    public static let terms: [GlossaryTerm] = [
        GlossaryTerm(term: "Company", text: "The business behind a destination. Brands are listed under the company that owns them, so YouTube counts as Alphabet."),
        GlossaryTerm(term: "Advertising or tracking", text: "A company with an advertising or analytics service among the destinations. It shows the app contacted them, not what was sent."),
        GlossaryTerm(term: "The app's own company", text: "The company that makes the app. It is counted and marked, because an app contacting its own servers is expected."),
        GlossaryTerm(term: "Apple system and Apple apps", text: "iOS background services and Apple's own apps. Apple servers count as their own company."),
        GlossaryTerm(term: "Not identified", text: "A destination no list knows. It stays in the count, so the numbers never look more complete than they are."),
        GlossaryTerm(term: "Possible", text: "A name seen only through a lookup or a shared server. It may be a different service, so it is never counted."),
    ]

    public static let howToRead: [String] = [
        "Every number counts companies, not websites: YouTube and Google Ads are one company, Alphabet.",
        "\"Contacted\" means the app connected to the company. It does not say what was sent or why.",
        "Unknown parts are always shown next to the counts.",
    ]

    /// words and phrases no user-facing text may contain, matched ignoring case on whole words
    public static let bannedPhrases: [String] = [
        "sells", "sold", "shared your data", "spying", "safe", "unsafe", "stops", "blocks", "even when not in use", "privacy score",
    ]

    /// a speaker never appears in a sentence (owner, 2026-11-24)
    public static let bannedSpeakers: [String] = ["Tattle", "we", "our", "us"]
}
