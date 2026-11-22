# Companies

**Status:** Problems 1.1 and 1.2 done: registrable domain from the bundled Public Suffix List, the curated company list and `CompanyClassifier`. Second sources (public tracker list) and the app to company table come later.

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
- ICANN section only: the shipped `psl.dat` drops the private section, so `x.github.io` gives `github.io` and `a.blogspot.com` gives `blogspot.com`. Hosting platforms are treated as one registrable domain on purpose
- Internationalised names: the list stores unicode rules; `xn--` labels are decoded (RFC 3492) for matching and returned as written

## Datasets

| Dataset | File | Source | Licence |
|---|---|---|---|
| Public Suffix List | `Resources/psl.dat` | https://publicsuffix.org/list/public_suffix_list.dat | MPL 2.0 |

- `psl.dat` is the list's licence header plus its ICANN rules, built by the script; never edit it by hand. The manifest holds the SHA-256 of both the shipped file and the downloaded original, and a test checks the shipped hash
- `NOTICES.txt` holds the full MPL 2.0 text and the source URL; the licence header stays in the data file
- Tattle's own code is MIT (`LICENSE`)
- To update: download the list by hand, run `scripts/build-companies-data.sh path/to/public_suffix_list.dat [YYYY-MM-DD]`, run the tests
- The repo guard allows a 40-hex value only on a line labelled as a commit (`// COMMIT:` or a `"commit"` key), for this data's provenance

## Resources

- `Bundle.module` finds the files under `swift run`, `swift build -c release` and `swift test -c release` (checked)
- Risk: a future `.app` bundle must copy `Tattle_Companies.bundle` into `Contents/Resources`, or `resourceURL` returns nil. When the resource is missing, `PublicSuffixList.bundled.isLoaded` is false and every name falls back to the one-label default rule

## Budgets

| Budget | Limit | Measured (2026-11-22) |
|---|---|---|
| Cold start (first call, parse) | at most 30 ms | about 7 ms release, about 23 ms debug |
| Added memory | at most 5 MB | about 0.6 to 1.8 MB |
| Data size | at most 3 MB | 76 KB (6950 rules) |

- Provisional. `loadCostIsPrinted` prints load time and added memory and asserts the 200 ms sanity floor and the 3 MB data size. Memory is not asserted (parallel tests inflate the process footprint); read it from `swift test -c release --filter Companies`

## Curated list and classifier (Problem 1.2)

- File: `Resources/curated.tsv`, tab separated, one header line `domain company parent category note`. `md/COMPANIES-curated.md` is the readable table (generated, sorted by category, with counts) that the owner reviews
- `domain` is a registrable domain or a hostname under one, lowercase, no trailing dot. `category` is one of `advertising`, `analytics`, `social`, `contentDelivery`, `cloudService`, `appleSystem` (`unclassified` is the absence of a row and is rejected). `note` is a short public rationale with no adjectives
- Every row has source `curated`. Rows are built from public knowledge of widely known companies only; they are never chosen from anyone's captures or reports. A domain whose owner is not certain is left out, not guessed
- Load is strict: an unknown category, a duplicate key, a key that is not registrable (or not lowercase), an empty field or a wrong column count fails the whole load. The error names the line number only, never a value
- Lookup ladder: the full hostname, then each parent suffix down to and including the registrable domain; the most specific row wins (`ads.example.com` can differ from `example.com`). Names are matched whole, never by substring. No match gives an explicit label with category `unclassified` and source `none`
- Categories (raw value, label, meaning): `advertising` (Advertising), `analytics` (Analytics), `social` (Social media), `contentDelivery` (Content delivery: servers rented to deliver files and video), `cloudService` (Cloud or app service: behind-the-scenes infrastructure only, such as hosting, storage, payments, sign-in, APIs, certificates, email delivery used by other companies), `appleSystem` (Apple system), `onlineService` (Online service: a company's own product people use directly, such as video and music sites, games, email, office apps, maps, search; decision OD11), `unclassified` (Not matched). Only advertising and analytics count as advertising or tracking
- A domain used both as a product and as an API stays `cloudService`; the generated review table lists every row so the owner can move it
- API: `CompanyClassifier(curated:)` (immutable, `Sendable`). `classify(hostname:appleOwner:order:)` tries sources in `order` (provisional `[.curated, .appleOwner]`; precedence is decided later by the agreement experiment). `label(hostname:from:appleOwner:)` runs exactly one source and never looks at another. `labelsBySource(hostname:appleOwner:)` returns every source's answer for comparison
- `CompanyLabel.source` says who answered (`curated`, `trackerList`, `appleOwner`, `none`); `rule` says which rung (`curatedHostname`, `curatedRegistrable`, `appleOwner`, `noMatch`); `datasetId` (`tattle-curated`), `datasetVersion` and `datasetSHA256` come from the manifest. The `appleOwner` source returns the report's owner string as `company` with no parent and category `unclassified`, because the report gives neither. `relation` is `unknown` until the app to company table exists
- To change the list: edit `curated.tsv`, run `scripts/build-curated.sh [version]` (refreshes the manifest hash, row count and the review table), run the tests. Bump the version when the content changes
- Cost: `lookupCostIsPrinted` prints the per-hostname cost of `classify` (sanity floor 200 microseconds)
