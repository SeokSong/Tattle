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

### Schema (version 1, then migrations)

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

### Schema version 2 (migration)

Added with `alter table ... add column`; defaults make old rows valid. Category and hostname source are not stored: they are derived at read time.

| Table | Column | Type | Meaning |
|---|---|---|---|
| `flow` | `started_midstream` | `integer not null default 0` | TCP flow whose first packet had no SYN |
| `flow` | `ech` | `integer not null default 0` | ClientHello had the encrypted_client_hello extension |
| `session` | `gap_count` | `integer not null default 0` | Silences over 5 s in packet time |
| `session` | `max_gap_ms` | `integer not null default 0` | Longest gap |
| `session` | `kernel_dropped` | `integer` | tcpdump's "packets dropped by kernel"; null = unknown |
| `session` | `save_failures` | `integer not null default 0` | Throwing saves |
| `session` | `unsaved_flows` | `integer not null default 0` | Flows lost at the end |

- API: `SessionStats`, `Store.setSessionStats(id:_:)`, `Store.sessionStats(id:)`, `FlowStore.recordSessionStats(id:_:)`

### Schema version 3 (planned, Milestone 3)

For review before any code (Milestone 3, problem 0.1). One migration for the whole milestone. Only the App Privacy Report import is stored: company labels, categories and summaries are computed when read, with the current company data, and the data version is printed (no per-session copy).

| Table | Column | Type | Meaning |
|---|---|---|---|
| `report_import` | `id` | `text primary key` | One row per imported App Privacy Report file |
| | `file_sha256` | `text not null unique` | Importing the same file twice is a no-op |
| | `period_start` | `real not null` | Earliest `firstTimeStamp` in the file (Unix seconds) |
| | `period_end` | `real not null` | Latest `timeStamp` in the file |
| | `imported_at` | `real not null` | When it was imported |
| | `lines_read`, `records_kept`, `malformed`, `unknown_types` | `integer` | Import counts, shown to the user |
| | `format_version` | `integer` | The `v<number>` of the export's file name; null when the name has none. The import warns when it is not 4 |
| `report_contact` | `import_id` | `text not null`, references `report_import(id)`, cascade delete | Which import it came from |
| | `app_id` | `text not null` | The app's bundle id |
| | `domain` | `text not null` | Domain the app contacted, lower case, no trailing dot; can be an IP address literal (often, in a real export) |
| | `domain_owner` | `text` | Apple's owner name for the domain; often empty |
| | `hits` | `integer not null` | How many times, as counted by iOS |
| | `first_seen`, `last_seen` | `real` | First and last contact |
| | `initiated_type`, `domain_type`, `domain_classification` | `text`, `integer`, `integer` | Kept raw; meaning undocumented, never shown or interpreted |

- Primary key of `report_contact`: (`import_id`, `app_id`, `domain`); index on `app_id`
- **Combining records:** an export lists the same app and domain many times. They become one row: `hits` summed, `first_seen` the earliest, `last_seen` the latest, `domain_owner` the first non-empty value; for the three raw codes the value from the latest record is kept
- **Field names and rules** come from the verified export: see [PRIVACY_REPORT.md](PRIVACY_REPORT.md). `period_start` and `period_end` are taken from the kept network records only, as absolute times
- **Not stored** (owner decision): the report's `access` records (camera, location, contacts…) and the `context` field (the website a browser request was made in)
- **An import must contain at least one network record.** An empty file, or one where every line is malformed, stores nothing and reports why
- **Same file twice:** a file whose `file_sha256` is already stored is a no-op. Tattle reads the export; it never deletes or moves the user's original file
- **Overlapping exports** (owner decision): a newer import replaces every older import whose period overlaps it (Apple's newer export already contains those days). An older import that does not overlap is kept. This prevents counting the same contacts twice
- **Retention** (owner decision): imports follow the same retention setting as capture sessions (1, 3 or 7 days), counted from the report's `period_end`. `expire(olderThan:)` and `deleteAll()` get their own `delete from report_import` (contacts follow by cascade), and a test checks that `deleteAll()` empties every table
- **Data inventory:** bundle ids reveal which apps are installed, so the inventory and README get a row for imported reports when this ships
- The report's period is shown with its real dates (an export can cover fewer than 7 days)
- The migration adds the two tables and the index as `migrations[3]` (`create table`, `create index`); the old-database test builds the version 2 schema literally

### Migration rule

- One schema bump per milestone. Every bump has an old-database test (build the previous schema literally in the test, open with `Store`, check the data)
- `schemaV1SQL` is frozen; `migrations` maps a target version to its statements
- A fresh database runs V1 then every migration in one transaction; an existing one runs the missing steps in one transaction and updates `meta.schema_version`. A failing step rolls everything back
- A database with a higher version than the app supports throws `StorageError.newerSchema(found:supported:)`

- The support folder name comes from `AppIdentity` (`Tattle`). On first use, a real `Watch` folder in Application Support is moved to `Tattle` (a rename on the same volume, permissions kept). Nothing is overwritten: if `Tattle` already exists, or `Watch` is a symlink, both are left alone. The database file keeps its name `watch.sqlite`

### API

```swift
public final class Store {
    public init(path: URL) throws                 // creates dirs with 0700, file 0600, runs migrations
    public static func defaultPath() -> URL       // ~/Library/Application Support/Tattle/watch.sqlite
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

### FlowStore protocol

- `FlowStore` (`Sources/Storage/FlowStore.swift`) is `AnyObject` with `beginSession(_:)`, `save(flows:domains:session:)` and `endSession(id:at:reason:)`; `Store` conforms
- The pipeline depends on the protocol, so tests use a fake that fails on demand. A failed `save` must not lose flows: the pipeline requeues them (see PIPELINE.md)

### Deleting for real

- `Store.init` sets `pragma secure_delete = on`, so freed pages are overwritten with zeros
- `deleteAll()`: delete all sessions, `wal_checkpoint(TRUNCATE)`, `vacuum`, checkpoint again. No deleted hostname stays in the `.sqlite` or `-wal` file
- `expire(olderThan:)`: delete, then `wal_checkpoint(TRUNCATE)` only (no vacuum, to stay fast). The file keeps its size, but freed pages are zeroed
- The install salt (`meta`) is kept, so device hashes stay stable. Deleting it is out of scope

### Data inventory

Every place Tattle keeps data. Each later change that stores something new must add a row here and in the README.

| What | Where | Retention | Cleared by Delete all |
|---|---|---|---|
| Sessions, flows, per-process tallies, DNS answers, server names, mid-connection and ECH flags, per-session gap count and longest gap, kernel drop and save-failure counts (numbers only, no content) | `watch.sqlite` plus `-wal` and `-shm` (0600, folder 0700) | 7 days after a session ends | Yes (checkpoint and vacuum) |
| Salted device hash and device name | Same database | Same as sessions (install salt stays) | Sessions yes; the install salt stays |
| Diagnostic raw-packet files (opt-in) | App: `diagnostics/` next to the database. CLI: the path given to `--diagnostic` (created new, 0600) | App: 24 hours. CLI: user-managed | App files yes; CLI files no |
| Retention setting (days, one number) | `UserDefaults` of the app (`AppModel.retentionKey`) | Until changed | No |
| Temporary files: `devicectl` JSON output (device name and id; `DeviceLookup`, `getDeviceInfo`), tool output of `rvictl`, `ifconfig` (`CaptureController.run`, 0600) | `FileManager.temporaryDirectory` (per-user, 0700) | Removed in a `defer` when the command ends; a crash can leave one until the system clears the folder | No |
| Band files (`report --write-bands`): numbers only | The path given (the repo's `Tests/Expected/` for committed ones) | User-managed | No |
| Capture script log and run directory | Root script's run folder (see [CAPTURE.md](CAPTURE.md)) | Removed by `stop()`; a directory a crashed app left is stopped and removed at the next launch. The script log moves to `logs/` (newest 10 kept) | Not touched; contains no packets, no hostnames |
| Report JSON (`tattle report --json`) | Printed to stdout only; saved only if the user redirects it | User-managed | No (outside the database) |
| Metrics file (`capture --metrics`, opt-in): one csv row every 2 s of counts and memory, numbers only (no hostnames, addresses or device ids) | The path given, created new (0600), `~/dev/tattle-fixtures/reports` for the long run | User-managed | No (outside the database) |
| Fixture captures and scenario files | `~/dev/tattle-fixtures` (developer only) | User-managed | No |

### Privacy

- File permissions 0600; directory 0700
- No raw packets, no payload bytes, no UDID; `device_hash` only
- `Store(path:)` refuses a path whose last component is a symbolic link (`StorageError.io("database path is a symbolic link")`), so a root capture cannot be redirected
- Encryption at rest: rely on FileVault in V1, noted in the privacy text

### Tests

- Open twice: schema created once, version stays 2
- `versionOneDatabaseMigrates`, `freshDatabaseIsVersionTwo`, `newerSchemaThrows`, `sessionStatsRoundTrip`, `migrationIsAtomic`
- `save` then `flows(session:)` round-trips every field, including tally rows and both address types
- `save` the same flow twice updates in place (no duplicate rows)
- Session left open → `markInterruptedSessions` sets reason `interrupted`
- `expire` removes a whole old session and keeps a recent one; the cascade removes its flows, tally rows, domains, addresses
- `deleteAll` leaves all tables empty
- `deleteAllLeavesNoPlainTextHostname`, `expireLeavesNoPlainTextHostname`: the bytes of `.sqlite` and `-wal` do not contain a deleted server name
- `deleteAllKeepsSchemaUsable`: a new session saves after `deleteAll`; `meta` rows and the device hash stay
- `deleteAllTimeOn5000Flows`: prints the time (information only)
- `deviceHash` is stable across reopen and differs between two stores (different salt)
- Permission bits on the created file
- `Store` works through the `FlowStore` protocol (begin, save, end)

### Acceptance

- `swift test` green; saving 10,000 flows in one call takes < 1 s

## See also

[FLOWS.md](FLOWS.md) · [DOMAINS.md](DOMAINS.md) · [APP.md](APP.md)
