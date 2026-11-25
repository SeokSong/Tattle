import Foundation

/// why the head-office table failed to load. carries a line number only, never a value from the file
public enum HeadOfficeError: Error, Equatable, Sendable {
    case missingHeader
    case wrongColumnCount(line: Int)
    case emptyField(line: Int)
    /// latitude outside -90...90 or longitude outside -180...180, or not a number
    case badCoordinate(line: Int)
    case unknownMatch(line: Int)
    case duplicateParent(line: Int)
    case fileMissing
}

/// one parent company's head office (Milestone 4, the company map). a head office, not where servers are
public struct HeadOffice: Sendable, Equatable {
    public let parent: String
    public let city: String
    /// empty when Wikidata gives the place no country
    public let country: String
    public let latitude: Double
    public let longitude: Double
    /// the Wikidata item the answer came from, for checking by hand; "none" for a hand place with no item
    public let wikidata: String
    /// how the company was found in Wikidata
    public let match: Match

    /// website: an AdGuard company found by its website; pinned: a curated parent's hand-picked Wikidata item;
    /// hand: a place entered by hand (Wikidata has none, or only a legal registration address)
    public enum Match: String, Sendable { case website, pinned, hand }
}

/// parent company to head office, from Resources/hq.tsv (curated parents, MIT) and Resources/tracker/hq.tsv (AdGuard
/// companies, CC BY-SA with the rest of that folder, owner 2026-11-25). Both are built from Wikidata (CC0) by
/// scripts/hq-data.swift.
/// keyed by the parent name the Summary counts, so a brand's line goes to its parent's head office (owner, 2026-11-25)
public struct HeadOfficeTable: Sendable {
    static let header = ["parent", "city", "country", "latitude", "longitude", "wikidata", "match"]
    private let table: [String: HeadOffice]

    public var count: Int { table.count }
    public var offices: [HeadOffice] { table.values.sorted { $0.parent < $1.parent } }

    public func office(forParent parent: String) -> HeadOffice? { table[parent] }

    /// strict: a bad row fails the whole load. country may be empty; every other field must be filled
    public init(parsing text: String) throws(HeadOfficeError) {
        self.table = try Self.parse(text)
    }

    /// the two bundled files together; a parent in both is a build error, reported as a duplicate in the second file
    public init(parsing curated: String, tracker: String) throws(HeadOfficeError) {
        var table = try Self.parse(curated)
        for (parent, office) in try Self.parse(tracker) {
            guard table[parent] == nil else { throw .duplicateParent(line: 0) }
            table[parent] = office
        }
        self.table = table
    }

    private static func parse(_ text: String) throws(HeadOfficeError) -> [String: HeadOffice] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let first = lines.first, first.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) == Self.header else {
            throw .missingHeader
        }
        var table: [String: HeadOffice] = [:]
        for (index, line) in lines.enumerated().dropFirst() {
            let number = index + 1
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == Self.header.count else { throw .wrongColumnCount(line: number) }
            guard !f.enumerated().contains(where: { $0.offset != 2 && $0.element.isEmpty }) else { throw .emptyField(line: number) }
            guard let lat = Double(f[3]), let lon = Double(f[4]), (-90...90).contains(lat), (-180...180).contains(lon) else {
                throw .badCoordinate(line: number)
            }
            guard let match = HeadOffice.Match(rawValue: f[6]) else { throw .unknownMatch(line: number) }
            guard table[f[0]] == nil else { throw .duplicateParent(line: number) }
            table[f[0]] = HeadOffice(parent: f[0], city: f[1], country: f[2], latitude: lat, longitude: lon, wikidata: f[5], match: match)
        }
        return table
    }

    public static func loadBundled() throws -> HeadOfficeTable {
        guard let curated = DatasetManifest.resourceURL("hq.tsv"), let tracker = DatasetManifest.resourceURL("tracker/hq.tsv") else {
            throw HeadOfficeError.fileMissing
        }
        return try HeadOfficeTable(parsing: String(contentsOf: curated, encoding: .utf8), tracker: String(contentsOf: tracker, encoding: .utf8))
    }
}
