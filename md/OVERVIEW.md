# Watch Project Overview

Watch shows which iPhone apps talk to which internet services, when, and how much. It is inspired by the CBC Marketplace investigation *The App Trap*: the goal is to make network activity that is normally invisible understandable to ordinary users.

Scope for now: **iPhone captured through a Mac over USB.** The iPhone app, Windows and Linux come later.

## What it is

- A Mac app that captures an iPhone's network traffic over USB, using Apple's Remote Virtual Interface (RVI)
- It reads Apple's per-packet process metadata (PKTAP), so traffic can be tied to the app that sent it
- It groups packets into network flows, extracts hostnames from DNS and TLS/QUIC handshakes, and stores the results locally
- It never decrypts anything. TLS and QUIC content stays encrypted; Watch reads only the unencrypted metadata around it

## Why build it

- iOS gives users almost no view of what apps send in the background
- Apple's App Privacy Report lists domains per app, but not volumes, timing, or which connection carried what
- A Mac on a USB cable can see much more than an iPhone app is allowed to see, without a jailbreak
- Watch should never claim to know more than it observed: unknown stays unknown

## Example

1. Plug the iPhone into the Mac and press Start in Watch
2. Open YouTube on the phone and watch a video
3. Watch shows the connections YouTube made, how many bytes each carried, and which hostnames they went to
4. Traffic from system services, and traffic with no process information, is shown separately instead of being credited to YouTube

## How it works (big picture)

```
iPhone ──USB──▶ rvi0 (rvictl) ──▶ tcpdump -U -w - ──stdout──▶ Watch
                                                              │
         PCAPNG reader ──▶ packet decoder ──▶ flow table ──▶ local store (7 days)
                                   │                ▲
                                   ├──▶ DNS + SNI ──┘
                                   └──▶ raw packet dropped
```

- tcpdump streams PCAPNG to Watch over stdout. Nothing raw is written to disk
- The reader turns the stream into packets, each with an interface, a timestamp, and process info (`proc` and `eproc`)
- The decoder reads IP and TCP/UDP headers, then the raw packet is dropped
- The flow table groups packets into connections and keeps a tally of the processes seen on each
- DNS answers and TLS/QUIC server names become domain evidence
- Flows and domain records are saved as they happen and kept for 7 days

Design mockups (made before the app was built; the app follows them): [connect](../img/01-connect.png), [grant access](../img/02-grant-access.png), [live capture](../img/03-live-capture.png), [settings](../img/04-settings.png), [pipeline](../img/pipeline.png)

## Requirements

IDs are used across the design docs.

### Functional

| ID | Requirement |
|---|---|
| F1 | Check the iPhone is on USB and that CoreDevice reports it as wired with a connected tunnel, before capturing |
| F2 | Start and stop RVI and tcpdump from Watch. Stop is immediate |
| F3 | Show clearly whenever a capture is running |
| F4 | Process packets live, while the capture runs |
| F5 | Decode IPv4, IPv6, TCP and UDP on Ethernet (en0, en2) and DLT_NULL (utun, pdp_ip0) interfaces |
| F5a | Extract the server name (SNI) from TLS and QUIC handshakes |
| F6 | Keep both process fields on every packet: `proc` and `eproc`, name and PID |
| F7 | Take packet direction from the capture metadata, not from guessing based on addresses |
| F8 | Group packets into flows: protocol, endpoints, start and end time, packet count, bytes |
| F9 | Extract hostname, CNAME chain and IP answers from DNS responses, with the app the lookup was for |
| F10 | Record each capture as a capture session (start, stop, device, source) |
| F11 | Ignore the 24-byte tcpdump trailer; report any other parse failure as an error |
| F12 | Never store or display decrypted or unencrypted content. Metadata only |

### Integrity

| ID | Requirement |
|---|---|
| I1 | "Unknown app" and "unknown domain" are separate states |
| I2 | Never assign an app based only on an IP address |
| I3 | A DNS answer is supporting evidence; it does not prove a connection happened |
| I4 | Keep raw process names and PIDs. Turning them into an app identity is a separate step that can be redone |
| I5 | One app can have several PIDs |
| I6 | Every number shown can be traced back to the packets it came from |
| I7 | Save observations as they arrive, not at the end of the capture |

### Non-functional

| ID | Requirement | Evidence |
|---|---|---|
| N1 | Keep up with at least 1,500 packets per second | multi-app test: 50,766 packets in ~35 s |
| N2 | Raw packets never written to disk in normal use. Records kept 7 days or until the user deletes them | ~62 MB raw per 35 s, ~6 GB per hour |
| N3 | Swift, unless benchmarks show it can't keep up | Reader parses 50,766 packets in 0.11 s |
| N4 | All data stays on the Mac. Nothing is sent anywhere | Privacy principle |
| N5 | Never show or log the device UDID | Privacy principle |
| N6 | Admin access is asked for, can be remembered, and can be revoked at any time | Product decision |

## Out of scope for now

- iPhone app and dashboard, App Privacy Report import
- Windows and Linux
- Company and tracker classification, IP geolocation, destination map
- Website-level filtering (V3)
- Blocking traffic

## Components

| Component | One-line summary | Status | Doc |
|---|---|---|---|
| Device | Is the iPhone plugged in and reachable (IOKit + CoreDevice) | Done: USB and CoreDevice checks work. Device name is hardcoded | [DEVICE.md](DEVICE.md) |
| PCAPNG reader | Turns the capture into packets with interface, time and process | Done, file and stream (14 tests) | [PCAPNG.md](PCAPNG.md) |
| Packet decoder | Reads IP and TCP/UDP headers, measures bytes | Done (21 tests, 0 malformed on fixtures) | [DECODER.md](DECODER.md) |
| Flows | Groups packets into connections with a process tally | Done (15 tests, invariants hold on fixtures) | [FLOWS.md](FLOWS.md) |
| Domains | DNS answers and TLS/QUIC server names | Done incl. QUIC (27 tests) | [DOMAINS.md](DOMAINS.md) |
| Attribution | Turns process evidence into an app identity, or leaves it unknown | Done (9 tests) | [ATTRIBUTION.md](ATTRIBUTION.md) |
| Storage | Local database, retention, delete | Done, SQLite3 (9 tests) | [STORAGE.md](STORAGE.md) |
| Pipeline | Wires it all; `flows` and `bench` CLI | Done (6 tests, ~620k packets/s) | [PIPELINE.md](PIPELINE.md) |
| App | Mac screens: connect, access, live capture, settings | Mockup done | [APP.md](APP.md) |
| Capture | Runs rvictl + tcpdump, streams into the pipeline | Done, live-tested (`capture` command, sudo mode) | [CAPTURE.md](CAPTURE.md) |
| Testing | Fixture captures, count checks, benchmarks | 111 tests, 5 fixture captures, live run | [TESTING.md](TESTING.md) |

## What we have proven

| Capability | Evidence |
|---|---|
| Mac detects the iPhone over USB | IOKit test, plugged and unplugged |
| Mac tells "paired" apart from "connected now" | CoreDevice JSON: transport `wired`, tunnel `connected` |
| RVI starts without Developer Mode | `rvictl -s` succeeded with Developer Mode off |
| Packet capture works, no kernel drops | 5 captures, 1,292 to 50,766 packets |
| Capture files are PCAPNG, despite the `.pcap` name | `file` command, reader |
| Process metadata is present | Safari, YouTube, TikTok, Instagram all attributed |
| Attribution follows app switches | multi-app test: TikTok then Instagram, in order |
| DNS lookups carry the app they were made for | `proc mDNSResponder, eproc TikTok` |
| tcpdump's end-of-file warning is harmless | Same 24-byte pcap header at the end of all 5 captures |
| Our reader matches tcpdump | Packet and per-process counts equal on every capture |
| The whole pipeline works live | 2026-11-16: 3-minute capture streamed from tcpdump, flows and domains saved, clean stop |
| The tcpdump "trailer" is a leading classic pcap header | Seen at the front of the stdout stream; `-P` removes it |

## Not proven yet

- Every app exposes process metadata (about 1% of packets have none)
- Every process can be mapped to an installed app
- RVI is reliable for long sessions
- VPN or tunnel traffic is not counted twice

## Current status

Updated 2026-11-17.

### Milestone 1: capture and analyse on the Mac (done)

| Step | Status |
|---|---|
| USB + device checks | Done |
| PCAPNG reader (file + stream) | Done |
| Packet decoder | Done |
| Flows | Done |
| Domains (DNS, TLS SNI, QUIC SNI) | Done |
| Attribution | Done |
| Storage (SQLite, 7-day retention) | Done |
| Pipeline + CLI (`read`, `flows`, `bench`, `capture`) | Done, ~620k packets/s |
| Mac app prototype (Connect, Live, Sessions, Settings) | Done, live-tested |

### Milestone 2: make the Mac results trustworthy (next)

| Item | Why | Needs the phone? |
|---|---|---|
| Restore fixture captures to `~/dev/watch-fixtures` | Regression checks currently skip | Yes, if the originals are lost |
| Classify Mac–phone link traffic (`heartbeatd`, `lockdownd`, `169.254.x`) | Keeps the USB plumbing out of app totals | No |
| Handle 16-character process names | `appstorecomponen` etc. must map to their app | No |
| Fill hostnames for connections older than the capture from earlier DNS, labelled as inferred | Biggest flows often have no name | No |
| Explain QUIC flows with no handshake | Two Google flows had no SNI | Yes, one `--diagnostic` capture |
| "On behalf of" label fix, `--device <name>` filter | Small correctness fixes | No |
| Quality report (`Report` target, `md/REPORT.md`): totals, reconciliation checks, M1-comparable metrics | Every later change must show up as a number | No |
| 30-minute stability capture | RVI long-session reliability unproven | Yes |
| VPN double counting | Untested; Private Relay is not a tunnel | Yes, needs a VPN |

### Milestone 3: user-facing product

| Item | Notes |
|---|---|
| Company and tracker classification | Domain → company list (bundled, offline) |
| Destination map | Geolocation of remote IPs, with the CDN caveat |
| Mac app polish | App filter, per-flow view, history across sessions |
| iOS app skeleton | App Privacy Report import; public APIs only (App Store priority). Committed scope: the report export (Settings → Privacy & Security → App Privacy Report → Save App Activity) covers the last 7 days while the phone is unplugged, which the Mac capture cannot. It lists app, domain and time, no bytes. Shown next to Mac captures, each labelled with its source |
| Signed helper (`SMAppService`) | Needs the $99 Developer Program; deferred by decision |

### Not started on purpose

- Windows / Linux (talking to the phone's capture service directly is a possible route)
- Website-level filtering (V3), blocking

## Full design

See [DESIGN.md](DESIGN.md).
