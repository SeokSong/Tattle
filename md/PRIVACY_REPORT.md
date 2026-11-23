# App Privacy Report export

Status: format verified on one real export (2026-11-21); parser built (Milestone 3, problems 2.1 and 2.2). This file holds shapes and counts only. The export itself is private: it lists the apps on a real phone and the domains they contact, so it is never committed, copied or quoted (the repo guard enforces this).

## What the file is

- iOS Settings, Privacy and Security, App Privacy Report, "Save App Activity" writes one file: newline-delimited JSON (NDJSON), one record per line
- File name pattern: `App_Privacy_Report_v4_<timestamp>.ndjson`. The `v4` is the format version
- It covers at most 7 days, and an export can cover fewer, so copy never says "the last 7 days": it says "the period covered by your report" with the real dates
- Tattle reads the export. It never moves, changes or deletes the user's original, and says so

## Shape of the real export

Printed by `scripts/privacy-report-schema.sh` (shape only, never values). Its output stays in the private fixtures folder and is never committed; re-run the script when the owner exports again and compare. The tables below give the shape without the export's counts.

| Fact | Value |
|---|---|
| File size | a few MB for a few days |
| Lines | every line a JSON object, none unparseable, last line ends with a line end |
| Longest line | a few hundred bytes |
| Record types | `networkActivity` and `access`; no others |
| Time stamps | `YYYY-MM-DDTHH:MM:SS.mmm` plus an offset, 29 characters, always milliseconds. Every stamp in an export has the same offset (the phone's zone at export); the parser still accepts any `Z` or `+hh:mm` offset and a missing fraction |
| Order | `firstTimeStamp` is never after `timeStamp` |
| Apps, domains | the same app and domain pair repeats across records |
| `hits` | integer, 1 or more |
| `domainOwner` | present on every record; empty on most records |

### `networkActivity` fields

All present on every record.

| Key | JSON type | Shape | Kept |
|---|---|---|---|
| `type` | string | `networkActivity` | selects the record kind |
| `bundleID` | string | reverse-DNS | yes |
| `domain` | string | a hostname or an IP address | yes, lower-cased, trailing dot removed |
| `domainOwner` | string | empty on most records | yes, empty becomes nil |
| `hits` | integer | 1 or more | yes, summed per app and domain |
| `firstTimeStamp`, `timeStamp` | string | ISO-8601 with offset | yes, as absolute times |
| `initiatedType` | string | two words seen (`AppInitiated`, `NonAppInitiated`) | raw, never shown or interpreted |
| `domainType` | integer | values 1 and 2 | raw, never shown or interpreted |
| `domainClassification` | integer | values 1 and 2 | raw, never shown or interpreted |
| `context` | string | empty on most records | **dropped** (OD6): the website a browser request was made in |
| `contextVerificationType` | integer | values 0 and 2 | **dropped** |

### `access` records

Access records (OD6: skipped and counted, contents never kept). Keys: `type`, `timeStamp`, `kind` (`intervalBegin`, `intervalEnd`), `category` (a word naming the kind of data or sensor), `accessor` (object with `identifier`, `identifierType`), `identifier` (a 36-character id), `accessCount` (0 on every record), and sometimes `outOfProcess` and `broadcaster` (an object). An access record has no `bundleID` or `domain`.

### Domain shapes

The `domain` field is not always a hostname. It can be an IPv4 or IPv6 address literal and can contain upper-case letters; no trailing dot was seen.

- Many of the distinct "domains" are bare IP addresses. They cannot get a company from the Public Suffix List, so they will mostly count as "not identified" until a later source maps them. The parser keeps them as written (lower-cased) and does not classify
- Domains are lower-cased, and a trailing dot is removed, so that the same host written two ways becomes one row.

## Decisions (problems 2.1 and 2.2)

| Topic | Decision | Why |
|---|---|---|
| Kept fields | The OD6 list: `bundleID`, `domain`, `domainOwner`, `hits`, the two times, and the three raw codes | OD6, option A |
| Period | `period_start` is the earliest `firstTimeStamp` and `period_end` the latest `timeStamp`, over the kept network records, compared as absolute times (offsets and daylight saving applied). Access records do not move it. The file has no header or period field | Nothing else in the file states a period; the period describes what is stored |
| Format version | Read from the file name (`_v4_`). The parser records it in `ImportResult.formatVersion` and sets `unexpectedFormatVersion` when the name has no version or another one. It still parses: the import screen warns, it does not refuse, because the fields are checked per record anyway | A new version most likely adds keys; a renamed file should still import |
| File size cap | 50 MB. The rule is 5 times a real export's size with a floor of 50 MB, so the floor applies | Review 03: a cap that cannot refuse a normal file |
| Line size cap | 16 KiB (real lines are a few hundred bytes) | A line with no end is refused as soon as the buffer passes the cap, not at the end of the file |
| Line count cap | 250,000 lines (far more than a 7-day export holds) | Bounds time and memory on a hostile file |
| Malformed share | More than 1% of the lines read rejects the import. A file where every line is malformed is rejected the same way | A little damage is tolerated and counted, a wrong file is not imported |
| Empty file | An empty result, not an error: `kept` is 0, so storage stores nothing and the screen says why | md/STORAGE.md: an import needs at least one network record |
| Last line | A last line with no line end that does not parse was cut off: dropped, `truncatedLastLine` true, not counted as malformed. A complete last line without a line end is a normal record | Exports copied while being written |
| Hash | SHA-256 of every byte of the file, computed while reading (a small hand-written implementation, because the module imports Foundation only; tested against the standard vectors) | Same file twice is a no-op |
| Combining | One row per app and domain, as in md/STORAGE.md: hits summed (never overflowing), earliest first time, latest last time, first non-empty owner in file order, the three raw codes from the record with the latest `timeStamp` (a later line wins a tie) | Same rule as the stored table |

### Bundle id to app join (shapes only)

- Almost all bundle ids are reverse-DNS names with a two or three letter first part, most of them with three parts
- Most have a last component made of letters only, 3 or more characters. A few have a generic last component (`app`, `ios`, `mobile` and similar), which would collide between apps
- Capture knows the process name (at most 16 characters, the executable name), not the bundle id. The last component often resembles it, but not reliably
- **Decision for problem 2.6:** join by an explicit table only: exact bundle id, then a prefix ending in a dot (`apps.tsv`), never by guessing from the last component. Unjoined apps stay under their bundle id and are counted. The last component is used offline, when building the table, to suggest candidate rows for the owner to check

### `domainOwner` is mostly empty (fallback for problem 3.2)

- Empty on most records, so Apple's owner is a minor source. The summary must not depend on it
- When the owner is empty, the domain is classified by the curated list and the Public Suffix List only. When that gives no company, the domain counts as "not identified". It is never shown as "no owner" or "unknown company", and Apple's silence is never reported as evidence of anything
- When the owner is filled, it is shown as Apple's own wording, labelled as the report's, and compared with the curated list under OD2 (the experiment decides which source wins)

## Parser (problem 2.2)

`Sources/PrivacyReport/`. Foundation only, no dependency, does not touch storage; `Companies` and `PrivacyReport` do not import each other (`LayeringTests`).

| Type | Job |
|---|---|
| `LineSource` | Where bytes come from: `byteCount`, `fileName`, `read(maxLength:)`. `FileLineSource` reads a file in 64 KB chunks |
| `ReportParser.parse(source:limits:sink:)` | Streams lines, hands each network record to the sink, returns an `ImportResult`. Records handed to the sink are provisional until it returns without throwing |
| `ReportParser.parseCombined(source:limits:)` | The same, then one `ReportContact` per app and domain |
| `ReportRecord`, `ReportContact`, `ContactCombiner` | Plain value types |
| `ImportLimits` | `standard` holds the caps above |
| `ImportResult` | Hash, counts (lines, kept, access skipped, unknown types and their names, malformed), period, truncated last line, format version |
| `ImportError` | `fileTooLarge`, `lineTooLong`, `tooManyMalformed`, `recordCap`, `unreadable` |

- The line is decoded once; `type` is read first and the other keys only for a network record. `context` is not a key of the decoder, so it is never read. An access record is never read beyond its kind and is gone when the line ends
- Unknown record kinds are skipped and counted; their names (format words, at most 16, ASCII only, 40 characters at most, anything else listed as `(unreadable)`) are in the result
- Blank lines are ignored and not counted
- Errors and results never carry a domain, an app id or an owner; an error holds numbers from the limits only
- Speed: 100,000 lines (31 MB) in about 0.6 s optimized, about 13 s unoptimized (debug)

## Repo guard

`Tests/TestSupport/RepoGuard.swift` rejects, anywhere in the repo outside `.build`, `.git` and `img`:

- files with the extension `.ndjson` or `.jsonl`, and files whose name starts with `App_Privacy_Report`
- any text file (up to 8 MB) holding a line that is a JSON object with at least three of the export's quoted key names, so a renamed copy is caught too

Docs may name the fields in backticks. `.gitignore` lists the same patterns, so a real export is not staged by accident. Tests build synthetic exports in memory with fake ids (`com.example.app1`) and reserved example domains; the local-only test on the real export (skipped without `TATTLE_FIXTURES`) checks counts and invariants and prints numbers only.

## Import command

`tattle import-report <file> [--db <path>]` runs the parser and stores the result in one transaction. It prints counts, dates and plain-language outcome lines only (already imported, older than a stored import, replaced older imports, newer format version, refused by the limits with the counts), never an app id, a domain or the file path.
