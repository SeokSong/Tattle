import Foundation

/// why a curated list failed to load. carries a line number only, never a value from the file
public enum CuratedListError: Error, Equatable, Sendable {
    case missingHeader
    case wrongColumnCount(line: Int)
    case emptyField(line: Int)
    case unknownCategory(line: Int)
    case notRegistrable(line: Int)
    case duplicateDomain(line: Int)
    /// a `suffix:` row whose suffix is not a plain rule of the list's private section
    case notPrivateSuffix(line: Int)
    case fileMissing
}

/// the hand-curated company list, loaded from Resources/curated.tsv. immutable and Sendable
public struct CuratedList: Sendable {
    public static let datasetId = "tattle-curated"
    static let header = ["domain", "company", "parent", "category", "note"]

    public let version: String
    public let sha256: String
    private let table: [String: Company]

    public var count: Int { table.count }
    /// the key prefix that marks a platform-operated suffix row (owner decision OD15)
    public static let operatedPrefix = "suffix:"

    /// every row for a domain or hostname, sorted by domain
    public var entries: [Company] {
        table.values.filter { !$0.domain.hasPrefix(Self.operatedPrefix) }.sorted { $0.domain < $1.domain }
    }
    /// the platform-operated suffix rows, sorted; `domain` is the key with its `suffix:` prefix
    public var operatedSuffixes: [Company] {
        table.values.filter { $0.domain.hasPrefix(Self.operatedPrefix) }.sorted { $0.domain < $1.domain }
    }

    /// parses tab separated text: one header line, then domain, company, parent, category, note.
    /// strict: a bad row fails the whole load (a half-loaded list would silently misclassify)
    public init(parsing text: String, version: String = "", sha256: String = "") throws(CuratedListError) {
        self.version = version
        self.sha256 = sha256
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let first = lines.first, first.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) == Self.header else {
            throw .missingHeader
        }
        var table: [String: Company] = [:]
        for (index, line) in lines.enumerated().dropFirst() {
            let number = index + 1
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == Self.header.count else { throw .wrongColumnCount(line: number) }
            guard !fields.contains(where: { $0.isEmpty }) else { throw .emptyField(line: number) }
            guard let category = CompanyCategory(rawValue: fields[3]), category != .unclassified else {
                throw .unknownCategory(line: number)
            }
            let domain = fields[0]
            if domain.hasPrefix(Self.operatedPrefix) {
                // a platform-operated suffix must be a plain private-section rule of the bundled list
                let suffix = String(domain.dropFirst(Self.operatedPrefix.count))
                guard suffix == suffix.lowercased(), PublicSuffixList.bundled.privatePlatform[suffix] != nil,
                      !suffix.hasPrefix("*."), !suffix.hasPrefix("!") else { throw .notPrivateSuffix(line: number) }
            } else {
                guard Self.isValidKey(domain) else { throw .notRegistrable(line: number) }
            }
            guard table[domain] == nil else { throw .duplicateDomain(line: number) }
            table[domain] = Company(domain: domain, company: fields[1], parent: fields[2], category: category, note: fields[4])
        }
        self.table = table
    }

    /// a key is lowercase and is a registrable domain or a hostname below one
    private static func isValidKey(_ key: String) -> Bool {
        guard key == key.lowercased(), !key.hasSuffix("."), let registrable = registrableDomain(of: key) else { return false }
        return key == registrable || key.hasSuffix("." + registrable)
    }

    /// reads the bundled file and its manifest entry
    public static func loadBundled() throws -> CuratedList {
        guard let url = DatasetManifest.resourceURL("curated.tsv") else { throw CuratedListError.fileMissing }
        let text = try String(contentsOf: url, encoding: .utf8)
        let entry = try? DatasetManifest.load().datasets.first { $0.file == "curated.tsv" }
        return try CuratedList(parsing: text, version: entry?.version ?? "", sha256: entry?.sha256 ?? "")
    }

    /// lazy, loaded once. an empty list when the resource is missing or invalid (every name then
    /// comes back unclassified); `loadBundled()` reports why
    public static let bundled: CuratedList = (try? loadBundled()) ?? CuratedList.empty

    private static let empty: CuratedList = {
        // the header alone always parses
        (try? CuratedList(parsing: header.joined(separator: "\t"))) ?? CuratedList(table: [:])
    }()

    private init(table: [String: Company]) {
        self.version = ""
        self.sha256 = ""
        self.table = table
    }

    /// the ladder: the full hostname, then each parent suffix down to and including the
    /// registrable domain; the most specific row wins. never matches on substrings
    /// ladder: exact hostname row, rows of each parent, then (at the registrable domain) a platform-operated
    /// suffix row, then the registrable domain's own row. a suffix row is reached only when the name is under
    /// that private suffix, so customers' sites under other suffixes are never named after the platform
    func lookup(_ name: String, registrable: String) -> (Company, LabelRule)? {
        var candidate = Substring(name)
        while true {
            if candidate.count == registrable.count, let dot = candidate.firstIndex(of: "."),
               let operated = table[Self.operatedPrefix + candidate[candidate.index(after: dot)...]] {
                return (operated, .curatedOperatedSuffix)
            }
            if let row = table[String(candidate)] {
                return (row, candidate.count == registrable.count ? .curatedRegistrable : .curatedHostname)
            }
            if candidate.count <= registrable.count { return nil }
            guard let dot = candidate.firstIndex(of: ".") else { return nil }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }
}
