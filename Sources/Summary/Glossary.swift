import Foundation

public struct GlossaryTerm: Sendable, Equatable {
    public let term: String
    public let text: String

    public init(term: String, text: String) {
        self.term = term
        self.text = text
    }
}

/// the glossary and "How to read this" texts come from Resources/wording.toml (`glossary.N.term`,
/// `glossary.N.text`, `howto.N`); the rules about words stay in code
public enum Glossary {
    /// the glossary has exactly six terms (OD3)
    public static let termCount = 6
    public static let howToReadCount = 3

    public static var terms: [GlossaryTerm] {
        (1...termCount).map {
            GlossaryTerm(term: Wording.bundled.text("glossary.\($0).term"), text: Wording.bundled.text("glossary.\($0).text"))
        }
    }

    public static var howToRead: [String] { (1...howToReadCount).map { Wording.bundled.text("howto.\($0)") } }

    /// words and phrases no user-facing text may contain, matched ignoring case on whole words
    public static let bannedPhrases: [String] = [
        "sells", "sold", "shared your data", "spying", "safe", "unsafe", "stops", "blocks", "even when not in use", "privacy score",
    ]

    /// a speaker never appears in a sentence (owner, 2026-11-24)
    public static let bannedSpeakers: [String] = ["Tattle", "we", "our", "us"]
}
