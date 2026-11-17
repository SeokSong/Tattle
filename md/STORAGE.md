# Storage

**Status:** Done (2026-11-16). `Sources/Storage`, SQLite3 directly, 9 tests. 10,000 flows save in 0.1 s debug. Notes: `markInterruptedSessions` sets `ended_at` from the last flow (no clock); `save` upserts flows but appends domains, so callers pass each observation once; `processTotals` shares a flow's bytes across its tally rows by packet count (approximate); `deleteAll` keeps the salt.

## Purpose

- Save sessions, flows and domain records on the Mac as they happen (I7)
- Keep them 7 days, or until the user deletes them (N2)
- Nothing leaves the machine (N4)

## What is stored

| Entity | Stored | Notes |
|---|---|---|
| CaptureSession | Yes | Start, end, end reason, hashed device id, device name |
| NetworkFlow | Yes | With process tally and server name |
| DomainObservation | Yes | DNS and SNI |
| Packet | **No** | Memory only. Diagnostic capture is a separate opt-in file ([CAPTURE.md](CAPTURE.md)) |
| App identity | No | Worked out when reading ([ATTRIBUTION.md](ATTRIBUTION.md)) |

## Retention

- Default 7 days. Same window as Apple's App Privacy Report
- Expire whole sessions: delete a session once it ended more than 7 days ago, with all its flows and domains
    - Avoids half-deleted sessions whose totals no longer add up
- "Delete all" in Settings, any time
- Retention period is a setting, so it can change without a redesign
- Later (V3): daily summaries kept longer, if history is needed

## Write pattern

- Batch writes every few seconds during capture
- One transaction per batch, so a crash loses at most one batch
- Unfinished sessions are closed as "interrupted" on next launch

## Size

- Not measured yet. Rough estimate: 100–200 bytes per flow, a few MB per hour of capture
- Measure on the fixtures once flows exist

## Decision: SQLite through the system library

| Option | For | Against |
|---|---|---|
| **SQLite (`import SQLite3`)** | Ships with macOS and iOS, no dependency, works inside the App Sandbox, full control of batching | Verbose; needs a thin wrapper |
| GRDB | Mature Swift wrapper | A third-party dependency to vet for App Store review and to keep updated |
| SwiftData | Apple's | Weak control over batching, macOS 14+, schema migrations are opaque |

- Chosen: SQLite3 directly, with a small wrapper (`~150 lines`: open, exec, prepared statement bind/step). Zero dependencies keeps the review surface and cost at nothing, and the same code works on iOS later

## Implementation spec

Target `Storage`, depends on `Flows`, `Domains`, `PacketDecoder`. Links `sqlite3` (`linkerSettings: [.linkedLibrary("sqlite3")]`).

### Schema (version 1)

```sql
pragma journal_mode = wal; pragma synchronous = normal; pragma foreign_keys = on;

create table meta (key text primary key, value text);          -- schema_version, install_salt

create table session (
  id text primary key, started_at real not null, ended_at real,
  end_reason text,                     -- stopped | interrupted | error
  source text not null,                -- rvi | file
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
  cname_chain text,                     -- json array
  ttl integer, flow_id text, process_name text, process_id integer,
  effective_name text, effective_id integer);
create index domain_session_host on domain(session_id, hostname);

create table domain_address (domain_id integer not null references domain(id) on delete cascade, addr blob not null);
create index domain_address_addr on domain_address(addr);
```

- Addresses as 4- or 16-byte blobs, so they index and compare without parsing
- Times as unix seconds (`real`)

### API

```swift
public final class Store {
    public init(path: URL) throws                 // creates dirs with 0700, file 0600, runs migrations
    public static func defaultPath() -> URL       // ~/Library/Application Support/Watch/watch.sqlite
    public func beginSession(_ s: CaptureSession) throws
    public func endSession(id: UUID, at: Date, reason: String) throws
    public func save(flows: [Flow], domains: [DomainObservation], session: UUID) throws   // one transaction, upsert flows + replace their tally rows
    public func markInterruptedSessions() throws  // on launch: ended_at is null → interrupted
    public func expire(olderThan: TimeInterval) throws   // deletes sessions by ended_at, cascades
    public func deleteAll() throws
    public func sessions() throws -> [CaptureSession]
    public func flows(session: UUID) throws -> [Flow]
    public func processTotals(session: UUID) throws -> [(ProcessPair, packets: Int, ipBytes: Int)]
    public func domains(session: UUID) throws -> [DomainObservation]
    public func deviceHash(udid: String) throws -> String   // sha256(salt || udid), salt made once, stored in meta
}
```

- All calls are synchronous and the class is used from one actor (the pipeline); mark it `@unchecked Sendable` with an internal lock, or keep it non-Sendable and owned by the pipeline actor. Choose the latter
- `save` uses prepared statements kept for the life of the store; one `begin`/`commit` per call

### Privacy

- File permissions 0600; directory 0700
- No raw packets, no payload bytes, no UDID; `device_hash` only
- Encryption at rest: rely on FileVault in V1, noted in the privacy text

### Tests

- Open twice: schema created once, version stays 1
- `save` then `flows(session:)` round-trips every field, including tally rows and both address types
- `save` the same flow twice updates in place (no duplicate rows)
- Session left open → `markInterruptedSessions` sets reason `interrupted`
- `expire` removes a whole old session and keeps a recent one; the cascade removes its flows, tally rows, domains, addresses
- `deleteAll` leaves all tables empty
- `deviceHash` is stable across reopen and differs between two stores (different salt)
- Permission bits on the created file

### Acceptance

- `swift test` green; saving 10,000 flows in one call takes < 1 s

## See also

[FLOWS.md](FLOWS.md) · [DOMAINS.md](DOMAINS.md) · [APP.md](APP.md)
