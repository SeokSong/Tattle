# Attribution

**Status:** Done (2026-11-16). `Sources/Attribution`, 9 tests. State is decided from the largest row of the winning group: a system `proc` with an app `eproc` → `.onBehalfOf`; a system group name → `.system`; else `.app`. Ties break by name. `packetsTotal` includes `.none` rows.

## Purpose

- Turn the process evidence on a flow into "which app was this", or say we don't know
- Runs when reading, over stored evidence, so the rules can change without recapturing (I4)

## Evidence

- Per-flow process tally (`proc` + `eproc`, name and PID) from [FLOWS.md](FLOWS.md)
- Nothing else. Never IP address alone (I2), never "the app that was open at the time"

## States

| State | Meaning | Example |
|---|---|---|
| App | Packets tagged with an app's process | `YouTube:18940` |
| On behalf of app | A system process tagged with an app as `eproc` | `mDNSResponder` for `TikTok` |
| System | A system process with no app | `locationd`, `apsd`, `nsurlsessiond` |
| Unknown | No process info | ~1% of packets |

- Unknown app and unknown domain are independent (I1)
- A flow can be "TikTok, domain unknown" or "unknown app, `example.com`"

## Rules (proposed)

- An app name groups all its PIDs (I5). Instagram had 18957 and 18958
- `eproc` wins over `proc` for the app, but both stay visible
- Mixed tally: the app with most packets, plus a "mixed" marker showing the rest
- Tally entirely "none": Unknown

## Process name to app

- PKTAP gives process names, not bundle ids (`YouTube`, `com.apple.WebKit`, `MobileSafari`)
- V1: show the process name as the app name
- Later: a mapping table for system processes and helpers (`com.apple.WebKit` → Safari when `eproc` says so)

## Seen so far

| Capture | Top processes (packets) |
|---|---|
| YouTube | YouTube 24,497 · locationd 2,609 · mDNSResponder 606 · nsurlsessiond 584 · none 455 |
| multi-app | Instagram 40,514 (2 PIDs) · TikTok 8,909 · none 533 |
| clean | TikTok 781 · nsurlsessiond 257 · none 88 · mDNSResponder 50 |

- Counts are packets, read by our reader. Not bytes yet

## Implementation spec

Target `Attribution`, depends on `Flows`, `Domains`. Pure functions, no state, no I/O.

```swift
public enum AppAttribution: Equatable, Sendable {
    case app(name: String, pids: Set<UInt32>)               // packets tagged with an app process
    case onBehalfOf(app: String, via: String)               // system proc with an app eproc
    case system(name: String)
    case unknown
}

public struct AttributionResult: Sendable {
    public let primary: AppAttribution
    public let packetsForPrimary: Int
    public let packetsTotal: Int
    public let mixed: Bool          // more than one non-none app in the tally
}

public enum Attributor {
    public static func attribute(_ tally: [ProcessPair: Int]) -> AttributionResult
    public static func isSystemProcess(_ name: String) -> Bool
    public static func supportingDomains(for flow: Flow, in domains: [DomainObservation]) -> [DomainObservation]
}
```

- `attribute`: group rows by app name = `effectiveName ?? processName`; skip `.none` rows. Winner = largest packet count. If the winner's name is a system process and the row had no `effectiveName` → `.system`; if it had an `effectiveName` → `.onBehalfOf`. Tally with only `.none` rows → `.unknown`. `mixed` = ≥ 2 distinct app names among non-system rows
- `isSystemProcess`: a fixed list in code (`mDNSResponder`, `nsurlsessiond`, `apsd`, `locationd`, `geod`, `trustd`, `cloudd`, `rapportd`, `identityservices`, `kernel_task`, `storekitd`, `appstored`, `amsengagementd`, `transparencyd`, `maild`, `TilesService`, `ConnectMobile`, `watchlistd`, `networkserviceproxy`, `destinationd`, `symptomsd`, `wifid`, `CommCenter`, `dataaccessd`, `itunescloudd`, `passd`, `searchpartyd`, `sharingd`, `timed`, `assistantd`, `akd`, `accountsd`, `AppleIDAuthAgent`, `appleaccountd`, `familycircled`, `findmydeviced`, `fmfd`, `gamed`, `homed`, `healthd`, `mediaremoted`, `nsurlsessiond`, `siriknowledged`, `suggestd`, `weatherd`, `webbookmarksd`, `wifianalyticsd`). Unknown names count as apps. Keep the list in one file so it's easy to extend
- `supportingDomains`: the list form of the rule in "Hostname resolver" below (one implementation, `DNSRule`, shared with `HostnameIndex`). SNI observation for the flow key first, then qualifying DNS answers newest first, ties by smaller hostname

### Hostname resolver (`Hostnames.swift`)

- `HostnameIndex(observations)` is built once per session; `resolve(flow)` and `resolveWithoutSNI(flow)` return `ResolvedHostname { name, source, dnsAgeSeconds, echPresent }?`
- Pure: no I/O, no clock, no network. Evidence is the same capture only. Nothing is stored

| Source | Label | Rule |
|---|---|---|
| `sni` | Seen in connection | `flow.serverName`, else the SNI observation for `flow.key`. `echPresent` is true when the flow or the observation saw ECH (the name is then the outer name) |
| `dns` | Seen in DNS this session | newest answer containing `flow.key.remoteAddress` with `time ≤ flow.firstSeen`, `flow.firstSeen − time ≤ ttl` (inclusive; nil ttl → 300 s) and an app match |

- App match: flow app = winner of `attribute(tally)` (app, on-behalf-of app, or system process name). Answer app = `effectiveProcess?.name ?? process?.name`. Names are compared after `ProcessNames.displayName`. An answer with no app matches any flow. A flow with no app (unknown) matches only answers with no app
- Ties on time: smaller hostname wins
- `resolveWithoutSNI` runs the dns step only (for `dnsPrecision`)
- Out of scope: `dnsEarlier`, reverse DNS, CNAME chasing beyond the stored query name

### Tests

- Each state from a hand-built tally
- Two PIDs, one app → `.app` with both pids
- `mDNSResponder` with eproc TikTok → `.onBehalfOf(TikTok, via mDNSResponder)`
- Mixed: YouTube 100 + TikTok 5 → primary YouTube, `mixed == true`
- Only `.none` → `.unknown`
- `supportingDomains` respects address, app, time order and TTL
- `HostnameIndex.resolve` agrees with `supportingDomains` on generated data; see `HostnamesTests`
- Rerunning over the same input gives equal results (pure)

## Traffic categories

The report prints bytes, packets, flows and share per category, bytes per rule and the bytes moved out of app totals: see [REPORT.md](REPORT.md#categories).

`Classifier.classify(_ flow:)` gives each flow one `TrafficCategory` and the name of the rule that decided it. It reads the flow's tally, the winning row's process names and both addresses.

| Category | Label | Rule names |
|---|---|---|
| `app` | From app | `app.process` |
| `helper` | Helper for an app | `helper.eproc` |
| `system` | iOS system | `system.process` |
| `deviceLink` | USB link to this Mac | `deviceLink.process`, `deviceLink.linkLocal` |
| `localNetwork` | Local network only | `localNetwork.address` |
| `unknown` | No process info | `unknown.noProcess` |

Precedence, first match wins:

1. `deviceLink.process`: the winning row's process is in `deviceLinkProcesses` (`heartbeatd`, `lockdownd`), compared in cut form
2. `app.process` or `helper.eproc`: the winning group is an app. `helper.eproc` when the winning row has a process and a different effective process, or a system process works for an app
3. `deviceLink.linkLocal`: no app evidence and both addresses are link-local (169.254.0.0/16, fe80::/10)
4. `localNetwork.address`: no app evidence and the remote address is local-only
5. `system.process`: the winning group is a system process
6. `unknown.noProcess`: no process evidence

- Never moves an app-tagged flow: an `app` or `helper` flow stays in its category whatever the addresses are (a NAS at 192.168.1.20, a work server at 10.x)
- Local-only addresses: multicast (224.0.0.0/4, ff00::/8), 255.255.255.255, loopback (127.0.0.0/8, ::1), link-local, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7. Not 100.64.0.0/10: real servers can sit there
- Phone traffic = `app` + `helper` + `system` + `unknown`; app traffic = `app` + `helper`
- `deviceLinkProcesses` is the only process allowlist; a name like `heartbeat` is an app

## Found in the first live capture (2026-11-16)

- Process names are truncated to 16 characters by the kernel (`appstorecomponen`, `AppStoreOverlays`). Any name-to-app mapping must match on the truncated form. Implemented, see "Names are cut to 16 characters"
- The Mac–phone USB link shows up in the capture: `heartbeatd`/`lockdownd` TCP on a `fd5d:...` address, and link-local `169.254.100.1`. Classify as `deviceLink` and keep out of app totals. Implemented by `Classifier`, see "Traffic categories"
- A connection that already existed when the capture started has no handshake and no DNS in the capture, so it shows as app-attributed with no hostname (a 27 MB YouTube flow in the live run). Expected; later, earlier DNS evidence could fill it in, labelled as such

## Names are cut to 16 characters; matching rules

- The kernel cuts process names to 16 characters, so PKTAP never gives a longer one (`networkserviceproxy` arrives as `networkservicepr`)
- `isSystemProcess(name)` is true when `name` equals a listed full name or its 16-character cut form. Both sets are built once from `systemProcessNames`
- Matching is exact on one of those two forms. A prefix match is not enough: `apsd2` is not `apsd`
- Bug fixed: `networkserviceproxy` (19 characters) could never match before
- A test checks every entry of `systemProcessNames` matches as written and as cut
- `ProcessNames` (`Sources/Attribution/ProcessNames.swift`): `maxLength`, `cut`, `matches(raw, full:)`, `displayName`
- Raw names stay in storage and in `ProcessPair`. Display names are derived, never stored over the raw name

| Raw (cut) name | Display name |
|---|---|
| `appstorecomponen` | App Store (component) |

- Unknown names display as they are. The table grows from real top names, in `ProcessNames.swift` only
- Not wired into the by-process screen yet

## Open questions

- Is a background app (TikTok during the YouTube capture) shown differently from the app in use? We can't tell which app was on screen
- Which system processes should be grouped under the app they serve?

## See also

[FLOWS.md](FLOWS.md) · [DOMAINS.md](DOMAINS.md) · [APP.md](APP.md)
