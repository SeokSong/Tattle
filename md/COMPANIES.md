# Companies

**Status:** Problems 1.1, 1.2, 1.4, 1.6 (AdGuard list) and 1.7 (curated, Apple owner and AdGuard sources, in the owner's order) done (1.3 labels at view time; the curated-only coverage baseline is frozen; OD14 and OD15 applied): registrable domain from the bundled Public Suffix List (both sections), the curated company list and `CompanyClassifier`. The app to company table is Problem 2.6 (below).

## Purpose

- Turn a hostname into the name classification keys on: `a.b.example.com` becomes `example.com`, `x.example.co.uk` becomes `example.co.uk`
- Carry the bundled datasets with their provenance and licences

## Vocabulary

| Term | Meaning |
|---|---|
| Public suffix | A name under which anyone can register (`com`, `co.uk`, `ck`-style wildcards) |
| Registrable domain | Public suffix plus one label (`example.co.uk`) |
| Manifest | `Resources/manifest.json`: name, version, commit, source URL, licence, fetch date, SHA-256 of each dataset |

## Rules

- `Companies` has no dependencies and imports Foundation only. The code never fetches anything; datasets are downloaded by hand and loaded with `scripts/build-companies-data.sh <local file>`
- API: `registrableDomain(of:) -> String?`, `PublicSuffixList` (lazy `bundled`, immutable, `Sendable`), `DatasetManifest`
- Returns nil for IP literals, single labels, empty labels, names over 253 bytes and names that are themselves a public suffix. Lowercases and strips one trailing dot
- Matching order: an exception rule (`!www.ck`) wins, then the longest plain or wildcard rule (`*.ck`), then the default rule (one label)
- Full list, ICANN and private sections (owner decision OD14): a private-section rule is a public suffix like any other, so `x.github.io` gives `x.github.io` and `someone.pages.dev` gives `someone.pages.dev`. The platform's own name for the rule is kept: `psl.dat` has a `// PLATFORM: <name>` line above each private block, taken from the list's comment for that block (the text before ` : `). `hostingPlatform(of:)` returns it when the registrable domain came from a private rule, or the suffix itself when the name could not be read. A name that is exactly a suffix (`github.io`) has no registrable domain
- A hostname whose registrable domain comes from a private rule is an unknown website hosted on that platform. Its label has source `none`, no company and no parent, and `hostingPlatform` set; coverage and the counts treat it as not identified. It is never labelled as the platform's company. The row text says "Website we couldn't identify" (the plain case still says "Not identified"); the tooltip says "Unknown website, hosted on <platform> (a service many sites use)". A curated row can still name one exact registrable site; a row keyed by the platform's own suffix (`cloudfront.net`, `pages.dev`) cannot load, because a suffix is not a registrable domain, so those rows were removed (curated list version 3)
- Internationalised names: the list stores unicode rules; `xn--` labels are decoded (RFC 3492) for matching and returned as written

## Datasets

| Dataset | File | Source | Licence |
|---|---|---|---|
| Public Suffix List | `Resources/psl.dat` | https://publicsuffix.org/list/public_suffix_list.dat | MPL 2.0 |
| AdGuard companiesdb tracker list | `Resources/tracker/tracker.tsv` | https://github.com/AdguardTeam/companiesdb (based on Whotracks.me) | CC BY-SA 4.0, this folder only |

- `psl.dat` is the list's licence header plus the rules of both sections (private blocks carry a `// PLATFORM:` line instead of the list's comments, which hold contact addresses), built by the script; never edit it by hand. The manifest holds the SHA-256 of both the shipped file and the downloaded original, and a test checks the shipped hash
- `NOTICES.txt` holds the full MPL 2.0 text and the source URL; the licence header stays in the data file
- Tattle's own code is MIT (`LICENSE`). The `Resources/tracker/` folder is CC BY-SA 4.0 with its own `LICENSE` and `README.md`; NOTICES and the About sheet credit AdGuard and Whotracks.me
- To update: download the list by hand, run `scripts/build-companies-data.sh path/to/public_suffix_list.dat [YYYY-MM-DD]`, run the tests
- The repo guard allows a 40-hex value only on a labelled commit line in the file that carries it: `// COMMIT:` in `Sources/Companies/Resources/psl.dat`, a `"commit"` key in `Sources/Companies/Resources/manifest.json`. Anywhere else it is a violation

## Resources

- SwiftPM's generated `Bundle.module` traps when `Tattle_Companies.bundle` is absent, so the code never uses it. `DatasetManifest.locateBundle(in:)` searches the executable's folder, the main bundle and its parent, `Bundle.main.resourceURL` and the folder of the bundle this code was linked into, and returns nil when none holds the bundle. It finds the files under `swift run`, `swift build -c release`, `swift test` and `swift test -c release`
- A missing bundle does not crash: `resourceURL` returns nil, `PublicSuffixList.bundled.isLoaded` is false, every name falls back to the one-label default rule, the curated list is empty, and the About sheet shows "The bundled lists could not be read". A future `.app` bundle must still copy `Tattle_Companies.bundle` into `Contents/Resources` for the lists to load. A test passes a fake search location

## Budgets

| Budget | Limit | Measured (2026-11-22) |
|---|---|---|
| Cold start (first call, parse) | at most 30 ms | about 14 ms release, about 33 ms debug (full list, 10,469 rules) |
| Added memory | at most 5 MB | about 1.3 MB |
| Data size | at most 3 MB | 164 KB (10,469 rules) |

- Provisional. `loadCostIsPrinted` prints load time and added memory and asserts the 200 ms sanity floor and the 3 MB data size. Memory is not asserted (parallel tests inflate the process footprint); read it from `swift test -c release --filter Companies`

## Curated list and classifier (Problem 1.2)

- File: `Resources/curated.tsv`, tab separated, one header line `domain company parent category note`. `md/COMPANIES-curated.md` is the readable table (generated, sorted by category, with counts) that the owner reviews
- `domain` is a registrable domain or a hostname under one, lowercase, no trailing dot. `category` is one of `advertising`, `analytics`, `social`, `contentDelivery`, `cloudService`, `appleSystem` (`unclassified` is the absence of a row and is rejected). `note` is a short public rationale with no adjectives
- Every row has source `curated`. Rows are built from public knowledge of widely known companies only; they are never chosen from anyone's captures or reports. A domain whose owner is not certain is left out, not guessed
- Load is strict: an unknown category, a duplicate key, a key that is not registrable (or not lowercase), an empty field or a wrong column count fails the whole load. The error names the line number only, never a value
- Lookup ladder: the full hostname, then each parent suffix down to and including the registrable domain; the most specific row wins (`ads.example.com` can differ from `example.com`). Names are matched whole, never by substring. No match gives an explicit label with category `unclassified` and source `none`
- Categories (raw value, label, meaning): `advertising` (Advertising), `analytics` (Analytics), `social` (Social media), `contentDelivery` (Content delivery: servers rented to deliver files and video), `cloudService` (Cloud or app service: behind-the-scenes infrastructure only, such as hosting, storage, payment gateways, sign-in, APIs, certificates, email delivery used by other companies), `appleSystem` (Apple system), `onlineService` (Online service: a company's own product people use directly, such as video and music sites, games, email, office apps, maps, search; decision OD11), `unclassified` (Not matched). Only advertising and analytics count as advertising or tracking
- A domain used both as a product and as an API stays `cloudService`, except where the owner moved it; the generated review table lists every row so the owner can move it
- Owner moves (2026-11-23, curated version 5): `google.com` and `microsoft.com` (the consumer sites) and `alipay.com` and `klarna.com` (payment services people use directly) are `onlineService`. Infrastructure domains such as `googleapis.com` and payment gateways such as `stripe.com` stay `cloudService`. Hostname rows keep the sign-in hosts `accounts.google.com` and `login.microsoft.com` in `cloudService` (curated version 6); any other host under the two domains takes the parent row's `onlineService`
- API: `CompanyClassifier(curated:)` (immutable, `Sendable`). `classify(hostname:appleOwner:order:)` tries sources in `order` (provisional `[.curated, .appleOwner]`; precedence is decided later by the agreement experiment). `label(hostname:from:appleOwner:)` runs exactly one source and never looks at another. `labelsBySource(hostname:appleOwner:)` returns every source's answer for comparison
- `CompanyLabel.source` says who answered (`curated`, `trackerList`, `appleOwner`, `none`); `rule` says which rung (`curatedHostname`, `curatedRegistrable`, `curatedOperatedSuffix`, `trackerHostname`, `trackerRegistrable`, `appleOwner`, `noMatch`); `datasetId` (`tattle-curated`, `adguard-companiesdb`), `datasetVersion` and `datasetSHA256` come from the manifest. The `appleOwner` source returns the report's owner string as `company` with no parent and category `unclassified`, because the report gives neither. `relation` is `unknown` until the app's company is known (see the app table section below)
- To change the list: edit `curated.tsv`, run `scripts/build-curated.sh [version]` (refreshes the manifest hash, row count and the review table), run the tests. Bump the version when the content changes
- Cost: `lookupCostIsPrinted` prints the per-hostname cost of `classify` (sanity floor 200 microseconds)

## Platform-operated suffixes (OD15)

Some private-section suffixes are the platform's own services, not a place where customers host sites. A curated row `suffix:<private suffix>` (same columns; the note is a fixed public phrase) marks one: every host under it gets that row's company, parent and category, with rule `curatedOperatedSuffix`. The key must be a plain private-section rule of the bundled list; otherwise the whole load fails (`notPrivateSuffix`). Ladder: exact hostname row, rows of each parent, then the operated suffix, then the registrable domain's row, then (private suffix, not operated) an unknown website hosted on the platform, then not identified. Mark a suffix only when the platform itself serves essentially all its subdomains; when in doubt it stays an unknown hosted site.

| Suffix | Decision | Reason |
|---|---|---|
| `googleapis.com` | Operated (Google, Alphabet, cloud or app service) | Platform's own API hosts; customer content uses paths |
| `cloudfront.net`, `akamai.net`, `akamaiedge.net`, `akamaihd.net`, `akamaized.net`, `akadns.net`, `edgekey.net`, `edgesuite.net`, `fastlylb.net`, `cloudflare.net`, `azureedge.net`, `trafficmanager.net` | Hosted on platform | Delivery networks that serve their customers' sites under per-customer names; the site is the customer's |
| `appspot.com`, `firebaseapp.com`, `web.app`, `workers.dev`, `pages.dev`, `azurewebsites.net`, `myshopify.com`, `blogspot.com` | Hosted on platform | Customers publish their own sites under a name they choose |
| `githubusercontent.com` | Hosted on platform | Serves user-published content |

## Coverage and the frozen curated-only baseline (Problem 1.4)

`tattle companies coverage <capture> | --db <path> --session <id|latest> [--json] [--bands <file>] [--write-bands <file> --label <text>] [--unmatched-out <file>]` prints how much of a capture the company sources can name. It is computed at read time from saved flows (`Sources/Summary/Coverage.swift`); nothing runs on the packet path. Output is keys and numbers only, so it can be committed as a band file.

| Metric (JSON key) | Numerator | Denominator |
|---|---|---|
| `companyCoverage` | Bytes of flows to port 443 whose name was seen in the connection (`sni`, not behind ECH) and has a label other than not matched | Bytes of all flows to port 443 (the base of `hostnameCoverageSniOnly`). Hint-named, ECH, unnamed and midstream flows stay in it |
| `companyCoverageOfNamedBytes` | Same numerator | Bytes of port 443 flows with a confirmed `sni` name. Answers "of what we could read, how much did the list know" |
| `domainCoverage` | Distinct registrable domains with every confirmed name under them identified | Distinct registrable domains of the confirmed names |
| `labelSourceShare.<source>` | Distinct domains identified by that source alone | Distinct domains identified by any allowed source. Recorded in band files, never a floor (it moves when a source is added) |
| `unmatched.connections` | Count of port 443 flows with no confirmed name, or a confirmed name that is not matched | Plain count, always printed beside `namedCompanies` |
| `namedCompanies`, `adTrackCompanies`, `possibleCompanies` | Plain counts of distinct parent companies: confirmed, confirmed in advertising or analytics, named only by a hint | Hints never enter the first two |

- Capture only. Coverage of an imported App Privacy Report is deferred to Part 2 (the report parser does not exist yet)
- The classifier is run with `sources: [.curated]`, the frozen baseline, so a later source (Apple owner, public list) is measured against it. The report records the curated list version and checksum
- Whole capture, not per app: the per-app form of these metrics belongs to the app summary (Part 3)
- `--unmatched-out` writes the most frequent unidentified registrable domains (flows, bytes, name; at most 200; mode 600) to a local file for curation. The names go only to that file, never to the screen. Keep it in a private folder outside the repo. The command refuses a path inside a git work tree (it walks up looking for `.git`), creates the file new with mode 600 from the first byte (an existing file or a symlink is refused), and `.gitignore` lists `*.unmatched-domains.txt`
- Band files: `Tests/Expected/companies-synthetic.json` (hand-built corpus, `CompanyCorpus` in `Tests/TestSupport`, every number worked out by hand) and `Tests/Expected/companies/<scenario>.json` (one per fixture capture, numbers only). They use the quality report's band format. Every coverage ratio is higher-is-better. The floor is the exact baseline value (the `baseline` field is rounded to three decimals for reading), with no tolerance: coverage on a fixed capture and list is exact, and the target is "baseline minus nothing". Byte ratios under 10,000 bytes and `labelSourceShare.*` are recorded as informational. Each band note records the curated list version and checksum
- Ratchet: `CoverageRatchet.check`; the CLI exits 3 below a floor. A band with a floor above 0 also fails when the report has no value for it (the metric is missing or its denominator is 0), so a run that loses all its named domains cannot pass. `curatedOnlyCoverageBaselinesHold` runs it on every fixture band (skips without `TATTLE_FIXTURES`). Raising a floor after adding curated rows: re-run `--write-bands` on the fixtures, keep the note

### Curated-only baseline (curated list version 4, full Public Suffix List, 2026-11-22)

Frozen again after OD14 and OD15. Before = curated version 3 (OD14 only, no operated suffix); original = curated version 2 with the ICANN-only list.

| Capture | companyCoverage (original / before) | companyCoverage | domainCoverage (original / before) | domainCoverage | unmatched.connections (original / before) | unmatched.connections |
|---|---|---|---|---|---|---|
| s0-idle | 97.8% / 97.5% | 5,693,439 / 5,838,617 (97.5%) | 11/14 / 10/14 | 10 / 14 (71.4%) | 19 / 20 | 20 |
| s1-safari | 18.7% / 18.7% | 374,666 / 2,005,927 (18.7%) | 1/5 / 1/5 | 1 / 5 (20.0%) | 21 / 21 | 21 |
| s2-two-apps | 74.0% / 74.0% | 33,966,120 / 45,905,154 (74.0%) | 6/13 / 6/13 | 6 / 13 (46.2%) | 43 / 43 | 43 |
| s3-youtube-quic | 99.9% / 98.5% | 99,482,226 / 99,556,929 (99.9%) | 11/14 / 10/19 | 16 / 19 (84.2%) | 10 / 34 | 10 |
| s4-link-failures | 44.5% / 44.5% | 1,131,257 / 2,544,045 (44.5%) | 8/12 / 8/12 | 8 / 12 (66.7%) | 11 / 11 | 11 |
| s5-midstream | 1.1% / 1.1% | 439,671 / 39,166,929 (1.1%) | 4/5 / 4/5 | 4 / 5 (80.0%) | 10 / 10 | 10 |

- `s5-midstream` has low `companyCoverage` because most of its bytes are connections that began before the capture and have no name: that part is the unseen share, not a list gap
- Domain counts are small, so one added row moves `domainCoverage` by several points. Read the byte ratios first

## App table (Problem 2.6)

- File: `Resources/apps.tsv`, tab separated, header `bundleId displayName processName company note`. `md/APPS-curated.md` is the readable review table (generated by `scripts/build-apps.sh`, which also refreshes the manifest entry)
- `bundleId` is an exact reverse-DNS id, or a prefix ending in a dot (every id starting with it). `processName` is blank or one or more full executable names separated by `|`; the kernel's 16-character cut form matches too. `company` is spelled exactly as a `parent` of the curated list (a test checks it). `note` is a short public rationale
- Rows are built from public knowledge of widely known apps and their publishers only. They are never chosen from anyone's captures or reports; the owner's own data is used only to count how many of its apps the table covers. A process name that is not known with confidence is left blank
- Load is strict: a wrong column count, an empty field, a bundle id that is not reverse-DNS text, a duplicate bundle id (case-insensitive) or a process name on two rows fails the whole load, with the line number only
- Join rule: an exact row, then the longest prefix row. Never fuzzy: no match on the last component, no partial component, no case-folding of process names. The last component of a bundle id may be used offline, to suggest candidate rows for the owner to check. Unjoined apps stay under their bundle id text and are counted
- API (`AppTable`, in `Sources/Companies/AppIdentity.swift`; named `AppTable` because Storage already has an `AppIdentity` enum): `row(forBundleId:)`, `row(forProcessName:)`, `company(for:)` (a raw process name), `company(forBundleId:)`, `joinRate(bundleIds:)`, `joinRate(processNames:)`
- `relation` (OD12): `AppTable.relation(appCompany:labelParent:)` gives `unknown` when the app's company is unknown or the label has no parent (an unmatched domain, or an Apple owner string), `sameCompanyAsApp` when the two parents are equal ignoring case, otherwise `other`. `CompanyLabel.relative(toAppCompany:)` applies it, and `FlowLabels.label(for:index:cache:appCompany:)` passes the company of the app that made the flow
- Join rate: `tattle import-report <file> --join-rate [--unjoined-out <file>]` (nothing is stored) and `tattle apps coverage <capture> [--unmatched-out <file>]` print counts only; the id lists go to a local mode 600 file outside the work tree
- Join-rate floor: the local report test fails when the table joins under 65% of the report's distinct bundle ids (owner decision 2026-11-23, just under the rate measured then). Raise it as the table grows
- Owner decisions on process names (2026-11-23, app table version 2): `Maps`, `Music`, `News`, `Weather` and `MobileSlideShow` are Apple's built-in apps and stay mapped to Apple: they ship on every iPhone, and a third-party app is not known to use those exact executable names (if one does, it is counted as Apple; a known limit). TikTok and Threads have no process name, so they are matched only by bundle id (a report), never by a capture's process name, because other apps could use the same name
- Apple system processes (owner decision 2026-11-23, planned for the summary builder in 3.1, not built yet): a capture flow in the `system` traffic category (iOS system) will use Apple as the app's company, so Apple servers it contacts are `sameCompanyAsApp`. The app table will not be used for this, because Companies does not depend on Attribution. Until 3.1, `relation` stays `unknown` for those flows. A report bundle id under `com.apple.` already joins to Apple through the prefix row
- The table is a starting set. Capture names are mostly system daemons, which are not apps and are not in the table

## Source precedence and the agreement matrix (Problem 1.7)

Precedence is data: `Resources/precedence.tsv`, tab separated, header `field order exception note`, one row per field. `PrecedenceTable` loads it strictly (an unknown field, source or exception, a duplicate or missing field, a source that cannot answer the field, or an exception naming a source not in the row's order fails the whole load, with the line number only). Changing the order is a data edit: edit the file, run `scripts/build-precedence.sh`, run the tests.

| Field | Order | Exception |
|---|---|---|
| owner (company and parent) | curated, then appleOwner, then trackerList | `skip:appleOwner:cdnOperator`: an Apple owner that is a CDN operator is set aside |
| category | curated, then trackerList | none |

- Order set by the owner: curated then Apple (OD2), the AdGuard list last (1.6, decision D: the curated list always wins). Precedence table version 2
- Apple's `domainOwner` exists only for an imported report: `classify(hostname:appleOwner:)` takes it as a plain String (Companies never imports PrivacyReport). Capture flows pass no owner, so Apple plays no part there
- The category never comes from Apple, which gives none: the category row cannot list `appleOwner` (the load fails) and an Apple-only label has category `unclassified` and no parent
- `CompanyClassifier.resolve(hostname:appleOwner:)` returns the label plus which answers an exception skipped; `classify` returns its label. Passing an explicit `order:` still fixes the sources (the curated-only coverage baseline does)
- `Resources/apple-owner-aliases.tsv` (header `appleOwner kind parent note`): `alias` maps an Apple owner string to the curated parent it clearly is (a legal name of that company); `cdn` marks a CDN operator (Akamai, Fastly, Cloudflare) and also maps it to its parent. Matching is the whole string, ignoring case and runs of spaces; no fuzzy matching. Every `parent` is a curated parent (a test checks it). Amazon is an alias and not a CDN operator: the owner string cannot tell CloudFront from the company's other services
- Source-pair agreement uses the sources alone: `Agreement.measure` runs each source on its own and never lets one see the other. A name with no Apple owner is simply not answered by Apple

### Experiment design (OD2)

1. Classify every domain of an App Privacy Report with the curated list alone and with Apple's owner string alone
2. Count, per pair: both name the same parent, both name different parents, only one names it, neither. Bare IP addresses (OD16) have no name to classify: they are excluded and counted separately
3. Every disagreement (and every name only Apple named) goes to a local file outside the work tree; the owner reads it and sets the order
4. A name is the same when the curated parent and Apple's owner (through an alias row, else as written) are equal ignoring case. There is no "different category" count for this pair, because Apple gives no category

Command: `tattle companies agreement --report <file> [--disagreements-out <file>]` prints numbers only. The local file has columns `kind` (`different` or `onlySecond`, Apple only), domain, curated parent, curated category, Apple owner, aliased parent; mode 600, new file only, refused inside a git work tree. The public tracker list is not a source yet; `Agreement.measure` takes the pair as parameters, so adding it is a data and wiring change.

### Measured (2026-11-22, the owner's App Privacy Report v4, rates only)

Shares of the distinct domains with a name (bare IP addresses excluded):

| Outcome | Share |
|---|---|
| Curated only | 52.6% |
| Apple owner only | 1.7% |
| Both, same parent | 4.9% |
| Both, different parent | none |
| Neither | 40.8% |
| Same parent only through an alias row | 91% of the same-parent answers |
| Different parent where the owner is a CDN operator | 0 |
| Apple only where the owner is a CDN operator | 0 |

Before the alias table most of the same-parent answers showed as different: every one was a legal-name difference, none a real disagreement. The CDN exception changed no answer on this report (no CDN operator appears as an owner), so it is kept as a guard for other reports. With these numbers the two possible orders give the same label wherever both answer; they differ only in whether an owner string beats a curated name, which never changes the parent here.

Golden synthetic conflict set: `Tests/CompaniesTests/ConflictSetTests.swift`, 25 made-up names with made-up owners, each with an expected winner and rule; a coverage test checks that every source of every order and every exception of the bundled table is used by a case.

## AdGuard tracker list (Problem 1.6)

The second company source, after the curated list and Apple's owner string. Owner decisions 2026-11-23 (picks A2, B1, C, D).

- Data: `Resources/tracker/tracker.tsv` (header `domain company adguardCategory`, sorted, one row per AdGuard tracker domain, 5,126 rows), built by `scripts/build-tracker-list.sh` from a pinned copy that `scripts/fetch-tracker-list.sh` downloads into `~/dev/tattle-fixtures/tracker-list/` (outside the repo, with a provenance file). The app never downloads it. The manifest holds the commit, the shipped hash and the source hash
- Licence: CC BY-SA 4.0 (AdGuard), based on Whotracks.me (CC BY 4.0). Only the `tracker/` folder is under it; it has its own `LICENSE` and `README.md`. Check the licence's no-DRM rule before any App Store release
- Company: AdGuard's company name, trimmed. A tracker with no company keeps its tracker name as the company, unless that name is only a domain (237 rows): then the company is empty
- Parent (B1): `Resources/tracker-owner-aliases.tsv` (MIT, header `adguardCompany parent note`, 60 rows) maps an AdGuard company name to a curated parent, exact whole-string match only ("Meta Network" and "Twitter Counter" are different companies). Every parent is a curated parent (a test). The rows were taken from names that already match curated companies and from a comparison of the two public lists, never from the owner's data. Any other company is its own parent
- Investors and former owners (owner, 2026-11-23): where AdGuard names an investment firm or a former owner, the alias maps it to the operating company: SoftBank to Alibaba, Apollo and Verizon to Yahoo, Blackstone to Liftoff. Known limit: on some AdGuard-only domains AdGuard still names an earlier owner that is a real operating company (for example IAC on an old travel site); those keep AdGuard's name. The curated list wins wherever it has a row
- Category (C): `Resources/tracker-categories.tsv` (MIT, 17 rows, one per AdGuard category): advertising and pornvertising are advertising; site_analytics, mobile_analytics and telemetry are analytics; social_media is social; cdn is content delivery; hosting, customer_interaction, essential, consent and email are cloud service; audio_video_player and comments are online service; misc, unknown and extensions are unclassified. A category missing from the table fails the build script and the load
- Public suffixes: 31 AdGuard domains are themselves public suffixes (for example a CDN's shared domain). The loader skips and counts them, so a customer site under a hosting platform is never named after the platform (OD14)
- Lookup (A2): loaded once into memory, walks from the hostname up to the registrable domain like the curated list (rules `trackerHostname`, `trackerRegistrable`, dataset id `adguard-companiesdb`)
- A row with no company is not identified in 1.6 (source `none`, no category). Part 3 decides how its category is shown
- The app's tooltip uses the same words as for the curated list: "Company list version <date>" (owner, 2026-11-23); the source is in the label (`source: trackerList`)
- Commands: `tattle companies coverage ... --sources curated,trackerList` and `tattle companies agreement --report <file> --second trackerList`

### Budgets (measured 2026-11-23, debug build, the test alone)

| Budget | Limit | Measured |
|---|---|---|
| Added memory | at most 5 MB | about 4.5 MB |
| Load | (no limit set) | about 80 ms |
| Lookup | under 1 ms | about 6 µs |

- `bundledTrackerLoadIsCheapAndFast` prints the numbers and asserts only load under 5 s and lookup under 1 ms. Memory is not asserted: with other tests in parallel it reads about 20 MB. Read it with `swift test --filter bundledTrackerLoadIsCheapAndFast`. If memory grows past 5 MB, the fallback is the sorted file searched in place (A1)

### Coverage gain (fixture captures, domain coverage, curated alone then with the AdGuard list)

| Capture | Curated | Curated + AdGuard |
|---|---|---|
| s0-idle | 71.4% | 85.7% |
| s1-safari | 20.0% | 40.0% |
| s2-two-apps | 46.2% | 61.5% |
| s3-youtube-quic | 84.2% | 94.7% |
| s4-link-failures | 66.7% | 75.0% |
| s5-midstream | 80.0% | 100.0% |

- Byte coverage changes by less than 2 points in every capture: the large flows were already named by the curated list
- The band files stay curated-only (the frozen baseline)
- On the owner's App Privacy Report (rates only): the curated list identifies about 57% of the named domains alone; the AdGuard list adds about 8 points. Where both answer, they name the same parent on about 95% of domains; the curated list wins the rest. Owner-data rates are rounded to whole percents, so several rates together cannot give away the number of rows
- Public comparison of the two lists: of the 275 domains both list exactly, 231 name the same parent. The differences are name variants (now aliases) and AdGuard naming an earlier owner or a part owner (eBay for PayPal, Verizon for Yahoo, SoftBank for Alibaba). Owner decisions: Chartboost and Tapjoy stay their own companies; an investment firm is never the parent (Yahoo, not Apollo)

## Accuracy audit against two independent references (OD13)

Replaces the hand audit of Problem 1.5. Our classification is compared automatically with two references that we did not build; rows where a reference agrees with us are confirmed, and only the contradictions go to the owner by hand.

### References

- DuckDuckGo Tracker Radar domain-to-entity map (`build-data/generated/domain_map.json` of github.com/duckduckgo/tracker-radar, pinned at commit 815b4d9, recorded in full with the URL and SHA-256 in `ddg-provenance.txt`). Licence CC BY-NC-SA 4.0: used only as a reference for this audit, never bundled and never committed. `scripts/audit-references.sh entities` downloads it into `~/dev/tattle-fixtures/reference/` (folder mode 700, files 600)
- The organisation (`O=`) of the subject of the server's TLS certificate. `scripts/audit-references.sh certs <domains-file>` fetches each audited registrable domain's certificate once with `openssl s_client` (8 second timeout, 2 per second, results cached in `cert-orgs.tsv`, a failed fetch is cached as a failure and retried only with `RETRY_FAILED=1`). A certificate without an organisation (domain validated) is recorded as "no organisation"
- The app never fetches anything; only the script does. `Audit` in `Sources/Companies/Audit.swift` is pure and takes both references as values

### Method

1. Frame: the strata below. Bare IP addresses are excluded. Each row is a registrable domain, the parent company we name for it (curated first, then Apple's owner string by the decided order) and its category
2. Names are compared after normalisation (case, punctuation and legal words such as Inc, LLC, Ltd, GmbH removed), against our parent and our company name. The entity map's entity name, display name and aliases all count. A reference name also matches through an alias table: `Resources/reference-aliases.tsv` (header `referenceName parent note`, public company names only) together with the rows of `apple-owner-aliases.tsv`. Every alias parent is a curated parent (a test checks it)
3. Outcomes: confirmed (at least one reference names the same company), contradicted (no reference agrees and one names a different company), unverifiable (no reference answered). "No organisation" and a failed fetch are no answer, never a disagreement
4. Per stratum: n, confirmed, contradicted, unverifiable and the one-sided 95% upper bound (exact Clopper-Pearson, computed by bisection on the binomial distribution; 0 of 200 gives 1.49%, 0 of 50 gives 5.8%) of the contradiction rate among verifiable rows (confirmed plus contradicted)
5. Contradictions are written to a local file only, with the domain, our parent and category, the entity map's entity and the certificate organisation, so the owner can decide row by row. Mode 600, new file only, refused inside a git work tree

Command: `tattle companies audit --references <dir> [--report <file>] [--captures <dir>] [--contradictions-out <file>] [--domains-out <file>]` prints numbers only. `--domains-out` writes the audited domains for the certificate fetcher.

### The claim it supports

"Our company names agree with at least one of two independent sources on X% of the domains where a source gave an answer; every contradiction is checked by hand." It is not a measure of the category, and a confirmed row is only as good as the references: a reference can be wrong or out of date, and a certificate organisation can name the host rather than the site, which is why contradictions are read by the owner and not counted as errors until then. The bound is an upper limit on the contradiction rate, not on the error rate.

### Measured (2026-11-23, with the AdGuard list, numbers only)

Before the AdGuard list (2026-11-23, after the owner's review): curated 99.5%, captures 100.0% (0 of 32), owner data 100%. Before the review (2026-11-22): curated 92.4%, 28 contradicted.

Entity map: 38371 domains. Certificates: 27% of the fetched domains had an organisation, 51% had none and 21% failed.

| Stratum | n | Confirmed | Contradicted | Unverifiable | Agreement among verifiable | 95% upper bound of contradiction rate |
|---|---|---|---|---|---|---|
| Curated list entries | 385 | 365 | 2 | 18 | 99.5% | 1.7% |
| Capture confirmed names (six captures) | 38 | 37 | 1 | 0 | 97.4% | 11.9% |
| App Privacy Report named domains | – | – | – | – | about 97% | under 10% |
| Owner data together | – | – | – | – | about 97% | under 10% |

- Counts are not published for the owner's report (–): rates only, rounded to whole percents, and the bound only as a round "under" value, because exact rates with an exact bound give away the number of rows
- Of the confirmed rows, both references agreed on 79 curated rows and 14 capture rows
- The 2 curated contradictions were reviewed by the owner and kept: the brand is listed as its own parent, while the reference names a part owner. They stay counted
- The new contradictions come from AdGuard labels: AdGuard's company name against the company's legal name, and one old brand name of a company that was since merged into another. The owner reviewed them on 2026-11-23 as name noise and kept the labels. They stay counted. They cannot become aliases, because an alias parent must be a curated parent
- Owner rule (2026-11-23): show the brand, count the parent. A brand whose parent fully owns it (YouTube, Hulu, Blizzard) is counted as the parent; a separately listed company that another company only partly owns keeps its own name; an investment firm is never the parent
