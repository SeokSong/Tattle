import Companies
import Foundation

/// why the wording file failed to load. carries a line number only
public enum WordingError: Error, Equatable, Sendable {
    /// not a comment, not blank, and not `key = "text"`
    case badLine(line: Int)
    /// a backslash followed by something other than `"` or `\`
    case badEscape(line: Int)
    case duplicateKey(line: Int)
    case fileMissing
}

/// the summary's sentence templates, read from Resources/wording.toml (a small subset of TOML: `key = "text"`
/// lines and `#` comments). the code chooses which key applies and fills the `{placeholders}`; the words live
/// in the file so they can be changed without touching code (owner, 2026-11-24)
public struct Wording: Sendable {
    public let entries: [String: String]

    public init(entries: [String: String]) {
        self.entries = entries
    }

    /// strict: a bad line fails the whole load, so a typo never shows half a screen of wrong text
    public init(parsing text: String) throws(WordingError) {
        var entries: [String: String] = [:]
        // some editors save a byte order mark; it is not part of the first line
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).enumerated() {
            let number = index + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else { throw .badLine(line: number) }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" }),
                  value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { throw .badLine(line: number) }
            var text = ""
            var escaped = false
            for c in value.dropFirst().dropLast() {
                if escaped {
                    guard c == "\"" || c == "\\" else { throw .badEscape(line: number) }
                    text.append(c)
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    throw .badLine(line: number)  // an unescaped quote inside the text
                } else {
                    text.append(c)
                }
            }
            guard !escaped else { throw .badEscape(line: number) }
            guard entries[key] == nil else { throw .duplicateKey(line: number) }
            entries[key] = text
        }
        self.entries = entries
    }

    /// the text for `key` with each `{name}` replaced. a missing key shows as `[key]`: a visible bug, never
    /// a made-up sentence
    public func text(_ key: String, _ values: [String: String] = [:]) -> String {
        guard let template = entries[key] else { return "[\(key)]" }
        // one pass over the template: a filled-in value (an app or company name) is never searched again, so a
        // name like "{count} Timer" stays as written. an unknown placeholder is left as it is
        var out = "", rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let name = String(rest[rest.index(after: open)..<close])
            out += values[name] ?? String(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// the `{name}` placeholders a text uses
    public static func placeholders(in text: String) -> Set<String> {
        var names = Set<String>()
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            names.insert(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return names
    }

    // MARK: loading

    /// the file name SwiftPM gives this target's resource bundle
    static let bundleName = "Tattle_Summary.bundle"

    /// found by the same search as the company lists (`DatasetManifest`); `Bundle.module` is never used, it traps
    /// when the bundle is absent
    static func resourceURL(_ name: String) -> URL? { DatasetManifest.resourceURL(name, inBundleNamed: bundleName) }

    public static func loadBundled() throws -> Wording {
        guard let url = resourceURL("wording.toml") else { throw WordingError.fileMissing }
        return try Wording(parsing: String(contentsOf: url, encoding: .utf8))
    }

    /// loaded once. empty when the file is missing or invalid: every sentence then shows its `[key]`
    public static let bundled: Wording = (try? loadBundled()) ?? Wording(entries: [:])
}
