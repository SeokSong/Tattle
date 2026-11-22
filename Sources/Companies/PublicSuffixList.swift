import Foundation

// the public suffix list, parsed once and immutable after. both sections are bundled (owner decision
// OD14, md/COMPANIES.md), so x.github.io is its own registrable domain. a rule from the private
// section remembers the platform named in the list's comment block above it
//
// rules are stored by their unicode labels, joined with dots:
//   plain rule      "co.uk"  -> plain
//   wildcard "*.ck" -> wildcardParents holds "ck"
//   exception "!www.ck" -> exceptions holds "www.ck"
// the shipped file marks each private block with "// PLATFORM: <name>" (written by the build script)
public struct PublicSuffixList: Sendable {
    let plain: Set<String>
    let wildcardParents: Set<String>
    let exceptions: Set<String>
    /// private-section rules by rule text ("x", "*.x" or "!x") to the platform name; "" when the
    /// comment could not be read (the suffix itself is then used as the platform)
    let privatePlatform: [String: String]

    static let platformMarker = "// PLATFORM:"

    /// number of rules read
    public var ruleCount: Int { plain.count + wildcardParents.count + exceptions.count }

    /// parses the list format: one rule per line, "//" comments, anything after whitespace ignored
    public init(contents: String) {
        var plain = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
        var platforms: [String: String] = [:]
        var inPrivate = false
        var platform = ""
        for line in contents.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("//") {
                if line.hasPrefix("// ===BEGIN PRIVATE DOMAINS===") { inPrivate = true; platform = "" }
                else if line.hasPrefix("// ===END PRIVATE DOMAINS===") { inPrivate = false }
                else if inPrivate, line.hasPrefix(Self.platformMarker) {
                    platform = line.dropFirst(Self.platformMarker.count).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let rule = line.split(whereSeparator: \.isWhitespace).first else { continue }
            let text = rule.lowercased()
            if text.hasPrefix("!") {
                exceptions.insert(String(text.dropFirst()))
            } else if text.hasPrefix("*.") {
                wildcards.insert(String(text.dropFirst(2)))
            } else {
                plain.insert(text)
            }
            if inPrivate { platforms[text] = platform }
        }
        self.plain = plain
        self.wildcardParents = wildcards
        self.exceptions = exceptions
        self.privatePlatform = platforms
    }

    /// the list shipped in the package; empty (and `isLoaded` false) if the resource is missing,
    /// in which case every name falls back to the default one-label suffix
    public static let bundled: PublicSuffixList = {
        guard let url = DatasetManifest.resourceURL("psl.dat"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return PublicSuffixList(contents: "")
        }
        return PublicSuffixList(contents: text)
    }()

    public var isLoaded: Bool { ruleCount > 0 }

    /// how many trailing labels of `labels` (already lowercase, unicode) form the public suffix, and the
    /// rule that decided it (nil for the default rule). exception rules win, then the longest plain or
    /// wildcard rule, then the default rule (one label)
    func suffixMatch(of labels: [String]) -> (length: Int, rule: String?) {
        let n = labels.count
        // joined[i] = labels[i...] as one dotted string, built from the right
        var joined = [String](repeating: "", count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            joined[i] = i == n - 1 ? labels[i] : labels[i] + "." + joined[i + 1]
        }
        for i in 0..<n where exceptions.contains(joined[i]) {
            return (n - i - 1, "!" + joined[i])
        }
        for i in 0..<n {
            if plain.contains(joined[i]) { return (n - i, joined[i]) }
            // a wildcard needs one extra label to its left: "*.ck" makes "a.ck" a suffix
            if i + 1 < n, wildcardParents.contains(joined[i + 1]) { return (n - i, "*." + joined[i + 1]) }
        }
        return (1, nil)
    }

    func suffixLength(of labels: [String]) -> Int { suffixMatch(of: labels).length }
}
