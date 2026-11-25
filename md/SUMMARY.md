# Summary

**Status:** Problems 3.1 (captures), 3.2 (App Privacy Report), 3.3 (sentences, glossary, wording lint), 3.4 (the Summary screen) and 4.2 (the rating) done. The reader test (3.5) is with the owner.

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
- Domains are compared lowercased without a trailing dot, and app ids ignoring case, so one domain or one app is never counted twice. Parents compare ignoring case too; a list's spelling is shown over an Apple owner string that differs only in case
- Timing: 100,000 contact rows over 5,000 distinct domains build in 390 ms release (budget 1 s); 100,000 distinct domains, far more than a real report, take about 2.9 s
- Proof: `Tests/TestSupport/ReportSummaryCorpus.swift` (17 rows, every number by hand, every domain checked against the real classifier first) and `Tests/SummaryTests/ReportSummaryTests.swift` (11 tests, including one that no field holds bytes or a list of domains)

## Sentences and glossary (Problem 3.3)

The words live in one file, `Sources/Summary/Resources/wording.toml`; the code (`SummaryText`, `Glossary`) only chooses which sentence applies and fills in the numbers and names (owner, 2026-11-24). The strings were approved by the owner on 2026-11-24.

### Changing what the screen says

1. Edit the text after `=` in `wording.toml`. Keep the key and its `{placeholders}`; write `\"` for a quote
2. Run the tests. `WordingTests` fails when a key is missing or unknown, a placeholder is one the code never fills, or a sentence breaks a rule
3. A new case (a new key) needs code: add it to `SummaryText.schema` and to the function that picks it

The format is a small subset of TOML (`key = "text"` lines and `#` comments), read by `Wording` with no library (the project has no third-party dependencies). Each plural or zero case is its own key (`.one`, `.other`, `.none`). A missing key shows as `[key]` on screen, a visible bug and never a made-up sentence. The file ships in `Tattle_Summary.bundle` (Summary target resources); a future `.app` bundle must copy it into `Contents/Resources`, like `Tattle_Companies.bundle`.

### Rules the owner chose

- No speaker: never "Tattle", "we", "our" or "us"; no sentence starts with a number
- The unit word is "destinations", and one idea has one word: "traced" ("could not be traced to any company")
- When the reader opens an app, the companies are named (up to 3; with more, the first 2 and the count), then the advertising or tracking part, then the untraced part, always together
- A destination the AdGuard list knows by type but not by company is "a known advertising service whose owner is unknown"
- No advertising or tracking found: "No advertising or tracking companies were found." (the owner first wanted "This app doesn't track")
- The own company row keeps its categories ("Alphabet · the app's own company · Advertising"), so the advertising or tracking count always has a row to point to
- Coverage: one line per source with the percent traced; the largest cause of the rest is only behind an (i) icon. Percentages have one decimal and round down (77.3%, 0.5%), so a small traced share is never shown as 0 and nothing is overstated; whether a rating is shown is decided on the exact ratio. Dates show the year when it is not the current year. "the largest share", never "most", because the largest cause need not be over half
- Rating: "Rated on 82.4% traced traffic."; below 70%: "Not enough data to rate: 55.0% of this app's traffic could be traced to a company. A rating needs at least 70%." A hidden rating hides only the band
- Never used: sells, sold, shared your data, spying, safe, unsafe, stops, blocks, even when not in use, privacy score

| Where | Example |
|---|---|
| Overview | In your captures and App Privacy Report (14 to 21 November), 12 apps contacted 31 companies, 9 of which do advertising or tracking. Another 40 destinations could not be traced to any company. |
| App, opened | Zappy contacted Zappy Inc, AdCo Holdings and CdnCo. Of these, AdCo Holdings does advertising or tracking. It also contacted 3 destinations that could not be traced to any company. Among them, 2 are known advertising services whose owner is unknown. |
| Company row | AdCo Holdings · Advertising, Analytics / Alphabet · the app's own company · Advertising / YouTube (owned by Alphabet) |
| Captures | Captures (14 to 21 November): 77.3% of this app's traffic could be traced to a company. (i): Of the remaining 22.7%, the largest share went to destinations whose names the app kept hidden. |
| Report | App Privacy Report (18 to 21 November): 6 of this app's 9 destinations could be traced to a company. The report doesn't show how much data was sent. |
| Data amounts | In the capture from 14 November, the largest share of the data went to Alphabet. (captures only, with the toggle on) |

## The Summary screen (Problem 3.4)

- `CombinedSummaryBuilder` joins the capture and report summaries into one card per app (OD8 as decided by the owner): by bundle id compared ignoring case; an app the app table does not know never merges by guess. Companies are united by parent ignoring case and tagged with where they were seen. Untraced destinations are counted once across both sources from names the summaries keep in memory only (never shown, never saved)
- Apple's own apps (bundle ids under `com.apple.`) are one "Apple apps" card in both sources, with one row per Apple app that opens to its own details. iOS system is its own card
- `SummaryScreenBuilder` turns the cards into rows: a closed row shows "4 companies · 1 advertising or tracking"; rows are ordered by the number of advertising or tracking companies, then by name, with Apple apps and iOS system last (owner, 2026-11-24)
- Bullets, not sentences (owner, 2026-11-24, after seeing the screen: "a user spends 10 to 20 seconds per app at most"). The overview is four bullets (apps; companies and how many advertise or track; destinations not traced; the dates of each source). An opened row is grouped bullets: Advertising or tracking, Other companies, Not traced (always shown, "None" at zero), Traced (one bullet per source, the (i) icon explains the rest), and "Possible, not counted" with its (i). Where a company was seen shows on hover only
- The full sentences of 3.3 (`SummaryText.appSentences`, `overview`, the coverage sentences) stay in the code and the wording file, tested, for the reader test or an export, but the screen does not use them
- The screen (`Sources/TattleApp/SummaryView.swift`) is the first sidebar item. It loads everything within retention off the main thread (`SummaryLoader`), with one hostname index per capture so a name seen in one capture never names a flow of another; it reloads after a capture ends, an import changes, retention changes or Delete all, has Refresh and a "How to read this" sheet. Neutral colours, no rating (Part 4), no byte amounts (Part 5)
- "Every named destination was traced to a company.": "named", because a row can be fully traced by name while part of its traffic had no name at all (owner, 2026-11-24, after seeing the screen)
- Demo: `TATTLE_DEMO_SUMMARY=1` shows made-up apps and companies (`SummaryDemo`, all `.test` names) and opens on the Summary screen. `TATTLE_SUPPORT_BASE=<absolute folder>` points the app's whole data folder (database, run folders, diagnostics) elsewhere, so a launch for a check never touches the real data; it is accepted only for an existing folder this user owns that no one else can write to (the capture's run folders live there). `scripts/demo-screenshot.sh <out.png>` does both and saves a picture of the app window only

## The rating (Problem 4.2; owner, 2026-11-24, revising OD4's word bands)

- A letter grade, always with the count: "C · 3 advertising or tracking companies", "A · no advertising or tracking found". Never the letter alone, never "safe": it counts companies the app contacted and says nothing about what the app does with data
- Counts every advertising or analytics company on the card, from captures and the App Privacy Report together (one grade per app), the app's own company included (owner, 2026-11-24, after the review of PR #11: the closed row must never say "none found" above an advertiser in the opened row; OD4 had left it out). Never counted: content delivery, cloud, online and Apple system companies, possible names, untraced destinations
- Cut-offs in `Sources/Summary/Resources/rating.toml`, editable without code: A = 0, B = 1, C = 2-3, D = 4-5, F = 6 or more. A curve (top 10% A, bottom 50% F) was considered and not used: most apps have 0 such companies, so a curve would split identical apps into A and F, and grades would move when other apps change
- Rated only when every source with data for the app is at least 70% traced (`threshold.percent`); otherwise "Not enough data to rate (65.0% traced)" with the lowest share. Only the grade is hidden; every company and count is still shown
- iOS system and the merged Apple apps card get no grade (a grade judges one app); each Apple app inside does
- Proof: `Tests/SummaryTests/RatingTests.swift` checks the 14 made-up test apps the owner approved before the code was written (OwnAds changed from A to B with the own-company decision)
- The threshold lives only in `rating.toml`; the older rating sentences read it too. A broken file is reported on standard error and the built-in scale is used

## Tips (Problem 4.3, OD5)

- Shown under "What you can do" in an opened app that contacted at least one advertising or tracking company (the companies the rating counts):
  - "Limit background activity: Settings › General › Background App Refresh (may not stop every connection)"
  - "Check tracking permission: Settings › Privacy & Security › Tracking"
- Apple's own apps get only the first (they never ask to track); iOS system and the merged Apple apps row get none
- The owner checked both Settings paths on iOS 27 on 2026-11-24. The version and date are in `wording.toml` (`tips.checked.*`); `tipsSettingsPathsAreRecheckedEveryYear` fails 365 days later on purpose, so the paths are checked again on a current iOS
