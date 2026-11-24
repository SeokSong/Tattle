# Summary

**Status:** Problems 3.1 (captures, `SummaryBuilder`) and 3.2 (App Privacy Report, `ReportSummaryBuilder`) done. The sentences and glossary (3.3) and the summary screen (3.4) come next.

## Purpose

Turn a capture into one entry per app that a non-technical reader can follow: which companies the app contacted, which ones are only possible, what could not be identified, and how much of the app's traffic Tattle could not see at all. Every number has to be defensible, so the builder follows the same rules as the quality report and the company coverage, and tests prove it.

## What is in it

`SummaryBuilder.build(flows:index:classifier:apps:) -> CaptureSummary`, at read time only, never on the packet path. Inputs are the flows and the hostname index of one capture, or several captures merged by the caller. One pass, one label per distinct hostname.

- `apps`: one `CaptureAppSummary` per app, sorted by name (case-insensitive and non-localized, the same on every Mac)
- `system`: one "iOS system" entry for every system process (company Apple)
- `noProcess`: connections iOS did not tag with any process (counts only)
- `excluded`: the Mac link (`deviceLink`) and local network (`localNetwork`) traffic, left out as in the quality report
- the curated list version and the tracker list version the labels came from

Each entry has:

| Field | Meaning |
|---|---|
| `name`, `key`, `company` | The app table's display name, bundle id and parent company; for an app the table does not know, the process name with no company |
| `companies` | One `CompanyEntry` per parent company confirmed by a name seen in the connection: brands, categories, relation to the app, connections and bytes |
| `namedCompanies`, `adTrackCompanies` | Distinct parent companies, and those with an advertising or analytics category |
| `possibleCompanies` | Parents seen only through a hint (DNS answer, another connection to the same server), minus confirmed ones |
| `unnamedCategories` | Distinct registrable domains per category that the AdGuard list gives a category but no company for |
| `identified`, `notIdentified`, `hinted`, `unseen` | Connections and bytes; every port 443 byte of an entry is in exactly one of them |
| `coverage` | Identified bytes over all port 443 bytes of the entry |
| `windowStart`, `windowEnd` | First and last connection |

## Rules

- Port 443 only, the same base as the quality report and `Coverage`
- Unit (OD3): the distinct parent company. Brands are listed under their parent ("YouTube (owned by Alphabet)" counts as Alphabet; owner rule 2026-11-23)
- The app's own company is counted and marked (`relation == .sameCompanyAsApp`) and sorted first, then advertising and tracking, then the rest (OD12)
- Hints never enter `companies` or any count; they only fill `possibleCompanies` and `hinted`
- Not identified stays in the denominator; nothing is guessed. A connection counts as identified only together with the company it names
- A name the AdGuard list knows only by category is counted in `unnamedCategories` ("plus 2 advertising services we couldn't name"), never in the company counts or the rating (owner, 2026-11-24)
- Apps: process names that the app table maps to one app are one entry (a cut name like `ZappyVideoPlayer` and a helper process both join `Zappy`). A name the table does not know is its own entry, never guessed (owner, 2026-11-24)
- System: every system process is one "iOS system" entry with company Apple, so Apple servers are the system's own company. A system process acting for an app (iOS reports the effective process) counts for that app (owner, 2026-11-24); one acting for another system process is system traffic (owner, 2026-11-24, the shared classifier rule)
- Bytes are in the summary for the "Show data amounts" toggle (5.2); the report source (3.2) has no byte field

## What is left out, and why

- Traffic to ports other than 443: the hostname evidence (TLS and QUIC names) is only on port 443
- The Mac link and local network traffic: not the phone talking to the internet
- Connections with no process information: shown as one line with counts, because they cannot be put under an app

## Proof

- `Tests/TestSupport/SummaryCorpus.swift`: a hand-built scenario of 23 connections with every expected number worked out by hand, checked flow by flow against the real code before the builder was written; `Tests/SummaryTests/CaptureSummaryTests.swift` (12 tests)
- `Tests/ReportTests/SummaryHonestyTests.swift`: on the scenario and on every fixture capture, the apps' unseen bytes per reason equal the quality report's `unnamedShare` numerators, the apps' coverage base equals its app-traffic denominator, and apps + system + no process + excluded equals `hostnameCoverageSniOnly`'s denominator. Measured 2026-11-24: equal on all six fixture captures
- The one deliberate difference: a connection whose name was seen only in a handshake with ECH (the flow itself has no server name) is named in the quality report but counted as hidden in the summary, because the visible name is the public outer name. A test pins it
- `Tests/SummaryTests/SummaryTimingTests.swift`: 100,000 synthetic flows, some with curated names and some with AdGuard category-only names, build in 289 ms release (budget 1 s, checked in release only; 2026-11-24)

## App Privacy Report summary (Problem 3.2)

`ReportSummaryBuilder.build(contacts:classifier:apps:) -> ReportSummary`. The app reads the stored contacts and passes them in as `ReportContactInput` values (Summary does not import Storage). There are no bytes: the report counts contacts (Apple's hit counts) and distinct domains.

- One entry per app, sorted by name; `appleApps` is one merged "Apple apps" entry for every bundle id under `com.apple.`, with `members` holding each Apple app's own summary for a drop-down (owner, 2026-11-24). A domain two Apple apps contacted counts once in the merged entry
- Names: the app table's display name for an exact row; otherwise the bundle id (an app the table does not know, or knows only by a prefix such as `com.google.`). The company comes from the row, exact or prefix (owner, 2026-11-24)
- Labels: the precedence table (curated, then Apple's `domainOwner`, then the AdGuard list; category from curated, then AdGuard). An Apple owner string counts under the curated parent it stands for (`apple-owner-aliases.tsv`), with the owner string as the brand
- Bare IP addresses are never shown and no type holds a domain. An address Apple's owner names is identified under that company; any other address is not identified and stays in the denominator (OD16 revised by the owner, 2026-11-24)
- Several imports: the store never holds overlapping imports (OD18), so hits for the same app and domain are summed and the domain counts once
- The same rules as captures: the distinct parent company is the unit, the app's own company is counted, marked and first, AdGuard category-only names are counted apart
- Proof: `Tests/TestSupport/ReportSummaryCorpus.swift` (17 rows, every number by hand, every domain checked against the real classifier first) and `Tests/SummaryTests/ReportSummaryTests.swift` (11 tests, including one that no field holds bytes or a list of domains)
