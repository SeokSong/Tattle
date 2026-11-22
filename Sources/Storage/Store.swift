import CryptoKit
import Domains
import Flows
import Foundation
import PCAPNG
import PacketDecoder

// never log addresses, hostnames or the device id.

public struct CaptureSession: Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var endReason: String?
    public var source: String
    public var deviceHash: String?
    public var deviceName: String?
    public var watchVersion: String

    public init(
        id: UUID, startedAt: Date, endedAt: Date? = nil, endReason: String? = nil, source: String,
        deviceHash: String? = nil, deviceName: String? = nil, watchVersion: String
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.source = source
        self.deviceHash = deviceHash
        self.deviceName = deviceName
        self.watchVersion = watchVersion
    }
}

private let schemaVersion = 2

/// the version 1 schema, frozen. never edit: change the schema by adding a migration
private let schemaV1SQL = """
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

/// migrations keyed by the version they produce. one bump per milestone
private let migrations: [Int: [String]] = [
    2: [
        "alter table flow add column started_midstream integer not null default 0",
        "alter table flow add column ech integer not null default 0",
        "alter table session add column gap_count integer not null default 0",
        "alter table session add column max_gap_ms integer not null default 0",
        "alter table session add column kernel_dropped integer",
        "alter table session add column save_failures integer not null default 0",
        "alter table session add column unsaved_flows integer not null default 0",
    ]
]

public struct SessionStats: Equatable, Sendable {
    public var gapCount: Int
    public var maxGapMs: Int
    /// tcpdump's "packets dropped by kernel"; nil = unknown
    public var kernelDropped: Int?
    public var saveFailures: Int
    public var unsavedFlows: Int

    public init(
        gapCount: Int = 0, maxGapMs: Int = 0, kernelDropped: Int? = nil, saveFailures: Int = 0, unsavedFlows: Int = 0
    ) {
        self.gapCount = gapCount
        self.maxGapMs = maxGapMs
        self.kernelDropped = kernelDropped
        self.saveFailures = saveFailures
        self.unsavedFlows = unsavedFlows
    }
}

public final class Store {
    private let db: Database

    /// creates directories with 0700 and the file with 0600, runs migrations
    public convenience init(path: URL) throws {
        try self.init(path: path, migrations: migrations)
    }

    /// `migrations` is replaceable so tests can inject a failing step
    init(path: URL, migrations: [Int: [String]]) throws {
        let fm = FileManager.default
        var linkInfo = stat()
        if lstat(path.path, &linkInfo) == 0, (linkInfo.st_mode & S_IFMT) == S_IFLNK {
            throw StorageError.io("database path is a symbolic link")
        }
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: path.path) {
            guard fm.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw StorageError.io("could not create database file")
            }
        }
        db = try Database(path: path.path)
        try db.exec("pragma journal_mode = wal; pragma synchronous = normal; pragma foreign_keys = on; pragma secure_delete = on;")
        try migrate(migrations)
    }

    public static func defaultPath() -> URL {
        defaultPath(base: nil)
    }

    /// base is injectable for tests; nil means the user's Application Support directory
    static func defaultPath(base: URL?) -> URL {
        AppIdentity.supportDirectory(base: base).appendingPathComponent("watch.sqlite")
    }

    private func migrate(_ steps: [Int: [String]]) throws {
        let probe = try db.statement("select count(*) from sqlite_master where type = 'table' and name = 'meta'")
        _ = try probe.step()
        let exists = probe.int(0) > 0
        probe.reset()
        if exists {
            guard let found = try schemaVersionValue() else { throw StorageError.invalidData("schema version") }
            if found > schemaVersion { throw StorageError.newerSchema(found: found, supported: schemaVersion) }
        }
        try db.transaction {
            var version = 1
            if exists {
                version = try schemaVersionValue() ?? 1
            } else {
                // fresh database: version 1, then every migration, in this one transaction
                try db.exec(schemaV1SQL)
                var salt = [UInt8](repeating: 0, count: 16)
                for i in salt.indices { salt[i] = UInt8.random(in: 0...255) }
                let ins = try db.statement("insert into meta(key, value) values (?, ?)")
                ins.bind(1, "schema_version"); ins.bind(2, "1"); try ins.run()
                ins.bind(1, "install_salt"); ins.bind(2, hex(salt)); try ins.run()
            }
            while version < schemaVersion {
                version += 1
                for sql in steps[version] ?? [] { try db.exec(sql) }
                let up = try db.statement("update meta set value = ? where key = 'schema_version'")
                up.bind(1, String(version)); try up.run()
            }
        }
    }

    // MARK: sessions

    public func beginSession(_ s: CaptureSession) throws {
        let st = try db.statement(
            """
            insert into session(id, started_at, ended_at, end_reason, source, device_hash, device_name, watch_version)
            values (?, ?, ?, ?, ?, ?, ?, ?)
            """)
        st.bind(1, s.id.uuidString)
        st.bind(2, s.startedAt.timeIntervalSince1970)
        st.bind(3, s.endedAt?.timeIntervalSince1970)
        st.bind(4, s.endReason)
        st.bind(5, s.source)
        st.bind(6, s.deviceHash)
        st.bind(7, s.deviceName)
        st.bind(8, s.watchVersion)
        try st.run()
    }

    public func endSession(id: UUID, at: Date, reason: String) throws {
        let st = try db.statement("update session set ended_at = ?, end_reason = ? where id = ?")
        st.bind(1, at.timeIntervalSince1970)
        st.bind(2, reason)
        st.bind(3, id.uuidString)
        try st.run()
    }

    /// sessions with no end are closed as interrupted. the end time is the last flow seen, or the start
    public func markInterruptedSessions() throws {
        try db.exec(
            """
            update session set end_reason = 'interrupted',
              ended_at = coalesce((select max(last_seen) from flow where flow.session_id = session.id), started_at)
            where ended_at is null
            """)
    }

    public func sessions() throws -> [CaptureSession] {
        let st = try db.statement(
            """
            select id, started_at, ended_at, end_reason, source, device_hash, device_name, watch_version
            from session order by started_at, id
            """)
        defer { st.reset() }
        var out: [CaptureSession] = []
        while try st.step() {
            guard let id = st.text(0).flatMap(UUID.init(uuidString:)) else {
                throw StorageError.invalidData("session id")
            }
            out.append(
                CaptureSession(
                    id: id, startedAt: Date(timeIntervalSince1970: st.double(1)),
                    endedAt: st.isNull(2) ? nil : Date(timeIntervalSince1970: st.double(2)),
                    endReason: st.text(3), source: st.text(4) ?? "", deviceHash: st.text(5),
                    deviceName: st.text(6), watchVersion: st.text(7) ?? ""))
        }
        return out
    }

    // MARK: save

    /// one transaction: upserts the flows and replaces their tally rows, appends the domains
    public func save(flows: [Flow], domains: [DomainObservation], session: UUID) throws {
        let sid = session.uuidString
        try db.transaction {
            let upsert = try db.statement(
                """
                insert into flow(id, session_id, transport, local_addr, local_port, remote_addr, remote_port,
                  interface, first_seen, last_seen, packets_in, packets_out, ip_bytes_in, ip_bytes_out,
                  payload_bytes_in, payload_bytes_out, unknown_direction, server_name, end_reason, started_midstream, ech)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                on conflict(id) do update set
                  interface = excluded.interface, first_seen = excluded.first_seen, last_seen = excluded.last_seen,
                  packets_in = excluded.packets_in, packets_out = excluded.packets_out,
                  ip_bytes_in = excluded.ip_bytes_in, ip_bytes_out = excluded.ip_bytes_out,
                  payload_bytes_in = excluded.payload_bytes_in, payload_bytes_out = excluded.payload_bytes_out,
                  unknown_direction = excluded.unknown_direction, server_name = excluded.server_name,
                  end_reason = excluded.end_reason, started_midstream = excluded.started_midstream,
                  ech = excluded.ech
                """)
            let clear = try db.statement("delete from flow_process where flow_id = ?")
            let tally = try db.statement(
                """
                insert into flow_process(flow_id, process_name, process_id, effective_name, effective_id, packets)
                values (?, ?, ?, ?, ?, ?)
                """)
            for f in flows {
                let fid = f.id.uuidString
                upsert.bind(1, fid)
                upsert.bind(2, sid)
                upsert.bind(3, transportCode(f.key.transport))
                upsert.bind(4, blob: addrBytes(f.key.localAddress))
                upsert.bind(5, Int(f.key.localPort))
                upsert.bind(6, blob: addrBytes(f.key.remoteAddress))
                upsert.bind(7, Int(f.key.remotePort))
                upsert.bind(8, f.interface)
                upsert.bind(9, f.firstSeen.timeIntervalSince1970)
                upsert.bind(10, f.lastSeen.timeIntervalSince1970)
                upsert.bind(11, f.packetsIn)
                upsert.bind(12, f.packetsOut)
                upsert.bind(13, f.ipBytesIn)
                upsert.bind(14, f.ipBytesOut)
                upsert.bind(15, f.payloadBytesIn)
                upsert.bind(16, f.payloadBytesOut)
                upsert.bind(17, f.unknownDirectionPackets)
                upsert.bind(18, f.serverName)
                upsert.bind(19, f.endReason?.rawValue)
                upsert.bind(20, Int(f.startedMidstream ? 1 : 0))
                upsert.bind(21, Int(f.echSeen ? 1 : 0))
                try upsert.run()

                clear.bind(1, fid)
                try clear.run()
                for (pair, count) in f.tally {
                    tally.bind(1, fid)
                    tally.bind(2, pair.processName)
                    tally.bind(3, pair.processID.map(Int.init))
                    tally.bind(4, pair.effectiveName)
                    tally.bind(5, pair.effectiveID.map(Int.init))
                    tally.bind(6, count)
                    try tally.run()
                }
            }

            guard !domains.isEmpty else { return }
            let insDomain = try db.statement(
                """
                insert into domain(session_id, time, source, hostname, cname_chain, ttl, flow_id,
                  process_name, process_id, effective_name, effective_id)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let insAddr = try db.statement("insert into domain_address(domain_id, addr) values (?, ?)")
            let findFlow = try db.statement(
                """
                select id from flow where session_id = ? and transport = ? and local_addr = ? and local_port = ?
                  and remote_addr = ? and remote_port = ?
                """)
            for d in domains {
                var flowID: String?
                if let k = d.flowKey {
                    findFlow.bind(1, sid)
                    findFlow.bind(2, transportCode(k.transport))
                    findFlow.bind(3, blob: addrBytes(k.localAddress))
                    findFlow.bind(4, Int(k.localPort))
                    findFlow.bind(5, blob: addrBytes(k.remoteAddress))
                    findFlow.bind(6, Int(k.remotePort))
                    if try findFlow.step() { flowID = findFlow.text(0) }
                    findFlow.reset()
                }
                insDomain.bind(1, sid)
                insDomain.bind(2, d.time.timeIntervalSince1970)
                insDomain.bind(3, d.source.rawValue)
                insDomain.bind(4, d.hostname)
                insDomain.bind(5, d.cnameChain.isEmpty ? nil : try jsonString(d.cnameChain))
                insDomain.bind(6, d.ttl.map(Int.init))
                insDomain.bind(7, flowID)
                insDomain.bind(8, d.process?.name)
                insDomain.bind(9, d.process.map { Int($0.pid) })
                insDomain.bind(10, d.effectiveProcess?.name)
                insDomain.bind(11, d.effectiveProcess.map { Int($0.pid) })
                try insDomain.run()
                let rowID = db.lastInsertRowID
                for a in d.addresses {
                    insAddr.bind(1, rowID)
                    insAddr.bind(2, blob: addrBytes(a))
                    try insAddr.run()
                }
            }
        }
    }

    // MARK: session stats

    public func setSessionStats(id: UUID, _ stats: SessionStats) throws {
        let st = try db.statement(
            """
            update session set gap_count = ?, max_gap_ms = ?, kernel_dropped = ?, save_failures = ?, unsaved_flows = ?
            where id = ?
            """)
        st.bind(1, stats.gapCount)
        st.bind(2, stats.maxGapMs)
        st.bind(3, stats.kernelDropped)
        st.bind(4, stats.saveFailures)
        st.bind(5, stats.unsavedFlows)
        st.bind(6, id.uuidString)
        try st.run()
    }

    public func sessionStats(id: UUID) throws -> SessionStats {
        let st = try db.statement(
            "select gap_count, max_gap_ms, kernel_dropped, save_failures, unsaved_flows from session where id = ?")
        st.bind(1, id.uuidString)
        defer { st.reset() }
        guard try st.step() else { throw StorageError.invalidData("no such session") }
        return SessionStats(
            gapCount: st.int(0), maxGapMs: st.int(1), kernelDropped: st.optInt(2), saveFailures: st.int(3),
            unsavedFlows: st.int(4))
    }

    // MARK: retention

    /// deletes sessions that ended more than `olderThan` seconds ago. flows, tally and domains cascade
    public func expire(olderThan: TimeInterval) throws {
        let st = try db.statement("delete from session where ended_at is not null and ended_at < ?")
        st.bind(1, Date().timeIntervalSince1970 - olderThan)
        try st.run()
        // secure_delete overwrites freed pages; truncating the wal removes its copies of them
        try db.exec("pragma wal_checkpoint(TRUNCATE)")
    }

    /// removes every session (the install salt stays). then the wal is emptied and the file vacuumed,
    /// so no deleted content is left in either file
    public func deleteAll() throws {
        try db.exec("delete from session")
        try db.exec("pragma wal_checkpoint(TRUNCATE)")
        try db.exec("vacuum")
        try db.exec("pragma wal_checkpoint(TRUNCATE)")
    }

    // MARK: reading

    public func flows(session: UUID) throws -> [Flow] {
        let sid = session.uuidString
        let st = try db.statement(
            """
            select id, transport, local_addr, local_port, remote_addr, remote_port, interface, first_seen, last_seen,
              packets_in, packets_out, ip_bytes_in, ip_bytes_out, payload_bytes_in, payload_bytes_out,
              unknown_direction, server_name, end_reason, started_midstream, ech
            from flow where session_id = ? order by first_seen, id
            """)
        st.bind(1, sid)
        defer { st.reset() }
        var out: [Flow] = []
        var index: [UUID: Int] = [:]
        while try st.step() {
            guard let id = st.text(0).flatMap(UUID.init(uuidString:)),
                let local = address(st.blob(2)), let remote = address(st.blob(4))
            else { throw StorageError.invalidData("flow row") }
            let key = FlowKey(
                transport: transport(st.int(1)), localAddress: local, localPort: UInt16(truncatingIfNeeded: st.int(3)),
                remoteAddress: remote, remotePort: UInt16(truncatingIfNeeded: st.int(5)))
            var f = Flow(
                id: id, key: key, interface: st.text(6) ?? "", at: Date(timeIntervalSince1970: st.double(7)))
            f.lastSeen = Date(timeIntervalSince1970: st.double(8))
            f.packetsIn = st.int(9)
            f.packetsOut = st.int(10)
            f.ipBytesIn = st.int(11)
            f.ipBytesOut = st.int(12)
            f.payloadBytesIn = st.int(13)
            f.payloadBytesOut = st.int(14)
            f.unknownDirectionPackets = st.int(15)
            f.serverName = st.text(16)
            f.endReason = st.text(17).flatMap(FlowEndReason.init(rawValue:))
            f.startedMidstream = st.int(18) != 0
            f.echSeen = st.int(19) != 0
            index[id] = out.count
            out.append(f)
        }

        let rows = try db.statement(
            """
            select fp.flow_id, fp.process_name, fp.process_id, fp.effective_name, fp.effective_id, fp.packets
            from flow_process fp join flow f on f.id = fp.flow_id where f.session_id = ?
            """)
        rows.bind(1, sid)
        defer { rows.reset() }
        while try rows.step() {
            guard let id = rows.text(0).flatMap(UUID.init(uuidString:)), let i = index[id] else { continue }
            let pair = ProcessPair(
                rows.text(1), rows.optInt(2).map { UInt32(truncatingIfNeeded: $0) }, rows.text(3),
                rows.optInt(4).map { UInt32(truncatingIfNeeded: $0) })
            out[i].tally[pair] = rows.int(5)
        }
        return out
    }

    /// packets per tally row. ip bytes are the flow's ip bytes shared out by packet count, since the
    /// flow only stores byte totals
    public func processTotals(session: UUID) throws -> [(ProcessPair, packets: Int, ipBytes: Int)] {
        let st = try db.statement(
            """
            select fp.process_name, fp.process_id, fp.effective_name, fp.effective_id, sum(fp.packets),
              sum(fp.packets * 1.0 * (f.ip_bytes_in + f.ip_bytes_out) / max(f.packets_in + f.packets_out, 1))
            from flow_process fp join flow f on f.id = fp.flow_id where f.session_id = ?
            group by fp.process_name, fp.process_id, fp.effective_name, fp.effective_id
            order by sum(fp.packets) desc
            """)
        st.bind(1, session.uuidString)
        defer { st.reset() }
        var out: [(ProcessPair, packets: Int, ipBytes: Int)] = []
        while try st.step() {
            let pair = ProcessPair(
                st.text(0), st.optInt(1).map { UInt32(truncatingIfNeeded: $0) }, st.text(2),
                st.optInt(3).map { UInt32(truncatingIfNeeded: $0) })
            out.append((pair, st.int(4), Int(st.double(5).rounded())))
        }
        return out
    }

    public func domains(session: UUID) throws -> [DomainObservation] {
        let st = try db.statement(
            """
            select d.id, d.time, d.source, d.hostname, d.cname_chain, d.ttl,
              d.process_name, d.process_id, d.effective_name, d.effective_id,
              f.transport, f.local_addr, f.local_port, f.remote_addr, f.remote_port
            from domain d left join flow f on f.id = d.flow_id
            where d.session_id = ? order by d.time, d.id
            """)
        st.bind(1, session.uuidString)
        defer { st.reset() }
        let addrs = try db.statement("select addr from domain_address where domain_id = ? order by rowid")
        var out: [DomainObservation] = []
        while try st.step() {
            guard let source = st.text(2).flatMap(DomainObservation.Source.init(rawValue:)) else {
                throw StorageError.invalidData("domain source")
            }
            var list: [IPAddress] = []
            addrs.bind(1, st.int(0))
            while try addrs.step() {
                if let a = address(addrs.blob(0)) { list.append(a) }
            }
            addrs.reset()
            var key: FlowKey?
            if !st.isNull(10), let l = address(st.blob(11)), let r = address(st.blob(13)) {
                key = FlowKey(
                    transport: transport(st.int(10)), localAddress: l, localPort: UInt16(truncatingIfNeeded: st.int(12)),
                    remoteAddress: r, remotePort: UInt16(truncatingIfNeeded: st.int(14)))
            }
            out.append(
                DomainObservation(
                    time: Date(timeIntervalSince1970: st.double(1)), source: source, hostname: st.text(3) ?? "",
                    cnameChain: try st.text(4).map(parseJSONStrings) ?? [], addresses: list,
                    ttl: st.optInt(5).map { UInt32(truncatingIfNeeded: $0) }, flowKey: key,
                    process: process(st.optInt(7), st.text(6)), effectiveProcess: process(st.optInt(9), st.text(8))))
        }
        return out
    }

    // MARK: device hash

    /// sha256(install salt || udid) as hex. the udid is never stored
    public func deviceHash(udid: String) throws -> String {
        let st = try db.statement("select value from meta where key = 'install_salt'")
        defer { st.reset() }
        guard try st.step(), let saltHex = st.text(0) else { throw StorageError.invalidData("salt") }
        var data = Data(unhex(saltHex))
        data.append(Data(udid.utf8))
        return hex(Array(SHA256.hash(data: data)))
    }

    // MARK: test support

    func rowCount(table: String) throws -> Int {
        let st = try Statement(db: db, sql: "select count(*) from \(table)")
        _ = try st.step()
        return st.int(0)
    }

    func schemaVersionValue() throws -> Int? {
        let st = try db.statement("select value from meta where key = 'schema_version'")
        defer { st.reset() }
        return try st.step() ? st.text(0).flatMap(Int.init) : nil
    }
}

// MARK: encoding helpers

private func process(_ pid: Int?, _ name: String?) -> PCAPNGProcess? {
    pid.map { PCAPNGProcess(pid: UInt32(truncatingIfNeeded: $0), name: name) }
}

private func transportCode(_ t: Transport) -> Int {
    switch t {
    case .tcp: return 6
    case .udp: return 17
    case .other(let n): return Int(n)
    }
}

private func transport(_ code: Int) -> Transport {
    switch code {
    case 6: return .tcp
    case 17: return .udp
    default: return .other(UInt8(truncatingIfNeeded: code))
    }
}

/// ipv4 as 4 bytes, ipv6 as 16, big-endian
func addrBytes(_ a: IPAddress) -> [UInt8] {
    switch a {
    case .v4(let v):
        return (0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(24 - 8 * $0)) }
    case .v6(let hi, let lo):
        return (0..<8).map { UInt8(truncatingIfNeeded: hi >> UInt64(56 - 8 * $0)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: lo >> UInt64(56 - 8 * $0)) }
    }
}

func address(_ b: [UInt8]) -> IPAddress? {
    switch b.count {
    case 4:
        return .v4(b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    case 16:
        return .v6(
            hi: b[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) },
            lo: b[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    default:
        return nil
    }
}

private func jsonString(_ list: [String]) throws -> String {
    let data = try JSONEncoder().encode(list)
    return String(decoding: data, as: UTF8.self)
}

private func parseJSONStrings(_ s: String) throws -> [String] {
    try JSONDecoder().decode([String].self, from: Data(s.utf8))
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func unhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = s.makeIterator()
    while let a = it.next(), let b = it.next(), let v = UInt8(String([a, b]), radix: 16) { out.append(v) }
    return out
}
