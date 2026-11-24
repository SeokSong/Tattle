import Foundation

/// why a tracker data file failed to load. carries a line number only, never a value from the file
public enum TrackerDataError: Error, Equatable, Sendable {
    case missingHeader
    case wrongColumnCount(line: Int)
    case emptyField(line: Int)
    /// a category name that the category map does not know, or a map row whose category is not a CompanyCategory
    case unknownCategory(line: Int)
    /// a domain that is not lowercase [a-z0-9.-], starts or ends with a dot, or holds ".."
    case invalidDomain(line: Int)
    case notSorted(line: Int)
    case duplicate(line: Int)
    case fileMissing
}

/// splits text into lines (trailing empty lines dropped) and checks the header; returns the rows as field arrays
private func parseTable(_ text: String, header: [String], columns: Int) throws(TrackerDataError) -> [(line: Int, fields: [String])] {
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
    while lines.last?.isEmpty == true { lines.removeLast() }
    guard let first = lines.first, first.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) == header else {
        throw .missingHeader
    }
    var rows: [(line: Int, fields: [String])] = []
    for (index, line) in lines.enumerated().dropFirst() {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == columns else { throw .wrongColumnCount(line: index + 1) }
        rows.append((index + 1, fields))
    }
    return rows
}

/// maps an AdGuard category name to a Tattle category, loaded from Resources/tracker-categories.tsv
public struct TrackerCategoryMap: Sendable, Equatable {
    static let header = ["adguardCategory", "category", "note"]
    private let table: [String: CompanyCategory]

    public var count: Int { table.count }

    public init(parsing text: String) throws(TrackerDataError) {
        var table: [String: CompanyCategory] = [:]
        for (line, fields) in try parseTable(text, header: Self.header, columns: Self.header.count) {
            guard !fields.contains(where: { $0.isEmpty }) else { throw .emptyField(line: line) }
            guard let category = CompanyCategory(rawValue: fields[1]) else { throw .unknownCategory(line: line) }
            guard table[fields[0]] == nil else { throw .duplicate(line: line) }
            table[fields[0]] = category
        }
        self.table = table
    }

    public func category(for adguardCategory: String) -> CompanyCategory? { table[adguardCategory] }
}

/// maps an AdGuard company name to a parent that Tattle already uses, loaded from Resources/tracker-owner-aliases.tsv
public struct TrackerOwnerAliases: Sendable, Equatable {
    static let header = ["adguardCompany", "parent", "note"]
    private let table: [String: String]

    public var count: Int { table.count }
    public var parents: Set<String> { Set(table.values) }

    public init(parsing text: String) throws(TrackerDataError) {
        var table: [String: String] = [:]
        for (line, fields) in try parseTable(text, header: Self.header, columns: Self.header.count) {
            guard !fields.contains(where: { $0.isEmpty }) else { throw .emptyField(line: line) }
            guard table[fields[0]] == nil else { throw .duplicate(line: line) }
            table[fields[0]] = fields[1]
        }
        self.table = table
    }

    /// exact, case-sensitive match on the whole string. no normalisation and no partial matching
    public func parent(for company: String) -> String? { table[company] }
}

public struct TrackerEntry: Sendable, Equatable {
    public let domain: String
    /// nil when the list has no company for the row
    public let company: String?
    /// nil when `company` is nil; else the alias parent, else `company` itself
    public let parent: String?
    public let category: CompanyCategory
    public let adguardCategory: String
}

/// the AdGuard tracker list, loaded from Resources/tracker/tracker.tsv. immutable and Sendable
public struct TrackerList: Sendable {
    public static let datasetId = "adguard-companiesdb"
    static let header = ["domain", "company", "adguardCategory"]

    public let version: String
    public let sha256: String
    /// rows whose domain is a public suffix or not under a registrable domain; they are not labelled (owner decision OD14)
    public let skippedNotRegistrable: Int
    private let table: [String: TrackerEntry]

    /// rows kept
    public var count: Int { table.count }

    /// strict: a bad row fails the whole load. rows must be sorted by domain with no duplicates
    public init(parsing text: String, categories: TrackerCategoryMap, aliases: TrackerOwnerAliases,
                version: String = "", sha256: String = "") throws(TrackerDataError) {
        self.version = version
        self.sha256 = sha256
        var table: [String: TrackerEntry] = [:]
        var skipped = 0
        var previous: String?
        for (line, fields) in try parseTable(text, header: Self.header, columns: Self.header.count) {
            let domain = fields[0], company = fields[1], adguard = fields[2]
            guard !domain.isEmpty, !adguard.isEmpty else { throw .emptyField(line: line) }
            guard Self.isValidDomain(domain) else { throw .invalidDomain(line: line) }
            if let previous {
                if domain == previous { throw .duplicate(line: line) }
                if domain < previous { throw .notSorted(line: line) }
            }
            previous = domain
            guard let category = categories.category(for: adguard) else { throw .unknownCategory(line: line) }
            guard let registrable = registrableDomain(of: domain),
                  domain == registrable || domain.hasSuffix("." + registrable) else {
                skipped += 1
                continue
            }
            table[domain] = TrackerEntry(
                domain: domain,
                company: company.isEmpty ? nil : company,
                parent: company.isEmpty ? nil : (aliases.parent(for: company) ?? company),
                category: category,
                adguardCategory: adguard)
        }
        self.table = table
        self.skippedNotRegistrable = skipped
    }

    private static func isValidDomain(_ d: String) -> Bool {
        d.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D }
            && !d.hasPrefix(".") && !d.hasSuffix(".") && !d.contains("..")
    }

    /// the full name, then each parent suffix down to and including the registrable domain; the most
    /// specific row wins. never matches above the registrable domain. returns rows with no company too
    public func lookup(_ name: String, registrable: String) -> (TrackerEntry, LabelRule)? {
        var candidate = Substring(name)
        while true {
            if let row = table[String(candidate)] {
                return (row, candidate.count == registrable.count ? .trackerRegistrable : .trackerHostname)
            }
            if candidate.count <= registrable.count { return nil }
            guard let dot = candidate.firstIndex(of: ".") else { return nil }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }

    /// reads the bundled files and the manifest entry
    public static func loadBundled() throws -> TrackerList {
        guard let mapURL = DatasetManifest.resourceURL("tracker-categories.tsv"),
              let aliasURL = DatasetManifest.resourceURL("tracker-owner-aliases.tsv"),
              let listURL = DatasetManifest.resourceURL("tracker/tracker.tsv") else { throw TrackerDataError.fileMissing }
        let categories = try TrackerCategoryMap(parsing: String(contentsOf: mapURL, encoding: .utf8))
        let aliases = try TrackerOwnerAliases(parsing: String(contentsOf: aliasURL, encoding: .utf8))
        let text = try String(contentsOf: listURL, encoding: .utf8)
        let entry = try? DatasetManifest.load().datasets.first { $0.file == "tracker/tracker.tsv" }
        return try TrackerList(parsing: text, categories: categories, aliases: aliases,
                               version: entry?.version ?? "", sha256: entry?.sha256 ?? "")
    }

    /// lazy, loaded once. empty means the tracker source never matches; `loadBundled()` reports why
    public static let bundled: TrackerList = (try? loadBundled()) ?? TrackerList.empty

    private static let empty: TrackerList = {
        // the header alone always parses
        let map = try? TrackerCategoryMap(parsing: TrackerCategoryMap.header.joined(separator: "\t"))
        let aliases = try? TrackerOwnerAliases(parsing: TrackerOwnerAliases.header.joined(separator: "\t"))
        if let map, let aliases, let list = try? TrackerList(parsing: header.joined(separator: "\t"), categories: map, aliases: aliases) {
            return list
        }
        return TrackerList(table: [:])
    }()

    private init(table: [String: TrackerEntry]) {
        self.version = ""
        self.sha256 = ""
        self.skippedNotRegistrable = 0
        self.table = table
    }
}
