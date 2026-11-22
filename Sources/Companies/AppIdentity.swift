import Foundation

/// why the app table failed to load. carries a line number only, never a value from the file
public enum AppTableError: Error, Equatable, Sendable {
    case missingHeader
    case wrongColumnCount(line: Int)
    case emptyField(line: Int)
    /// a bundle id that is not reverse-DNS text, or a prefix that does not end in a dot
    case badBundleId(line: Int)
    case duplicateBundleId(line: Int)
    /// the same process name on two rows: a name must lead to one app
    case duplicateProcessName(line: Int)
    case fileMissing
}

/// one app the table knows: how it appears in a report (bundle id) and in a capture (process names),
/// and who makes it
public struct AppRow: Sendable, Equatable {
    /// an exact bundle id, or a prefix ending in a dot
    public let bundleId: String
    public let displayName: String
    /// full process names as the executable is called; the 16-character cut form is matched too
    public let processNames: [String]
    /// the parent company, spelled as the curated list's `parent` column
    public let company: String
    /// short public rationale; no adjectives
    public let note: String

    public var isPrefix: Bool { bundleId.hasSuffix(".") }
}

/// how many apps of a report joined the table, and which did not
public struct JoinRate: Sendable, Equatable {
    public let joined: Int
    public let total: Int
    /// the distinct ids that did not join, sorted. local use only: never print or commit these
    public let notJoined: [String]
    public var rate: Double { total == 0 ? 0 : Double(joined) / Double(total) }
}

/// the explicit app table (Resources/apps.tsv): joins a report's bundle ids and a capture's process
/// names to one app row, and the row to its parent company. immutable and Sendable. Foundation only.
/// there is no fuzzy matching: a bundle id joins by an exact row, then by the longest row prefix that
/// ends in a dot; a process name joins by its full or 16-character cut form. anything else stays unjoined
public struct AppTable: Sendable {
    public static let datasetId = "tattle-apps"
    static let header = ["bundleId", "displayName", "processName", "company", "note"]
    /// the kernel cuts process names to this length (the same rule as `ProcessNames.cut` in Attribution,
    /// which this target cannot import)
    static let processNameLength = 16
    /// separates several process names in the `processName` column
    static let processNameSeparator: Character = "|"

    public let version: String
    public let sha256: String
    public let rows: [AppRow]
    public var count: Int { rows.count }

    // keys are lowercased: bundle ids are case-insensitive in practice (com.apple.Maps, com.apple.maps)
    private let exact: [String: Int]
    private let prefixes: [(prefix: String, row: Int)]
    private let byProcessName: [String: Int]

    /// tab separated text: one header line, then bundleId, displayName, processName, company, note.
    /// strict: a bad row fails the whole load (a half-loaded table would silently misjoin)
    public init(parsing text: String, version: String = "", sha256: String = "") throws(AppTableError) {
        self.version = version
        self.sha256 = sha256
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let first = lines.first, first.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) == Self.header else {
            throw .missingHeader
        }
        var rows: [AppRow] = []
        var exact: [String: Int] = [:]
        var prefixes: [(prefix: String, row: Int)] = []
        var seenKeys = Set<String>()
        var byProcessName: [String: Int] = [:]
        for (index, line) in lines.enumerated().dropFirst() {
            let number = index + 1
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == Self.header.count else { throw .wrongColumnCount(line: number) }
            // the process name may be blank; every other field must be filled
            guard !fields.enumerated().contains(where: { $0.offset != 2 && $0.element.isEmpty }) else { throw .emptyField(line: number) }
            let id = fields[0]
            guard Self.isValidBundleId(id) else { throw .badBundleId(line: number) }
            let key = id.lowercased()
            guard seenKeys.insert(key).inserted else { throw .duplicateBundleId(line: number) }
            let names = fields[2].isEmpty ? [] : fields[2].split(separator: Self.processNameSeparator, omittingEmptySubsequences: false).map(String.init)
            guard !names.contains(where: { $0.isEmpty }) else { throw .emptyField(line: number) }
            let row = AppRow(bundleId: id, displayName: fields[1], processNames: names, company: fields[3], note: fields[4])
            let position = rows.count
            rows.append(row)
            if row.isPrefix { prefixes.append((key, position)) } else { exact[key] = position }
            for name in names {
                // the full name and its cut form lead to the same row; two rows may not share either
                for form in Set([name, Self.cut(name)]) {
                    if let other = byProcessName[form], other != position { throw .duplicateProcessName(line: number) }
                    byProcessName[form] = position
                }
            }
        }
        self.rows = rows
        self.exact = exact
        // longest prefix first, so the most specific row wins
        self.prefixes = prefixes.sorted { $0.prefix.count > $1.prefix.count }
        self.byProcessName = byProcessName
    }

    /// reverse-DNS text: dot separated parts of letters, digits, hyphen and underscore, at least two
    /// parts. a trailing dot marks a prefix
    private static func isValidBundleId(_ id: String) -> Bool {
        var body = Substring(id)
        if body.hasSuffix(".") { body = body.dropLast() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-" || $0 == "_") }
        }
    }

    private static func cut(_ s: String) -> String { String(s.prefix(processNameLength)) }

    /// reads the bundled file and its manifest entry
    public static func loadBundled() throws -> AppTable {
        guard let url = DatasetManifest.resourceURL("apps.tsv") else { throw AppTableError.fileMissing }
        let text = try String(contentsOf: url, encoding: .utf8)
        let entry = try? DatasetManifest.load().datasets.first { $0.file == "apps.tsv" }
        return try AppTable(parsing: text, version: entry?.version ?? "", sha256: entry?.sha256 ?? "")
    }

    /// lazy, loaded once. an empty table when the resource is missing or invalid (nothing then joins);
    /// `loadBundled()` reports why
    public static let bundled: AppTable = (try? loadBundled()) ?? AppTable.empty

    private static let empty: AppTable = {
        // the header alone always parses
        (try? AppTable(parsing: header.joined(separator: "\t"))) ?? AppTable()
    }()

    private init() {
        version = ""
        sha256 = ""
        rows = []
        exact = [:]
        prefixes = []
        byProcessName = [:]
    }

    // MARK: joins

    /// the row for a report bundle id: an exact row, else the longest prefix row. never a guess from
    /// the last component or from similar text
    public func row(forBundleId id: String) -> AppRow? {
        let key = id.lowercased()
        if let i = exact[key] { return rows[i] }
        for entry in prefixes where key.hasPrefix(entry.prefix) && key.count > entry.prefix.count { return rows[entry.row] }
        return nil
    }

    /// the row for a capture's raw process name: the full name or the full name as the kernel cuts it,
    /// never a prefix of it (the rule of `ProcessNames.matches`)
    public func row(forProcessName raw: String) -> AppRow? {
        byProcessName[raw].map { rows[$0] }
    }

    /// the parent company of the app a capture names, or nil when the table does not know the app
    public func company(for appName: String) -> String? {
        row(forProcessName: appName)?.company
    }

    /// the parent company of the app a report names, or nil when the table does not know the app
    public func company(forBundleId id: String) -> String? {
        row(forBundleId: id)?.company
    }

    /// the join rate of a report: distinct bundle ids that reach a row, over distinct bundle ids
    public func joinRate(bundleIds: some Sequence<String>) -> JoinRate {
        let distinct = Set(bundleIds)
        let missing = distinct.filter { row(forBundleId: $0) == nil }.sorted()
        return JoinRate(joined: distinct.count - missing.count, total: distinct.count, notJoined: missing)
    }

    /// the same for a capture: distinct raw process names that reach a row, over distinct names
    public func joinRate(processNames: some Sequence<String>) -> JoinRate {
        let distinct = Set(processNames)
        let missing = distinct.filter { row(forProcessName: $0) == nil }.sorted()
        return JoinRate(joined: distinct.count - missing.count, total: distinct.count, notJoined: missing)
    }

    /// the company of a label relative to the app. unknown when the app's company is unknown or the
    /// label names no parent; same company when the parents are equal (case-insensitive, whole text)
    public static func relation(appCompany: String?, labelParent: String?) -> LabelRelation {
        guard let appCompany, !appCompany.isEmpty, let labelParent, !labelParent.isEmpty else { return .unknown }
        return appCompany.caseInsensitiveCompare(labelParent) == .orderedSame ? .sameCompanyAsApp : .other
    }
}

extension CompanyLabel {
    /// the same label with `relation` computed from the app's company (nil: the app is not in the table)
    public func relative(toAppCompany appCompany: String?) -> CompanyLabel {
        var copy = self
        copy.relation = AppTable.relation(appCompany: appCompany, labelParent: parent)
        return copy
    }
}
