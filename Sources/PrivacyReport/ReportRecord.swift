import Foundation

/// one network record of an App Privacy Report export, with only the fields the owner decided to keep
/// (OD6, see md/PRIVACY_REPORT.md). the report's `context` field (the website a browser request was
/// made in), its `contextVerificationType` and all `access` records are never read into this type.
/// `initiatedType`, `domainType` and `domainClassification` are raw codes with undocumented meaning:
/// carried and stored, never shown and never interpreted.
public struct ReportRecord: Sendable, Equatable {
    /// the app's bundle id as written in the export
    public let bundleID: String
    /// lower case, without a trailing dot. an ip address literal is possible and stays as written
    public let domain: String
    /// Apple's owner name for the domain; nil when the export has none (about 94% of records)
    public let domainOwner: String?
    public let hits: Int
    public let firstTimeStamp: Date
    public let timeStamp: Date
    public let initiatedType: String?
    public let domainType: Int?
    public let domainClassification: Int?

    public init(
        bundleID: String, domain: String, domainOwner: String?, hits: Int,
        firstTimeStamp: Date, timeStamp: Date,
        initiatedType: String?, domainType: Int?, domainClassification: Int?
    ) {
        self.bundleID = bundleID
        self.domain = domain
        self.domainOwner = domainOwner
        self.hits = hits
        self.firstTimeStamp = firstTimeStamp
        self.timeStamp = timeStamp
        self.initiatedType = initiatedType
        self.domainType = domainType
        self.domainClassification = domainClassification
    }
}

/// one row per app and domain, as stored in `report_contact` (md/STORAGE.md, schema version 3)
public struct ReportContact: Sendable, Equatable {
    public let appID: String
    public let domain: String
    public let domainOwner: String?
    public let hits: Int
    public let firstSeen: Date
    public let lastSeen: Date
    public let initiatedType: String?
    public let domainType: Int?
    public let domainClassification: Int?
}

/// combines the records of one export into one row per app and domain: `hits` summed (capped, never
/// overflowing), `firstSeen` the earliest, `lastSeen` the latest, `domainOwner` the first non-empty
/// value in file order, and the three raw codes from the record with the latest time stamp (a later
/// line wins a tie). memory is bounded by the number of distinct app and domain pairs
public struct ContactCombiner: Sendable {
    private struct Key: Hashable {
        let app: String
        let domain: String
    }
    private struct Row {
        var owner: String?
        var hits: Int
        var first: Date
        var last: Date
        var initiated: String?
        var domainType: Int?
        var classification: Int?
    }
    private var rows: [Key: Row] = [:]

    public init() {}

    public var count: Int { rows.count }

    public mutating func add(_ r: ReportRecord) {
        let key = Key(app: r.bundleID, domain: r.domain)
        guard var row = rows[key] else {
            rows[key] = Row(
                owner: r.domainOwner, hits: r.hits, first: r.firstTimeStamp, last: r.timeStamp,
                initiated: r.initiatedType, domainType: r.domainType, classification: r.domainClassification)
            return
        }
        let (sum, overflow) = row.hits.addingReportingOverflow(r.hits)
        row.hits = overflow ? Int.max : sum
        row.first = min(row.first, r.firstTimeStamp)
        if row.owner == nil { row.owner = r.domainOwner }
        if r.timeStamp >= row.last {
            row.last = r.timeStamp
            row.initiated = r.initiatedType
            row.domainType = r.domainType
            row.classification = r.domainClassification
        }
        rows[key] = row
    }

    /// sorted by app then domain, so the same export always gives the same list
    public var contacts: [ReportContact] {
        rows.map { key, row in
            ReportContact(
                appID: key.app, domain: key.domain, domainOwner: row.owner, hits: row.hits,
                firstSeen: row.first, lastSeen: row.last, initiatedType: row.initiated,
                domainType: row.domainType, domainClassification: row.classification)
        }
        .sorted { ($0.appID, $0.domain) < ($1.appID, $1.domain) }
    }
}
