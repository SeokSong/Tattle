import Foundation

/// why the Apple owner table failed to load. carries a line number only, never a value from the file
public enum AppleOwnerTableError: Error, Equatable, Sendable {
    case missingHeader
    case wrongColumnCount(line: Int)
    case emptyField(line: Int)
    case unknownKind(line: Int)
    /// the same owner string twice (case and spacing ignored)
    case duplicateOwner(line: Int)
    case fileMissing
}

/// what a row of `apple-owner-aliases.tsv` says about an owner string
public enum AppleOwnerKind: String, CaseIterable, Sendable {
    /// the owner string is clearly the same company as a curated parent
    case alias
    /// the owner string is a CDN operator: it names who runs the delivery network, not who runs the site. also an alias
    case cdn
}

/// one row: Apple's owner string, what kind it is, and the curated parent it stands for
public struct AppleOwnerRow: Sendable, Equatable {
    public let owner: String
    public let kind: AppleOwnerKind
    /// spelled exactly as a `parent` of the curated list (a test checks it)
    public let parent: String
    public let note: String
}

/// what Apple's `domainOwner` strings mean (Resources/apple-owner-aliases.tsv). the owner string is passed
/// in as a plain String: this target never imports PrivacyReport. Apple gives an owner and no category,
/// so nothing here yields a category. matching is exact on the whole string, ignoring case and runs of
/// spaces; there is no fuzzy matching. immutable and Sendable. Foundation only
public struct AppleOwnerTable: Sendable {
    public static let datasetId = "tattle-apple-owner-aliases"
    static let header = ["appleOwner", "kind", "parent", "note"]

    public let version: String
    public let sha256: String
    public let rows: [AppleOwnerRow]
    public var count: Int { rows.count }
    private let byKey: [String: Int]

    /// the lookup key: lowercase, trimmed, runs of whitespace collapsed
    static func key(_ owner: String) -> String {
        owner.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public init(parsing text: String, version: String = "", sha256: String = "") throws(AppleOwnerTableError) {
        self.version = version
        self.sha256 = sha256
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let first = lines.first, first.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) == Self.header else {
            throw .missingHeader
        }
        var rows: [AppleOwnerRow] = []
        var byKey: [String: Int] = [:]
        for (index, line) in lines.enumerated().dropFirst() {
            let number = index + 1
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == Self.header.count else { throw .wrongColumnCount(line: number) }
            guard !fields.contains(where: { $0.isEmpty }) else { throw .emptyField(line: number) }
            guard let kind = AppleOwnerKind(rawValue: fields[1]) else { throw .unknownKind(line: number) }
            let key = Self.key(fields[0])
            guard byKey[key] == nil else { throw .duplicateOwner(line: number) }
            byKey[key] = rows.count
            rows.append(AppleOwnerRow(owner: fields[0], kind: kind, parent: fields[2], note: fields[3]))
        }
        self.rows = rows
        self.byKey = byKey
    }

    public func row(forOwner owner: String) -> AppleOwnerRow? {
        byKey[Self.key(owner)].map { rows[$0] }
    }

    /// the curated parent the owner string stands for, when the table says so
    public func aliasedParent(forOwner owner: String) -> String? { row(forOwner: owner)?.parent }

    public func isCDNOperator(_ owner: String) -> Bool { row(forOwner: owner)?.kind == .cdn }

    /// the name to compare with a curated parent: the alias when there is one, else the owner string
    /// as Apple wrote it (trimmed). two names are the same when they are equal ignoring case
    public func comparableParent(forOwner owner: String) -> String {
        aliasedParent(forOwner: owner) ?? owner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func loadBundled() throws -> AppleOwnerTable {
        guard let url = DatasetManifest.resourceURL("apple-owner-aliases.tsv") else { throw AppleOwnerTableError.fileMissing }
        let text = try String(contentsOf: url, encoding: .utf8)
        let entry = try? DatasetManifest.load().datasets.first { $0.file == "apple-owner-aliases.tsv" }
        return try AppleOwnerTable(parsing: text, version: entry?.version ?? "", sha256: entry?.sha256 ?? "")
    }

    /// loaded once; empty when the resource is missing or invalid (no aliases, no CDN exception)
    public static let bundled: AppleOwnerTable = (try? loadBundled()) ?? AppleOwnerTable.empty

    private static let empty: AppleOwnerTable = {
        // the header alone always parses
        (try? AppleOwnerTable(parsing: header.joined(separator: "\t"))) ?? AppleOwnerTable(rows: [])
    }()

    private init(rows: [AppleOwnerRow]) {
        self.version = ""
        self.sha256 = ""
        self.rows = rows
        self.byKey = [:]
    }
}
