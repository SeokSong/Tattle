import Domains
import Flows
import Foundation
import PCAPNG
import PacketDecoder
import SQLite3
import Testing

@testable import Storage

private func tempPath() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("watch-storage-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("watch.sqlite")
}

private func cleanup(_ path: URL) {
    try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
}

private let t0 = Date(timeIntervalSince1970: 1_763_000_000)

private func session(started: Date = t0) -> CaptureSession {
    CaptureSession(
        id: UUID(), startedAt: started, source: "rvi", deviceHash: "abc", deviceName: "phone", watchVersion: "0.1")
}

private func v4Key(_ i: Int = 0, remotePort: UInt16 = 443) -> FlowKey {
    FlowKey(
        transport: .tcp, localAddress: .v4(0x0A00_0002), localPort: UInt16(1024 + i % 60000),
        remoteAddress: .v4(0x5DB8_D800 | UInt32(i % 256)), remotePort: remotePort)
}

private func makeFlow(_ key: FlowKey, at: TimeInterval = 0) -> Flow {
    var f = Flow(key: key, interface: "en0", at: t0.addingTimeInterval(at))
    f.lastSeen = t0.addingTimeInterval(at + 5.25)
    f.packetsIn = 3; f.packetsOut = 2
    f.ipBytesIn = 3000; f.ipBytesOut = 200
    f.payloadBytesIn = 2900; f.payloadBytesOut = 100
    f.unknownDirectionPackets = 1
    f.serverName = "example.test"
    f.endReason = .fin
    f.tally[ProcessPair("TikTok", 10, nil, nil)] = 3
    f.tally[ProcessPair("mDNSResponder", 212, "TikTok", 10)] = 1
    f.tally[.none] = 1
    return f
}

@Test func openTwiceKeepsSchemaOnce() throws {
    let path = tempPath()
    defer { cleanup(path) }
    var salt1 = ""
    do {
        let s = try Store(path: path)
        #expect(try s.schemaVersionValue() == 3)
        salt1 = try s.deviceHash(udid: "u")
    }
    let s = try Store(path: path)
    #expect(try s.schemaVersionValue() == 3)
    #expect(try s.rowCount(table: "meta") == 2)
    #expect(try s.deviceHash(udid: "u") == salt1)
}

@Test func roundTripsFlowsAndDomains() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let sess = session()
    try store.beginSession(sess)

    let f4 = makeFlow(v4Key())
    let key6 = FlowKey(
        transport: .udp, localAddress: .v6(hi: 0x2001_0DB8_0000_0001, lo: 2), localPort: 5000,
        remoteAddress: .v6(hi: 0xFE80_0000_0000_0000, lo: 0xFFFF_FFFF_FFFF_FFFF), remotePort: 443)
    var f6 = makeFlow(key6, at: 1)
    f6.serverName = nil
    f6.endReason = nil
    let dns = DomainObservation(
        time: t0, source: .dns, hostname: "a.example.test", cnameChain: ["b.example.test", "c.example.test"],
        addresses: [.v4(1), .v6(hi: 5, lo: 6)], ttl: 60, process: PCAPNGProcess(pid: 7, name: "TikTok"),
        effectiveProcess: PCAPNGProcess(pid: 8, name: nil))
    let sni = DomainObservation(time: t0, source: .sni, hostname: "example.test", flowKey: f4.key)
    try store.save(flows: [f4, f6], domains: [dns, sni], session: sess.id)

    let back = try store.flows(session: sess.id)
    #expect(back.count == 2)
    for (a, b) in zip([f4, f6], back) {
        #expect(a.id == b.id)
        #expect(a.key == b.key)
        #expect(a.interface == b.interface)
        #expect(a.firstSeen == b.firstSeen)
        #expect(a.lastSeen == b.lastSeen)
        #expect(a.packetsIn == b.packetsIn && a.packetsOut == b.packetsOut)
        #expect(a.ipBytesIn == b.ipBytesIn && a.ipBytesOut == b.ipBytesOut)
        #expect(a.payloadBytesIn == b.payloadBytesIn && a.payloadBytesOut == b.payloadBytesOut)
        #expect(a.unknownDirectionPackets == b.unknownDirectionPackets)
        #expect(a.serverName == b.serverName && a.endReason == b.endReason)
        #expect(a.tally == b.tally)
    }

    let doms = try store.domains(session: sess.id)
    #expect(doms.count == 2)
    let d = try #require(doms.first { $0.source == .dns })
    #expect(d.hostname == dns.hostname && d.cnameChain == dns.cnameChain && d.addresses == dns.addresses)
    #expect(d.ttl == 60 && d.process == dns.process && d.effectiveProcess == dns.effectiveProcess)
    #expect(d.flowKey == nil)
    let n = try #require(doms.first { $0.source == .sni })
    #expect(n.flowKey == f4.key && n.ttl == nil && n.cnameChain.isEmpty)

    let totals = try store.processTotals(session: sess.id)
    #expect(totals.map(\.packets).reduce(0, +) == 10)
    #expect(totals.first?.0 == ProcessPair("TikTok", 10, nil, nil) && totals.first?.packets == 6)
}

@Test func savingTwiceUpdatesInPlace() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let sess = session()
    try store.beginSession(sess)
    var f = makeFlow(v4Key())
    try store.save(flows: [f], domains: [], session: sess.id)
    f.packetsIn = 99
    f.tally = [ProcessPair("YouTube", 1, nil, nil): 99]
    try store.save(flows: [f], domains: [], session: sess.id)
    #expect(try store.rowCount(table: "flow") == 1)
    #expect(try store.rowCount(table: "flow_process") == 1)
    let back = try store.flows(session: sess.id)
    #expect(back.count == 1 && back[0].packetsIn == 99 && back[0].tally == f.tally)
}

@Test func interruptedSessions() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let open = session()
    let done = session()
    try store.beginSession(open)
    try store.beginSession(done)
    try store.endSession(id: done.id, at: t0.addingTimeInterval(10), reason: "stopped")
    try store.markInterruptedSessions()
    let all = try store.sessions()
    let o = try #require(all.first { $0.id == open.id })
    #expect(o.endReason == "interrupted" && o.endedAt != nil)
    let d = try #require(all.first { $0.id == done.id })
    #expect(d.endReason == "stopped" && d.endedAt == t0.addingTimeInterval(10))
    #expect(d.deviceName == "phone" && d.deviceHash == "abc" && d.watchVersion == "0.1" && d.source == "rvi")
}

private func populate(_ store: Store, _ s: CaptureSession) throws {
    try store.beginSession(s)
    let f = makeFlow(v4Key())
    let dns = DomainObservation(time: t0, source: .dns, hostname: "a.test", addresses: [.v4(1), .v4(2)])
    try store.save(flows: [f], domains: [dns], session: s.id)
}

@Test func expireRemovesWholeOldSessionOnly() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let old = session(), recent = session()
    try populate(store, old)
    try populate(store, recent)
    try store.endSession(id: old.id, at: Date().addingTimeInterval(-8 * 86400), reason: "stopped")
    try store.endSession(id: recent.id, at: Date().addingTimeInterval(-3600), reason: "stopped")
    try store.expire(olderThan: 7 * 86400)
    #expect(try store.sessions().map(\.id) == [recent.id])
    #expect(try store.flows(session: old.id).isEmpty)
    #expect(try store.rowCount(table: "flow") == 1)
    #expect(try store.rowCount(table: "flow_process") == 3)
    #expect(try store.rowCount(table: "domain") == 1)
    #expect(try store.rowCount(table: "domain_address") == 2)
}

@Test func deleteAllEmptiesTables() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    try populate(store, session())
    try store.deleteAll()
    for t in ["session", "flow", "flow_process", "domain", "domain_address", "report_import", "report_contact"] {
        #expect(try store.rowCount(table: t) == 0)
    }
}

@Test func deviceHashStableAndPerStore() throws {
    let p1 = tempPath(), p2 = tempPath()
    defer { cleanup(p1); cleanup(p2) }
    let h1 = try Store(path: p1).deviceHash(udid: "00008110-ABC")
    #expect(try Store(path: p1).deviceHash(udid: "00008110-ABC") == h1)
    #expect(try Store(path: p2).deviceHash(udid: "00008110-ABC") != h1)
    #expect(h1.count == 64 && !h1.contains("ABC"))
}

@Test func permissionBits() throws {
    let path = tempPath()
    defer { cleanup(path) }
    _ = try Store(path: path)
    let fm = FileManager.default
    let file = try fm.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
    let dir = try fm.attributesOfItem(atPath: path.deletingLastPathComponent().path)[.posixPermissions] as? Int
    #expect(file == 0o600)
    #expect(dir == 0o700)
}

@Test func saves10kFlowsFast() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let sess = session()
    try store.beginSession(sess)
    let flows = (0..<10_000).map { makeFlow(v4Key($0, remotePort: UInt16(1 + $0 / 256)), at: Double($0)) }
    let start = Date()
    try store.save(flows: flows, domains: [], session: sess.id)
    let elapsed = Date().timeIntervalSince(start)
    print("saved 10000 flows in \(String(format: "%.3f", elapsed)) s")
    #expect(try store.rowCount(table: "flow") == 10_000)
    #expect(try store.flows(session: sess.id).count == 10_000)
}

@Test func storeWorksThroughFlowStore() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store: any FlowStore = try Store(path: path)
    let sess = session()
    try store.beginSession(sess)
    try store.save(flows: [makeFlow(v4Key(1, remotePort: 443), at: 0)], domains: [], session: sess.id)
    try store.endSession(id: sess.id, at: Date(), reason: "captureStopped")
    let reader = try Store(path: path)
    #expect(try reader.flows(session: sess.id).count == 1)
}


@Test func storeRejectsSymlinkPath() throws {
    let real = tempPath()
    defer { cleanup(real) }
    try FileManager.default.createDirectory(
        at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
    let target = real.deletingLastPathComponent().appendingPathComponent("target.sqlite")
    let link = real.deletingLastPathComponent().appendingPathComponent("link.sqlite")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: StorageError.io("database path is a symbolic link")) { try Store(path: link) }
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

private let secretHost = "secret-host.example"

private func populateSecret(_ store: Store, _ s: CaptureSession) throws {
    try store.beginSession(s)
    var f = makeFlow(v4Key())
    f.serverName = secretHost
    let dns = DomainObservation(time: t0, source: .dns, hostname: secretHost, addresses: [.v4(1)])
    try store.save(flows: [f], domains: [dns], session: s.id)
}

private func databaseFilesContainHostname(_ path: URL) throws -> Bool {
    let needle = Data(secretHost.utf8)
    for suffix in ["", "-wal"] {
        let file = URL(fileURLWithPath: path.path + suffix)
        guard FileManager.default.fileExists(atPath: file.path) else { continue }
        if try Data(contentsOf: file).range(of: needle) != nil { return true }
    }
    return false
}

@Test func deleteAllLeavesNoPlainTextHostname() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    try populateSecret(store, session())
    #expect(try databaseFilesContainHostname(path))  // the check can see the name before deleting
    try store.deleteAll()
    #expect(try !databaseFilesContainHostname(path))
}

@Test func expireLeavesNoPlainTextHostname() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let old = session()
    try populateSecret(store, old)
    try store.endSession(id: old.id, at: Date().addingTimeInterval(-8 * 86400), reason: "stopped")
    #expect(try databaseFilesContainHostname(path))
    try store.expire(olderThan: 7 * 86400)
    #expect(try store.sessions().isEmpty)
    #expect(try !databaseFilesContainHostname(path))
}

@Test func deleteAllKeepsSchemaUsable() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let salt = try store.deviceHash(udid: "u")
    try populate(store, session())
    try store.deleteAll()
    #expect(try store.rowCount(table: "meta") == 2)
    #expect(try store.deviceHash(udid: "u") == salt)
    let next = session()
    try store.beginSession(next)
    try store.save(flows: [makeFlow(v4Key())], domains: [], session: next.id)
    #expect(try store.flows(session: next.id).count == 1)
    #expect(try Store(path: path).sessions().map(\.id) == [next.id])
}

@Test func deleteAllTimeOn5000Flows() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let store = try Store(path: path)
    let sess = session()
    try store.beginSession(sess)
    let flows = (0..<5_000).map { makeFlow(v4Key($0, remotePort: UInt16(1 + $0 / 256)), at: Double($0)) }
    try store.save(flows: flows, domains: [], session: sess.id)
    let start = Date()
    try store.deleteAll()
    print("deleteAll on 5000 flows took \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
    #expect(try store.rowCount(table: "flow") == 0)
}

// MARK: schema version 2

// version 1 schema copied literally, so the test does not depend on the app's code
private let v1Schema = """
    create table meta (key text primary key, value text);
    create table session (
      id text primary key, started_at real not null, ended_at real,
      end_reason text, source text not null,
      device_hash text, device_name text, watch_version text);
    create table flow (
      id text primary key, session_id text not null references session(id) on delete cascade,
      transport integer not null, local_addr blob not null, local_port integer not null,
      remote_addr blob not null, remote_port integer not null, interface text not null,
      first_seen real not null, last_seen real not null,
      packets_in integer, packets_out integer, ip_bytes_in integer, ip_bytes_out integer,
      payload_bytes_in integer, payload_bytes_out integer, unknown_direction integer,
      server_name text, end_reason text);
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
    """

private let oldSessionID = UUID()
private let oldFlowID = UUID()

private func buildV1Database(_ path: URL, version: String = "1") throws {
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    var h: OpaquePointer?
    #expect(sqlite3_open(path.path, &h) == SQLITE_OK)
    defer { sqlite3_close(h) }
    let sql =
        v1Schema + """
        insert into meta values ('schema_version', '\(version)');
        insert into meta values ('install_salt', '00112233445566778899aabbccddeeff');
        insert into session(id, started_at, source, watch_version)
          values ('\(oldSessionID.uuidString)', 1763000000, 'rvi', '0.1');
        insert into flow(id, session_id, transport, local_addr, local_port, remote_addr, remote_port, interface,
          first_seen, last_seen, packets_in, packets_out, ip_bytes_in, ip_bytes_out, payload_bytes_in,
          payload_bytes_out, unknown_direction, server_name, end_reason)
          values ('\(oldFlowID.uuidString)', '\(oldSessionID.uuidString)', 6, x'0a000002', 1024, x'5db8d800', 443,
          'en0', 1763000000, 1763000005, 3, 2, 3000, 200, 2900, 100, 0, 'old.test', 'fin');
        insert into flow_process values ('\(oldFlowID.uuidString)', 'TikTok', 10, null, null, 5);
        """
    #expect(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK)
}

@Test func versionOneDatabaseMigrates() throws {
    let path = tempPath()
    defer { cleanup(path) }
    try buildV1Database(path)
    let s = try Store(path: path)
    #expect(try s.schemaVersionValue() == 3)
    let flows = try s.flows(session: oldSessionID)
    #expect(flows.count == 1)
    #expect(flows[0].id == oldFlowID)
    #expect(flows[0].serverName == "old.test")
    #expect(flows[0].ipBytesIn == 3000)
    #expect(flows[0].tally[ProcessPair("TikTok", 10, nil, nil)] == 5)
    #expect(flows[0].startedMidstream == false)
    #expect(flows[0].echSeen == false)
    #expect(try s.sessionStats(id: oldSessionID) == SessionStats())
    #expect(try s.sessionStats(id: oldSessionID).kernelDropped == nil)
    // salt survives
    #expect(try s.rowCount(table: "meta") == 2)
}

@Test func freshDatabaseIsVersionThree() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let s = try Store(path: path)
    #expect(try s.schemaVersionValue() == 3)
    let sess = session()
    try s.beginSession(sess)
    var f = makeFlow(v4Key())
    f.startedMidstream = true
    f.echSeen = true
    try s.save(flows: [f], domains: [], session: sess.id)
    let back = try s.flows(session: sess.id)
    #expect(back.count == 1)
    #expect(back[0].startedMidstream)
    #expect(back[0].echSeen)
    // upsert updates the flags too
    f.echSeen = false
    try s.save(flows: [f], domains: [], session: sess.id)
    let again = try s.flows(session: sess.id)
    #expect(again[0].startedMidstream)
    #expect(!again[0].echSeen)
}

@Test func newerSchemaThrows() throws {
    let path = tempPath()
    defer { cleanup(path) }
    try buildV1Database(path, version: "4")
    #expect(throws: StorageError.newerSchema(found: 4, supported: 3)) {
        _ = try Store(path: path)
    }
}

@Test func sessionStatsRoundTrip() throws {
    let path = tempPath()
    defer { cleanup(path) }
    let s = try Store(path: path)
    let sess = session()
    try s.beginSession(sess)
    #expect(try s.sessionStats(id: sess.id) == SessionStats())
    let stats = SessionStats(gapCount: 2, maxGapMs: 41_000, kernelDropped: 7, saveFailures: 1, unsavedFlows: 0)
    try s.recordSessionStats(id: sess.id, stats)
    #expect(try s.sessionStats(id: sess.id) == stats)
}

@Test func migrationIsAtomic() throws {
    let path = tempPath()
    defer { cleanup(path) }
    try buildV1Database(path)
    let bad: [Int: [String]] = [
        2: ["alter table flow add column started_midstream integer not null default 0", "this is not sql"]
    ]
    #expect(throws: (any Error).self) { _ = try Store(path: path, migrations: bad) }
    // the half-applied step rolled back: still version 1, and a normal open migrates cleanly
    var h: OpaquePointer?
    #expect(sqlite3_open(path.path, &h) == SQLITE_OK)
    var st: OpaquePointer?
    sqlite3_prepare_v2(h, "select value from meta where key = 'schema_version'", -1, &st, nil)
    #expect(sqlite3_step(st) == SQLITE_ROW)
    #expect(String(cString: sqlite3_column_text(st, 0)) == "1")
    sqlite3_finalize(st)
    sqlite3_close(h)
    let s = try Store(path: path)
    #expect(try s.schemaVersionValue() == 3)
    #expect(try s.flows(session: oldSessionID).count == 1)
}
