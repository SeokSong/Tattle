import Foundation

// imported App Privacy Report rows. plain structs: Storage does not know the parser's types,
// the import glue in Pipeline maps between them. never log app ids or domains.

public struct ReportImportRow: Equatable, Sendable {
    public var id: String
    public var fileSHA256: String
    public var periodStart: Date
    public var periodEnd: Date
    public var importedAt: Date
    public var linesRead: Int
    public var recordsKept: Int
    public var malformed: Int
    public var unknownTypes: Int
    /// the `v<number>` of the export's file name; nil when the name has none
    public var formatVersion: Int?

    public init(
        id: String = UUID().uuidString, fileSHA256: String, periodStart: Date, periodEnd: Date,
        importedAt: Date = Date(), linesRead: Int = 0, recordsKept: Int = 0, malformed: Int = 0,
        unknownTypes: Int = 0, formatVersion: Int? = nil
    ) {
        self.id = id
        self.fileSHA256 = fileSHA256
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.importedAt = importedAt
        self.linesRead = linesRead
        self.recordsKept = recordsKept
        self.malformed = malformed
        self.unknownTypes = unknownTypes
        self.formatVersion = formatVersion
    }
}

/// one app and domain within one import
public struct ReportContactRow: Equatable, Sendable {
    public var importId: String
    public var appId: String
    public var domain: String
    public var domainOwner: String?
    public var hits: Int
    public var firstSeen: Date?
    public var lastSeen: Date?
    public var initiatedType: String?
    public var domainType: Int?
    public var domainClassification: Int?

    public init(
        importId: String, appId: String, domain: String, domainOwner: String? = nil, hits: Int,
        firstSeen: Date? = nil, lastSeen: Date? = nil, initiatedType: String? = nil, domainType: Int? = nil,
        domainClassification: Int? = nil
    ) {
        self.importId = importId
        self.appId = appId
        self.domain = domain
        self.domainOwner = domainOwner
        self.hits = hits
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.initiatedType = initiatedType
        self.domainType = domainType
        self.domainClassification = domainClassification
    }
}

public enum SaveImportOutcome: Equatable, Sendable {
    /// stored; `replaced` older imports with an overlapping period were removed in the same transaction
    case stored(replaced: Int)
    /// a file with the same sha-256 is already stored: nothing changed
    case duplicate
    /// no contacts: nothing stored
    case empty
    /// a stored import overlaps this one and ends later, so this file is older: nothing stored.
    /// `newestPeriodEnd` is the latest `period_end` among those overlapping imports
    case olderThanStored(newestPeriodEnd: Date)
}

extension Store {
    /// one transaction: same hash is a no-op; an overlapping stored import with a later `period_end` refuses this
    /// (older) file; otherwise (equal `period_end` counts as newer) every stored import whose period overlaps
    /// this one is replaced (periods that only touch at one instant count as overlapping, so a record on the boundary
    /// is never counted twice). contacts are stored under `row.id`
    @discardableResult
    public func saveImport(_ row: ReportImportRow, contacts: [ReportContactRow]) throws -> SaveImportOutcome {
        guard !contacts.isEmpty else { return .empty }
        return try db.transaction {
            let dup = try db.statement("select count(*) from report_import where file_sha256 = ?")
            dup.bind(1, row.fileSHA256)
            _ = try dup.step()
            let exists = dup.int(0) > 0
            dup.reset()
            if exists { return .duplicate }

            let newer = try db.statement(
                "select max(period_end) from report_import where period_start <= ? and period_end >= ? and period_end > ?")
            newer.bind(1, row.periodEnd.timeIntervalSince1970)
            newer.bind(2, row.periodStart.timeIntervalSince1970)
            newer.bind(3, row.periodEnd.timeIntervalSince1970)
            _ = try newer.step()
            let newestEnd: Double? = newer.isNull(0) ? nil : newer.double(0)
            newer.reset()
            if let newestEnd { return .olderThanStored(newestPeriodEnd: Date(timeIntervalSince1970: newestEnd)) }

            let old = try db.statement("select count(*) from report_import where period_start <= ? and period_end >= ?")
            old.bind(1, row.periodEnd.timeIntervalSince1970)
            old.bind(2, row.periodStart.timeIntervalSince1970)
            _ = try old.step()
            let replaced = old.int(0)
            old.reset()
            let del = try db.statement("delete from report_import where period_start <= ? and period_end >= ?")
            del.bind(1, row.periodEnd.timeIntervalSince1970)
            del.bind(2, row.periodStart.timeIntervalSince1970)
            try del.run()  // contacts cascade

            let ins = try db.statement(
                """
                insert into report_import(id, file_sha256, period_start, period_end, imported_at, lines_read,
                  records_kept, malformed, unknown_types, format_version)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            ins.bind(1, row.id)
            ins.bind(2, row.fileSHA256)
            ins.bind(3, row.periodStart.timeIntervalSince1970)
            ins.bind(4, row.periodEnd.timeIntervalSince1970)
            ins.bind(5, row.importedAt.timeIntervalSince1970)
            ins.bind(6, row.linesRead)
            ins.bind(7, row.recordsKept)
            ins.bind(8, row.malformed)
            ins.bind(9, row.unknownTypes)
            ins.bind(10, row.formatVersion)
            try ins.run()

            let c = try db.statement(
                """
                insert into report_contact(import_id, app_id, domain, domain_owner, hits, first_seen, last_seen,
                  initiated_type, domain_type, domain_classification)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for r in contacts {
                c.bind(1, row.id)
                c.bind(2, r.appId)
                c.bind(3, r.domain)
                c.bind(4, r.domainOwner)
                c.bind(5, r.hits)
                c.bind(6, r.firstSeen?.timeIntervalSince1970)
                c.bind(7, r.lastSeen?.timeIntervalSince1970)
                c.bind(8, r.initiatedType)
                c.bind(9, r.domainType)
                c.bind(10, r.domainClassification)
                try c.run()
            }
            return .stored(replaced: replaced)
        }
    }

    /// stored imports, oldest period first
    public func imports() throws -> [ReportImportRow] {
        let st = try db.statement(
            """
            select id, file_sha256, period_start, period_end, imported_at, lines_read, records_kept, malformed,
              unknown_types, format_version
            from report_import order by period_start, id
            """)
        defer { st.reset() }
        var out: [ReportImportRow] = []
        while try st.step() {
            guard let id = st.text(0), let sha = st.text(1) else { throw StorageError.invalidData("import row") }
            out.append(
                ReportImportRow(
                    id: id, fileSHA256: sha, periodStart: Date(timeIntervalSince1970: st.double(2)),
                    periodEnd: Date(timeIntervalSince1970: st.double(3)),
                    importedAt: Date(timeIntervalSince1970: st.double(4)), linesRead: st.int(5),
                    recordsKept: st.int(6), malformed: st.int(7), unknownTypes: st.int(8),
                    formatVersion: st.optInt(9)))
        }
        return out
    }

    public func contacts(importId: String) throws -> [ReportContactRow] {
        let st = try db.statement(contactSelect + " where c.import_id = ? order by c.app_id, c.domain")
        st.bind(1, importId)
        return try readContacts(st)
    }

    /// contacts last seen at or after `since` (a contact with no time uses its import's period end)
    public func contacts(since: Date) throws -> [ReportContactRow] {
        let st = try db.statement(
            contactSelect + " join report_import i on i.id = c.import_id"
                + " where coalesce(c.last_seen, i.period_end) >= ? order by c.import_id, c.app_id, c.domain")
        st.bind(1, since.timeIntervalSince1970)
        return try readContacts(st)
    }

    /// removes one import by its file hash (contacts cascade). false when none matched
    @discardableResult
    public func deleteImport(sha256: String) throws -> Bool {
        try db.transaction {
            let st = try db.statement("delete from report_import where file_sha256 = ?")
            st.bind(1, sha256)
            try st.run()
            let n = try db.statement("select changes()")
            _ = try n.step()
            let changed = n.int(0)
            n.reset()
            return changed > 0
        }
    }

    private var contactSelect: String {
        """
        select c.import_id, c.app_id, c.domain, c.domain_owner, c.hits, c.first_seen, c.last_seen,
          c.initiated_type, c.domain_type, c.domain_classification from report_contact c
        """
    }

    private func readContacts(_ st: Statement) throws -> [ReportContactRow] {
        defer { st.reset() }
        var out: [ReportContactRow] = []
        while try st.step() {
            guard let imp = st.text(0), let app = st.text(1), let dom = st.text(2) else {
                throw StorageError.invalidData("contact row")
            }
            out.append(
                ReportContactRow(
                    importId: imp, appId: app, domain: dom, domainOwner: st.text(3), hits: st.int(4),
                    firstSeen: st.isNull(5) ? nil : Date(timeIntervalSince1970: st.double(5)),
                    lastSeen: st.isNull(6) ? nil : Date(timeIntervalSince1970: st.double(6)),
                    initiatedType: st.text(7), domainType: st.optInt(8), domainClassification: st.optInt(9)))
        }
        return out
    }
}
