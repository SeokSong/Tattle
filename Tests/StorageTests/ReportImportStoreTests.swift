import Foundation
import SQLite3
import Testing

@testable import Storage

private func tempPath() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("tattle-import-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("watch.sqlite")
}

private func cleanup(_ path: URL) {
    try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
}

private let day: TimeInterval = 86400
private let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 30 * day).rounded())

private func at(_ days: Double) -> Date { base.addingTimeInterval(days * day) }

private func importRow(
    sha: String = UUID().uuidString, start: Double, end: Double, importedAt: Date = Date()
) -> ReportImportRow {
    ReportImportRow(
        fileSHA256: sha, periodStart: at(start), periodEnd: at(end), importedAt: importedAt, linesRead: 10,
        recordsKept: 8, malformed: 1, unknownTypes: 1, formatVersion: 4)
}

private func contacts(_ row: ReportImportRow, count: Int = 2, domain: String = "ads.example.test") -> [ReportContactRow] {
    (0..<count).map { i in
        ReportContactRow(
            importId: row.id, appId: "com.example.app\(i)", domain: domain, domainOwner: i == 0 ? "Example Owner" : nil,
            hits: 3 + i, firstSeen: row.periodStart, lastSeen: row.periodEnd, initiatedType: "AppInitiated",
            domainType: 1, domainClassification: i == 0 ? 2 : nil)
    }
}

private func tables(_ store: Store) throws -> [String] {
    let st = try store.db.statement("select name from sqlite_master where type = 'table' and name not like 'sqlite_%'")
    defer { st.reset() }
    var out: [String] = []
    while try st.step() { out.append(st.text(0) ?? "") }
    return out
}

@Test func importRoundTrips() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    var row = importRow(start: 0, end: 6)
    row.formatVersion = nil
    let cs = contacts(row)
    #expect(try store.saveImport(row, contacts: cs) == .stored(replaced: 0))
    let back = try store.imports()
    #expect(back.count == 1)
    #expect(back[0].id == row.id && back[0].fileSHA256 == row.fileSHA256)
    #expect(back[0].formatVersion == nil)
    #expect(back[0].linesRead == 10 && back[0].recordsKept == 8 && back[0].malformed == 1 && back[0].unknownTypes == 1)
    #expect(abs(back[0].periodEnd.timeIntervalSince(row.periodEnd)) < 0.001)
    #expect(try store.contacts(importId: row.id) == cs)
    #expect(try store.contacts(since: at(7)).isEmpty)
    #expect(try store.contacts(since: at(6)).count == 2)
}

@Test func emptyImportStoresNothing() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    #expect(try store.saveImport(importRow(start: 0, end: 1), contacts: []) == .empty)
    #expect(try store.rowCount(table: "report_import") == 0)
}

@Test func reimportSameHashIsNoOp() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let first = importRow(sha: "aaa", start: 0, end: 6, importedAt: at(10))
    try store.saveImport(first, contacts: contacts(first))
    let again = importRow(sha: "aaa", start: 0, end: 6, importedAt: at(11))
    #expect(try store.saveImport(again, contacts: contacts(again, count: 5)) == .duplicate)
    #expect(try store.rowCount(table: "report_import") == 1)
    #expect(try store.rowCount(table: "report_contact") == 2)
    #expect(try store.imports()[0].id == first.id)
    #expect(abs(try store.imports()[0].importedAt.timeIntervalSince(at(10))) < 0.001)
}

@Test func newerImportReplacesOverlappingOlderOnes() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let a = importRow(start: 0, end: 3), b = importRow(start: 10, end: 13), c = importRow(start: 20, end: 23)
    for r in [a, b, c] { try store.saveImport(r, contacts: contacts(r)) }
    // overlaps a and b, not c
    let n = importRow(start: 2, end: 14)
    #expect(try store.saveImport(n, contacts: contacts(n, count: 1)) == .stored(replaced: 2))
    #expect(Set(try store.imports().map(\.id)) == [n.id, c.id])
    #expect(try store.rowCount(table: "report_contact") == 3)
    #expect(try store.contacts(importId: a.id).isEmpty)
}

@Test func nonOverlappingOlderImportIsKept() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let a = importRow(start: 0, end: 3), n = importRow(start: 4, end: 7)
    try store.saveImport(a, contacts: contacts(a))
    #expect(try store.saveImport(n, contacts: contacts(n)) == .stored(replaced: 0))
    #expect(try store.imports().count == 2)
}

@Test func touchingPeriodsCountAsOverlapping() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let a = importRow(start: 0, end: 3), n = importRow(start: 3, end: 6)
    try store.saveImport(a, contacts: contacts(a))
    #expect(try store.saveImport(n, contacts: contacts(n)) == .stored(replaced: 1))
    #expect(try store.imports().map(\.id) == [n.id])
}

@Test func failedInsertKeepsTheReplacedImport() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let a = importRow(start: 0, end: 3)
    try store.saveImport(a, contacts: contacts(a))
    let n = importRow(start: 1, end: 4)
    // two rows with the same app and domain break the primary key part way through
    let dup = contacts(n, count: 1) + contacts(n, count: 1)
    #expect(throws: (any Error).self) { try store.saveImport(n, contacts: dup) }
    #expect(try store.imports().map(\.id) == [a.id])
    #expect(try store.contacts(importId: a.id).count == 2)
}

@Test func deleteImportBySha() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let a = importRow(sha: "s1", start: 0, end: 3)
    try store.saveImport(a, contacts: contacts(a))
    #expect(try store.deleteImport(sha256: "nope") == false)
    #expect(try store.deleteImport(sha256: "s1"))
    #expect(try store.rowCount(table: "report_import") == 0)
    #expect(try store.rowCount(table: "report_contact") == 0)
}

@Test func expireRemovesImportsByPeriodEnd() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let now = Date()
    func rel(_ d: Double) -> Date { now.addingTimeInterval(d * day) }
    let old = ReportImportRow(fileSHA256: "old", periodStart: rel(-15), periodEnd: rel(-8))
    let recent = ReportImportRow(fileSHA256: "new", periodStart: rel(-14.5 + 8), periodEnd: rel(-6))
    try store.saveImport(old, contacts: contacts(old))
    try store.saveImport(recent, contacts: contacts(recent))
    try store.expire(olderThan: 7 * day)
    #expect(try store.imports().map(\.id) == [recent.id])
    #expect(try store.rowCount(table: "report_contact") == 2)
    // a shorter retention removes the second one too
    try store.expire(olderThan: 3 * day)
    #expect(try store.imports().isEmpty)
    #expect(try store.rowCount(table: "report_contact") == 0)
}

@Test func deleteAllEmptiesEveryTable() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let sess = CaptureSession(id: UUID(), startedAt: Date(), source: "rvi", watchVersion: "0.1")
    try store.beginSession(sess)
    let r = importRow(start: 0, end: 3)
    try store.saveImport(r, contacts: contacts(r))
    try store.deleteAll()
    let names = try tables(store)
    #expect(names.contains("report_contact") && names.contains("report_import"))
    for t in names where t != "meta" { #expect(try store.rowCount(table: t) == 0, "\(t) still has rows") }
    #expect(try store.rowCount(table: "meta") == 2)
}

@Test func expireEmptiesEveryTableForOldData() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let r = ReportImportRow(
        fileSHA256: "x", periodStart: Date().addingTimeInterval(-20 * day), periodEnd: Date().addingTimeInterval(-10 * day))
    try store.saveImport(r, contacts: contacts(r))
    try store.expire(olderThan: 7 * day)
    for t in try tables(store) where t != "meta" { #expect(try store.rowCount(table: t) == 0, "\(t) still has rows") }
}

private func filesContain(_ path: URL, _ needle: String) throws -> Bool {
    for suffix in ["", "-wal"] {
        let f = URL(fileURLWithPath: path.path + suffix)
        guard FileManager.default.fileExists(atPath: f.path) else { continue }
        if try Data(contentsOf: f).range(of: Data(needle.utf8)) != nil { return true }
    }
    return false
}

@Test func importedDomainLeavesNoPlainTextAfterDeleteAllOrExpire() throws {
    let host = "secret-import-host.example"
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let r = importRow(start: 0, end: 3)
    try store.saveImport(r, contacts: contacts(r, domain: host))
    #expect(try filesContain(path, host))
    try store.deleteAll()
    #expect(try !filesContain(path, host))

    let old = ReportImportRow(
        fileSHA256: "o", periodStart: Date().addingTimeInterval(-20 * day), periodEnd: Date().addingTimeInterval(-10 * day))
    try store.saveImport(old, contacts: contacts(old, domain: host))
    #expect(try filesContain(path, host))
    try store.expire(olderThan: 7 * day)
    #expect(try !filesContain(path, host))
}

@Test func importOf100kRowsIsOneTransaction() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let r = importRow(start: 0, end: 6)
    let rows = (0..<100_000).map { i in
        ReportContactRow(importId: r.id, appId: "com.example.app\(i % 500)", domain: "h\(i).example.test", hits: 1)
    }
    let t = Date()
    try store.saveImport(r, contacts: rows)
    let secs = Date().timeIntervalSince(t)
    print("import of 100k rows: \(secs) s")
    #expect(try store.rowCount(table: "report_contact") == 100_000)
    #expect(secs < 20)
}

@Test func importRowsHaveNoAppPathOrFilePath() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    func columns(_ t: String) throws -> [String] {
        let st = try store.db.statement("select name from pragma_table_info('\(t)') order by cid")
        defer { st.reset() }
        var out: [String] = []
        while try st.step() { out.append(st.text(0) ?? "") }
        return out
    }
    #expect(
        try columns("report_import") == [
            "id", "file_sha256", "period_start", "period_end", "imported_at", "lines_read", "records_kept",
            "malformed", "unknown_types", "format_version",
        ])
    #expect(
        try columns("report_contact") == [
            "import_id", "app_id", "domain", "domain_owner", "hits", "first_seen", "last_seen", "initiated_type",
            "domain_type", "domain_classification",
        ])
}

// MARK: migration

/// the version 2 schema, written out literally (version 1 plus the milestone 2 columns)
private let v2Schema = """
    create table meta (key text primary key, value text);
    create table session (
      id text primary key, started_at real not null, ended_at real,
      end_reason text, source text not null,
      device_hash text, device_name text, watch_version text,
      gap_count integer not null default 0, max_gap_ms integer not null default 0, kernel_dropped integer,
      save_failures integer not null default 0, unsaved_flows integer not null default 0);
    create table flow (
      id text primary key, session_id text not null references session(id) on delete cascade,
      transport integer not null, local_addr blob not null, local_port integer not null,
      remote_addr blob not null, remote_port integer not null, interface text not null,
      first_seen real not null, last_seen real not null,
      packets_in integer, packets_out integer, ip_bytes_in integer, ip_bytes_out integer,
      payload_bytes_in integer, payload_bytes_out integer, unknown_direction integer,
      server_name text, end_reason text,
      started_midstream integer not null default 0, ech integer not null default 0);
    create index flow_session on flow(session_id, first_seen);
    create table flow_process (
      flow_id text not null references flow(id) on delete cascade,
      process_name text, process_id integer, effective_name text, effective_id integer,
      packets integer not null,
      primary key (flow_id, process_name, process_id, effective_name, effective_id));
    create table domain (
      id integer primary key, session_id text not null references session(id) on delete cascade,
      time real not null, source text not null, hostname text not null,
      cname_chain text,
      ttl integer, flow_id text, process_name text, process_id integer,
      effective_name text, effective_id integer);
    create index domain_session_host on domain(session_id, hostname);
    create table domain_address (
      domain_id integer not null references domain(id) on delete cascade, addr blob not null);
    create index domain_address_addr on domain_address(addr);
    insert into meta values ('schema_version', '2');
    insert into meta values ('install_salt', '00112233445566778899aabbccddeeff');
    insert into session(id, started_at, source, watch_version, gap_count)
      values ('11111111-1111-1111-1111-111111111111', 1763000000, 'rvi', '0.1', 4);
    insert into flow(id, session_id, transport, local_addr, local_port, remote_addr, remote_port, interface,
      first_seen, last_seen, server_name, started_midstream, ech)
      values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 6, x'0a000002',
      1024, x'5db8d800', 443, 'en0', 1763000000, 1763000005, 'old.example.test', 1, 1);
    """

private func buildV2Database(_ path: URL) throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    var h: OpaquePointer?
    #expect(sqlite3_open(path.path, &h) == SQLITE_OK)
    defer { sqlite3_close(h) }
    #expect(sqlite3_exec(h, v2Schema, nil, nil, nil) == SQLITE_OK)
}

@Test func versionTwoDatabaseMigratesToThree() throws {
    let path = tempPath()
    defer { cleanup(path) }
    try buildV2Database(path)
    let s = try Store(path: path)
    #expect(try s.schemaVersionValue() == 3)
    let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    #expect(try s.sessionStats(id: id).gapCount == 4)
    let flows = try s.flows(session: id)
    #expect(flows.count == 1 && flows[0].serverName == "old.example.test")
    #expect(flows[0].startedMidstream && flows[0].echSeen)
    #expect(try s.rowCount(table: "meta") == 2)
    #expect(try s.rowCount(table: "report_import") == 0)
    let r = importRow(start: 0, end: 1)
    #expect(try s.saveImport(r, contacts: contacts(r)) == .stored(replaced: 0))
}

@Test func versionThreeStepFailureRollsBack() throws {
    let path = tempPath()
    defer { cleanup(path) }
    try buildV2Database(path)
    let bad: [Int: [String]] = [
        3: ["create table report_import (id text primary key)", "this is not sql"]
    ]
    #expect(throws: (any Error).self) { _ = try Store(path: path, migrations: bad) }
    var h: OpaquePointer?
    #expect(sqlite3_open(path.path, &h) == SQLITE_OK)
    var st: OpaquePointer?
    sqlite3_prepare_v2(h, "select value from meta where key = 'schema_version'", -1, &st, nil)
    #expect(sqlite3_step(st) == SQLITE_ROW)
    #expect(String(cString: sqlite3_column_text(st, 0)) == "2")
    sqlite3_finalize(st)
    var st2: OpaquePointer?
    sqlite3_prepare_v2(h, "select count(*) from sqlite_master where name = 'report_import'", -1, &st2, nil)
    #expect(sqlite3_step(st2) == SQLITE_ROW)
    #expect(sqlite3_column_int(st2, 0) == 0)
    sqlite3_finalize(st2)
    sqlite3_close(h)
    let s = try Store(path: path)
    #expect(try s.schemaVersionValue() == 3)
}

@Test func olderOverlappingImportIsRefused() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let newer = importRow(start: 5, end: 12)
    try store.saveImport(newer, contacts: contacts(newer))
    let older = importRow(start: 0, end: 6)
    #expect(try store.saveImport(older, contacts: contacts(older)) == .olderThanStored(newestPeriodEnd: newer.periodEnd))
    #expect(try store.imports().map(\.id) == [newer.id])
    #expect(try store.rowCount(table: "report_contact") == 2)
    // touching also counts, and a non-overlapping older file is still stored
    let touching = importRow(start: 0, end: 5)
    #expect(try store.saveImport(touching, contacts: contacts(touching)) == .olderThanStored(newestPeriodEnd: newer.periodEnd))
    let apart = importRow(start: 0, end: 4)
    #expect(try store.saveImport(apart, contacts: contacts(apart)) == .stored(replaced: 0))
    #expect(try store.imports().count == 2)
}

@Test func equalPeriodEndReplaces() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let a = importRow(start: 0, end: 6)
    try store.saveImport(a, contacts: contacts(a))
    let b = importRow(start: 2, end: 6)
    #expect(try store.saveImport(b, contacts: contacts(b)) == .stored(replaced: 1))
    #expect(try store.imports().map(\.id) == [b.id])
}

@Test func deleteImportLeavesNoPlainTextInWalOrDatabase() throws {
    let host = "marker-delete-import.example"
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let r = importRow(sha: "del1", start: 0, end: 3)
    try store.saveImport(r, contacts: contacts(r, domain: host))
    #expect(try filesContain(path, host))  // the check can see the marker before deleting
    #expect(try store.deleteImport(sha256: "del1"))
    #expect(try !filesContain(path, host))
}

private final class StoreBox: @unchecked Sendable {
    let store: Store
    init(_ s: Store) { store = s }
}

@Test func secondStoreWaitsForTheWriteLockInsteadOfFailingBusy() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let a = StoreBox(try Store(path: path))
    let b = try Store(path: path)
    let holding = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    // the other writer holds its write transaction on another thread for a moment
    Thread.detachNewThread {
        try? a.store.db.transaction {
            holding.signal()
            Thread.sleep(forTimeInterval: 0.5)
        }
        done.signal()
    }
    holding.wait()
    let r = importRow(sha: "busy", start: 0, end: 2)
    #expect(try b.saveImport(r, contacts: contacts(r)) == .stored(replaced: 0))
    done.wait()
    #expect(try a.store.imports().count == 1)
}
