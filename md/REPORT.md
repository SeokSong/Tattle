# Quality report

The `Report` target turns flows and domains into a `QualityReport`: totals, reconciliation checks and metrics. Every later change to attribution or hostnames must show up as a number here.

## Rules

- Pure logic: no clock, no files, no processes. Only types it is given
- Byte counts are IP bytes: `ipBytesIn + ipBytesOut` of a flow
- A flow counts whole, including packets before its name was found
- Deterministic: sorted keys, pretty printed, no rounding; input order does not change the output
- The JSON holds no hostnames, addresses or process names, except `detail` (below)
- `reportVersion` is 1. The `categories` section (4.2) only adds keys; no earlier key changed, so the version did not move

## API

- `ReportBuilder.build(flows:domains:pipeline:options:) -> QualityReport`
- `QualityReport.json()` returns the sorted, pretty-printed JSON
- `PipelineSnapshot`: `packets, decoded, skipped, malformed, droppedNoPort`. Pass nil when reporting a stored session
- `ReportOptions`: `detail` (default false), `watchVersion` (default `dev`)

## Ratio

Every ratio prints as `{numerator, denominator, value}`. `value` is absent when the denominator is 0.

## Metrics implemented

| JSON key | Numerator | Denominator | Example |
|---|---|---|---|
| `attribution.attributedShare` (M1-comparable) | Bytes of flows where `Attributor.attribute(tally).primary` is not `.unknown` | `totals.ipBytes` | 300 of 400 = 0.75 |
| `attribution.noProcessShare` | Bytes of flows whose tally has only `ProcessPair.none` rows | `totals.ipBytes` | 100 of 400 = 0.25 |
| `attribution.mixedFlowShare` | Bytes of flows with more than one non-system app name | `totals.ipBytes` | 100 of 200 = 0.5 |
| `hostnames.hostnameCoverageSniOnly` (M1-comparable) | Bytes of flows with remote port 443 and a `serverName` | Bytes of flows with remote port 443 | 200 of 300 = 0.667 |

Other fields:

| JSON key | Meaning |
|---|---|
| `totals.flows`, `totals.packets`, `totals.ipBytes` | Flow count, sum of `packetsIn + packetsOut`, sum of IP bytes |
| `byInterface` | IP bytes by `flow.interface` |

Baseline note:

- `hostnameCoverageSniOnly` here has no categories yet: its denominator is all flows with remote port 443
- Problem 5.1 narrows it to `appTraffic` flows and records the change in the band file note
- The baseline records both versions: the M1 view, and the narrowed view recomputed on the same captures

Not here yet: the other hostname metrics (5.1), added later as new fields.

## Categories

Added in 4.2. Each flow is classified once by `Classifier` (see [ATTRIBUTION.md](ATTRIBUTION.md#traffic-categories)) and counts whole. Bytes are IP bytes.

| JSON key | Meaning |
|---|---|
| `categories.byCategory.<category>` | `{flows, packets, ipBytes, share}` for each of `app`, `helper`, `system`, `deviceLink`, `localNetwork`, `unknown`. All six always present. `share` = `ipBytes` / `totals.ipBytes` |
| `categories.rules.<rule>` | Bytes per rule name (`app.process`, `helper.eproc`, `system.process`, `deviceLink.process`, `deviceLink.linkLocal`, `localNetwork.address`, `unknown.noProcess`). Only rules that matched appear. Sum equals `totals.ipBytes` |
| `categories.movedOutOfAppBytes.<category>` | Plain bytes (`deviceLink`, `localNetwork`) of flows that M1 attribution called app, on-behalf-of or system and that are now in that category. A flow M1 called unknown is not "moved" |
| `categories.phoneTrafficShare` | (`app` + `helper` + `system` + `unknown` bytes) / `totals.ipBytes` |
| `categories.unknownShare` | `unknown` bytes / `totals.ipBytes`. Same ratio as `byCategory.unknown.share` |
| `categories.systemTopProcessShare` | Bytes of the largest single process in `system` / all `system` bytes. Shows a catch-all `system` bucket without names. No value when `system` has no bytes |

- `noProcessShare` is measured on the tally alone; `unknownShare` is measured after the rules. `unknownShare` can be lower (a no-process multicast flow is `localNetwork`). The text report prints them on adjacent lines with that note
- Classification follows `Classifier` only: a flow with several process groups is not split
- Check `categoryBytes`: sum of category bytes equals `totals.ipBytes`

Example on the synthetic corpus (10710 bytes): `app` 10189, `helper` 185, `deviceLink` 180, `localNetwork` 156, `system` 0, `unknown` 0; `movedOutOfAppBytes.deviceLink` 180.

Detail mode adds, by display name: `detail.systemProcesses`, `detail.deviceLinkProcesses` (`{name, flows, ipBytes}`, up to 20 each) and `detail.systemTopProcess`.

## Reconciliation checks

Each check prints `name`, `expected`, `actual`, `ok`. `reconciliation.ok` is the AND of the checks that could be evaluated.

| Check | Expected | Actual | Needs pipeline stats |
|---|---|---|---|
| `packetsRead` | `packets` | `decoded + skipped + malformed` | Yes |
| `decodedAccounted` | `decoded` | sum of flow packets + `droppedNoPort` | Yes |
| `categoryBytes` | `totals.ipBytes` | Sum of `categories.byCategory.*.ipBytes` | No |
| `interfaceBytes` | `totals.ipBytes` | sum of `byInterface` | No |
| `flowTimes` | flow count | flows with `lastSeen >= firstSeen` | No |

## Detail mode

- Off by default. With `options.detail`, the report adds `detail.topProcesses`: up to 20 lines of `{name, flows, ipBytes}`, grouped by display name of the winning process, sorted by bytes then name
- Process names appear only there. Hostnames and addresses never appear in any mode

## Scenario files

- A scenario file says what the phone did during a capture. It names apps and sites, so real ones live in `~/dev/watch-fixtures/scenarios/<id>.json` and are never committed
- Only `id` and `windows` are required

```json
{
  "id": "s1-safari",
  "windows": [{ "start": 10, "end": 70, "expectedTopApp": "MobileSafari" }],
  "expectedApps": ["MobileSafari"],
  "expectedHosts": ["example.com", "iana.org", "example.org"],
  "mustNotBeDeviceLink": ["MobileSafari"],
  "slackSeconds": 5
}
```

| Field | Meaning |
|---|---|
| `windows[].start`, `end` | Seconds after the first packet of the capture (the earliest `firstSeen` of any flow) |
| `windows[].expectedTopApp` | App that should carry the most bytes in the window. Empty or absent: no expectation (idle phone) |
| `expectedApps` | Apps that should appear in app traffic in any window |
| `expectedHosts` | Hosts that should be matched by a resolved name. Match: the name equals the host or ends with `.` + host (`cdn.example.com` matches `example.com`, `notexample.com` does not) |
| `mustNotBeDeviceLink` | Process names that must never be in the `deviceLink` category. Scored by `deviceLinkFalsePositives` |
| `slackSeconds` | Default 5 |

Scoring rules:

- A window scores only flows whose `firstSeen` is inside `[start + slackSeconds, end]`. Flows that began before the window are ignored, even if they carry bytes inside it
- App traffic: flows whose winning process group is a non-system app, or a system process working for an app. Bytes are IP bytes in plus out. Still computed from `Attributor` (the `appTraffic` category matches it except for device link flows)
- An expected app or top app matches a raw (16-character) process name when equal, when the raw name is the cut form of the expected name, or when its display name equals the expected name
- Each window is scored on its own for `topAppMatch`; recall and `unlabelledShare` pool the windows

| Score | Meaning |
|---|---|
| `topAppMatch` | Windows with an expected top app that matched, over windows with one |
| `appRecall` | Expected apps found, over expected apps |
| `hostRecall` | Expected hosts matched by `HostnameIndex.resolve` names (SNI or DNS), over expected hosts |
| `unlabelledShare` | App bytes of apps not in `expectedApps`, over all app bytes in the windows. Information, not an error |
| `deviceLinkFalsePositives` | Count of flows in the windows that are `deviceLink` and carry a process named in `mustNotBeDeviceLink`. Must be 0 |

## Band files

- A band file holds the numbers a scenario's report must stay inside. Committed as `Tests/Expected/<id>.json`
- Privacy rule: no hostnames, no addresses, no process names. Only metric keys and numbers. `RepoGuardTests` scans the folder

```json
{
  "scenario": "s1-safari",
  "baselineLabel": "m1-2026-11-DD",
  "totalsBand": { "ipBytes": "1-2 MB" },
  "metrics": {
    "noProcessShare": { "baseline": 0.012, "floor": 0.0, "ceiling": 0.017 },
    "hostnameCoverageSniOnly": { "baseline": 0.91, "floor": 0.905, "ceiling": 1.0 }
  },
  "notes": [{ "metric": "hostnameCoverage", "reason": "narrowed to appTraffic in 5.1" }]
}
```

Metric keys: `attributedShare`, `noProcessShare`, `mixedFlowShare`, `hostnameCoverageSniOnly`.

Ratchet rules (`Ratchet.check(report:bands:)`):

- Fails when `value < floor` or `value > ceiling`. A value equal to a limit passes
- Not enforced: bands with `"informational": true`, metrics missing from the report, and metrics whose denominator is under 10,000 bytes (too few bytes to mean anything) or 0
- A regression prints the metric key, the value, the limit and the distance in percentage points

Tolerance rule, applied when a band file is written (`Bands.make`, values rounded to 3 decimals, kept in 0 to 1):

| Direction | Metrics | Floor | Ceiling |
|---|---|---|---|
| Lower is better | `noProcessShare`, `mixedFlowShare` | 0.0 | baseline + 0.005 |
| Higher is better | `attributedShare`, `hostnameCoverageSniOnly` | baseline - 0.005 | 1.0 |

- `totalsBand.ipBytes` is a rounded range (`"1-2 MB"`), information only, not enforced
- A metric with a denominator under 10,000 bytes is written with `"informational": true` and no floor or ceiling
- Writing over an existing file keeps its `notes`

## Command

```sh
WatchCapture report <file.pcap|pcapng> [options]
WatchCapture report --db <path> --session <id|latest> [options]
```

| Option | Effect |
|---|---|
| `--detail` | Add process names |
| `--json` | JSON instead of text. With `--scenario` or `--bands` the output is `{"report", "score", "regressions"}` |
| `--scenario <file>` | Print the scenario score (numbers only) |
| `--bands <file>` | Run the ratchet; print each regression. The scenario ids of the two files must agree when both are given |
| `--write-bands <file> --label <text>` | Write a band file from this report. Not together with `--bands` |

Exit codes: 0 ok, 2 a reconciliation check failed, 3 a band regression (2 wins when both), 1 other error.
