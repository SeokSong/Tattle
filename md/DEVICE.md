# Device

**Status:** Done (2026-11-16). `DeviceLookup` in `Sources/Capture` reads `devicectl list devices`; ready = wired + paired (the tunnel comes up on demand). Used by the CLI and the app. `capture --device <name>` picks the wired device by name via `DeviceLookup.select` (exact, else unique substring, case and apostrophe style ignored; ambiguous or missing = exit 3).

## Purpose

- Before a capture starts, answer: is the iPhone plugged in and reachable right now? (F1)
- A paired iPhone stays "paired" after the cable is pulled, so pairing alone can't answer this

## Checks

Two separate checks, both must pass.

- USB (IOKit)
    - Enumerate `IOUSBDevice` entries
    - Match vendor ID 1452 (Apple) and product name `iPhone`
- CoreDevice (`xcrun devicectl device info details --json-output`)
    - Run through Swift's `Process`, parse the JSON with `Decodable`

| State | Pairing | Transport | Tunnel |
|---|---|---|---|
| Connected over USB | paired | wired | connected |
| Unplugged | paired | absent | unavailable |

- Ready = transport `wired` **and** pairing `paired`. The tunnel state is shown but not required: `devicectl list devices` reports `tunnelState: disconnected` for a plugged-in paired phone until something opens the tunnel (`device info details` does), and RVI capture works without it (found 2026-11-16 when the app's Device link row stayed red)
- Developer Mode was off in every test and capture still worked. Not a requirement

## Known issues

- The CLI's device check uses the first wired device from `DeviceLookup` (no device name is hardcoded)
- The UDID needed by `rvictl -s` is found by hand today
    - Get it from the same devicectl JSON. Keep it in memory only, never log it (N5)
- `devicectl` takes a few seconds. Fine before a capture, too slow for polling

## Interface (proposed)

```swift
struct DeviceStatus {
    let usbConnected: Bool
    let pairing: String?
    let transport: String?
    let tunnel: String?
    let name: String?
    var isReady: Bool
}

func checkDevice() async throws -> DeviceStatus
```

## Tests

- Decode saved devicectl JSON for both the connected and unplugged states
- `isReady` is false for every row that isn't wired + connected

## Open questions

- More than one iPhone plugged in: pick one, or ask?
- Is IOKit still needed once devicectl reports transport `wired`?

## See also

[CAPTURE.md](CAPTURE.md) · [APP.md](APP.md)
