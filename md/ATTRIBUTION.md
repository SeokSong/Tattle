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
- `supportingDomains`: DNS observations where `flow.key.remoteAddress ∈ addresses`, `effectiveName == winner app name` (or either nil), `time ≤ flow.firstSeen`, and `flow.firstSeen − time ≤ ttl` (ttl nil → 300 s); plus the SNI observation whose `flowKey == flow.key`. SNI first, then DNS by time descending

### Tests

- Each state from a hand-built tally
- Two PIDs, one app → `.app` with both pids
- `mDNSResponder` with eproc TikTok → `.onBehalfOf(TikTok, via mDNSResponder)`
- Mixed: YouTube 100 + TikTok 5 → primary YouTube, `mixed == true`
- Only `.none` → `.unknown`
- `supportingDomains` respects address, app, time order and TTL
- Rerunning over the same input gives equal results (pure)

## Found in the first live capture (2026-11-16)

- Process names are truncated to 16 characters by the kernel (`appstorecomponen`, `AppStoreOverlays`). Any name-to-app mapping must match on the truncated form
- The Mac–phone USB link shows up in the capture: `heartbeatd`/`lockdownd` TCP on a `fd5d:...` address, and link-local `169.254.100.1`. Classify as `deviceLink` and keep out of app totals. Not implemented yet
- A connection that already existed when the capture started has no handshake and no DNS in the capture, so it shows as app-attributed with no hostname (a 27 MB YouTube flow in the live run). Expected; later, earlier DNS evidence could fill it in, labelled as such

## Open questions

- Is a background app (TikTok during the YouTube capture) shown differently from the app in use? We can't tell which app was on screen
- Which system processes should be grouped under the app they serve?

## See also

[FLOWS.md](FLOWS.md) · [DOMAINS.md](DOMAINS.md) · [APP.md](APP.md)
