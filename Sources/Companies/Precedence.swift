import Foundation

/// why the precedence table failed to load. carries a line number only, never a value from the file
public enum PrecedenceError: Error, Equatable, Sendable {
    case missingHeader
    case wrongColumnCount(line: Int)
    case emptyField(line: Int)
    /// a field other than the ones the table knows (`owner`, `category`)
    case unknownField(line: Int)
    case duplicateField(line: Int)
    /// a source name that is not a `LabelSource`, or is `none`, or appears twice in one order
    case unknownSource(line: Int)
    /// a source that can never answer the field (the Apple owner string gives no category)
    case sourceCannotAnswer(line: Int)
    case unknownException(line: Int)
    /// an exception that names a source the row's order does not list
    case exceptionSourceNotInOrder(line: Int)
    /// a field the table has no row for
    case missingField(field: String)
    case fileMissing
}

/// the fields a precedence row decides
public enum PrecedenceField: String, CaseIterable, Sendable {
    /// the company and parent shown for a name
    case owner
    /// the category of a name
    case category

    /// the sources that can answer this field at all. Apple's report names an owner but never a category
    public var answerableSources: [LabelSource] {
        switch self {
        case .owner: [.curated, .trackerList, .appleOwner]
        case .category: [.curated, .trackerList]
        }
    }
}

/// a test an exception applies to one source's answer
public enum PrecedenceCondition: String, CaseIterable, Sendable {
    /// the Apple owner string is a CDN operator of `apple-owner-aliases.tsv`: it names who runs the
    /// delivery network, not who runs the site
    case cdnOperator
}

/// one exception of a row: `skip` a source's answer when the condition holds
public struct PrecedenceException: Sendable, Equatable {
    public let skip: LabelSource
    public let when: PrecedenceCondition

    public init(skip: LabelSource, when: PrecedenceCondition) {
        self.skip = skip
        self.when = when
    }

    /// the spelling used in the table and in tags: `skip:appleOwner:cdnOperator`
    public var spelling: String { "skip:\(skip.rawValue):\(when.rawValue)" }
}

/// one row of the table: for a field, the sources in order and the exceptions
public struct PrecedenceRow: Sendable, Equatable {
    public let field: PrecedenceField
    public let order: [LabelSource]
    public let exceptions: [PrecedenceException]
}

/// the rule for resolving disagreement between sources, as data (Resources/precedence.tsv). the order is
/// a data edit, not a code change. immutable and Sendable. Foundation only
public struct PrecedenceTable: Sendable, Equatable {
    public static let datasetId = "tattle-precedence"
    static let header = ["field", "order", "exception", "note"]
    /// separates sources in an order and exceptions in a row
    static let listSeparator: Character = ","
    static let exceptionSeparator: Character = "|"
    static let noException = "none"

    public let version: String
    public let sha256: String
    public let rows: [PrecedenceRow]

    public func row(for field: PrecedenceField) -> PrecedenceRow {
        // every field has a row: the load fails otherwise
        rows.first { $0.field == field } ?? PrecedenceRow(field: field, order: [], exceptions: [])
    }

    public func order(for field: PrecedenceField) -> [LabelSource] { row(for: field).order }

    /// tab separated text: one header line, then field, order, exception, note. strict: a bad row fails the
    /// whole load (a half-loaded table would silently change who wins)
    public init(parsing text: String, version: String = "", sha256: String = "") throws(PrecedenceError) {
        self.version = version
        self.sha256 = sha256
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let first = lines.first, first.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) == Self.header else {
            throw .missingHeader
        }
        var rows: [PrecedenceRow] = []
        for (index, line) in lines.enumerated().dropFirst() {
            let number = index + 1
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == Self.header.count else { throw .wrongColumnCount(line: number) }
            guard !fields.contains(where: { $0.isEmpty }) else { throw .emptyField(line: number) }
            guard let field = PrecedenceField(rawValue: fields[0]) else { throw .unknownField(line: number) }
            guard !rows.contains(where: { $0.field == field }) else { throw .duplicateField(line: number) }
            var order: [LabelSource] = []
            for name in fields[1].split(separator: Self.listSeparator, omittingEmptySubsequences: false) {
                guard let source = LabelSource(rawValue: String(name)), source != .none, !order.contains(source) else {
                    throw .unknownSource(line: number)
                }
                guard field.answerableSources.contains(source) else { throw .sourceCannotAnswer(line: number) }
                order.append(source)
            }
            var exceptions: [PrecedenceException] = []
            if fields[2] != Self.noException {
                for spelling in fields[2].split(separator: Self.exceptionSeparator, omittingEmptySubsequences: false) {
                    let parts = spelling.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 3, parts[0] == "skip", let source = LabelSource(rawValue: parts[1]),
                          let condition = PrecedenceCondition(rawValue: parts[2]) else { throw .unknownException(line: number) }
                    guard order.contains(source) else { throw .exceptionSourceNotInOrder(line: number) }
                    exceptions.append(PrecedenceException(skip: source, when: condition))
                }
            }
            rows.append(PrecedenceRow(field: field, order: order, exceptions: exceptions))
        }
        for field in PrecedenceField.allCases where !rows.contains(where: { $0.field == field }) {
            throw .missingField(field: field.rawValue)
        }
        self.rows = rows
    }

    /// reads the bundled file and its manifest entry
    public static func loadBundled() throws -> PrecedenceTable {
        guard let url = DatasetManifest.resourceURL("precedence.tsv") else { throw PrecedenceError.fileMissing }
        let text = try String(contentsOf: url, encoding: .utf8)
        let entry = try? DatasetManifest.load().datasets.first { $0.file == "precedence.tsv" }
        return try PrecedenceTable(parsing: text, version: entry?.version ?? "", sha256: entry?.sha256 ?? "")
    }

    /// loaded once. when the resource is missing or invalid, the safe fallback is the curated list alone
    public static let bundled: PrecedenceTable = (try? loadBundled()) ?? PrecedenceTable.curatedOnly

    private static let curatedOnly: PrecedenceTable = {
        let text = header.joined(separator: "\t") + "\nowner\tcurated\tnone\tfallback\ncategory\tcurated\tnone\tfallback\n"
        // the text above always parses
        return (try? PrecedenceTable(parsing: text)) ?? PrecedenceTable(rows: [])
    }()

    private init(rows: [PrecedenceRow]) {
        self.version = ""
        self.sha256 = ""
        self.rows = rows
    }
}

/// a source whose answer an exception set aside
public struct SkippedSource: Sendable, Equatable {
    public let source: LabelSource
    public let condition: PrecedenceCondition

    public init(source: LabelSource, condition: PrecedenceCondition) {
        self.source = source
        self.condition = condition
    }
}

/// the result of resolving one name: the label, and which answers an exception skipped on the way
public struct Resolution: Sendable, Equatable {
    public let label: CompanyLabel
    public let skipped: [SkippedSource]
    /// the source the category came from: `.none` when no source gave one
    public let categorySource: LabelSource

    /// coverage-style tags of the table rows this resolution used: `owner:order:curated`,
    /// `owner:exception:skip:appleOwner:cdnOperator`, `category:order:curated`
    public var rowTags: [String] {
        var tags = ["owner:order:\(label.source.rawValue)"]
        tags += skipped.map { "owner:exception:skip:\($0.source.rawValue):\($0.condition.rawValue)" }
        tags.append("category:order:\(categorySource.rawValue)")
        return tags
    }
}

extension PrecedenceTable {
    /// every tag a resolution can carry from this table: one per source in each order and one per exception
    public var allRowTags: [String] {
        var tags: [String] = []
        for row in rows {
            tags += row.order.map { "\(row.field.rawValue):order:\($0.rawValue)" }
            tags += row.exceptions.map { "\(row.field.rawValue):exception:\($0.spelling)" }
        }
        return tags
    }
}
