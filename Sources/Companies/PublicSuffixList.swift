import Foundation

// the public suffix list, parsed once and immutable after. only the ICANN section is bundled
// (md/COMPANIES.md says why), so x.github.io resolves to github.io.
//
// rules are stored by their unicode labels, joined with dots:
//   plain rule      "co.uk"  -> plain
//   wildcard "*.ck" -> wildcardParents holds "ck"
//   exception "!www.ck" -> exceptions holds "www.ck"
public struct PublicSuffixList: Sendable {
    let plain: Set<String>
    let wildcardParents: Set<String>
    let exceptions: Set<String>

    /// number of rules read
    public var ruleCount: Int { plain.count + wildcardParents.count + exceptions.count }

    /// parses the list format: one rule per line, "//" comments, anything after whitespace ignored
    public init(contents: String) {
        var plain = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
        for line in contents.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("//") else { continue }
            guard let rule = line.split(whereSeparator: \.isWhitespace).first else { continue }
            let text = rule.lowercased()
            if text.hasPrefix("!") {
                exceptions.insert(String(text.dropFirst()))
            } else if text.hasPrefix("*.") {
                wildcards.insert(String(text.dropFirst(2)))
            } else {
                plain.insert(text)
            }
        }
        self.plain = plain
        self.wildcardParents = wildcards
        self.exceptions = exceptions
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

    /// how many trailing labels of `labels` (already lowercase, unicode) form the public suffix.
    /// exception rules win, then the longest plain or wildcard rule, then the default rule (one label)
    func suffixLength(of labels: [String]) -> Int {
        let n = labels.count
        // joined[i] = labels[i...] as one dotted string, built from the right
        var joined = [String](repeating: "", count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            joined[i] = i == n - 1 ? labels[i] : labels[i] + "." + joined[i + 1]
        }
        for i in 0..<n where exceptions.contains(joined[i]) {
            return n - i - 1
        }
        for i in 0..<n {
            if plain.contains(joined[i]) { return n - i }
            // a wildcard needs one extra label to its left: "*.ck" makes "a.ck" a suffix
            if i + 1 < n, wildcardParents.contains(joined[i + 1]) { return n - i }
        }
        return 1
    }
}
