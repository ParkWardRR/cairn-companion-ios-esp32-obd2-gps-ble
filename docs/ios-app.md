# iOS app design

## Stack

| Layer | Choice |
|---|---|
| Language / UI | Swift, SwiftUI |
| State | Observation (`@Observable`), no Combine / `ObservableObject` |
| Concurrency | async/await, structured concurrency, `AsyncSequence` for location and BLE streams |
| Location | `CLLocationUpdate.liveUpdates(.automotiveNavigation)` |
| Background | `CLBackgroundActivitySession`, `location` + `bluetooth-central` modes |
| BLE | CoreBluetooth central, state restoration |
| Min OS | iOS 17 (Observation, `liveUpdates`, `CLBackgroundActivitySession`) |
| Repo | Standalone; protocol spec mirrored in the Cairn firmware repo |

Use the live-updates API with a `LiveConfiguration`; do not mix it with `CLLocationManager`-style `desiredAccuracy`. Cadence is system-managed. The app filters to a ~1 Hz transmit target (drop extras; tolerate gaps).

## Phase 1 screen

One screen:

- **Auto-connect to Cairn** switch (on by default). The session follows the dongle: it starts when the link is bonded and stops when it drops. No Start button
- Connection state: scanning → connecting → bonded → streaming
- Phone location: accuracy (m), fix age, speed, validity
- Device GNSS (from `GNSS_QUALITY`): fix type, sats used, HDOP
- Acceptance (from `COMPANION_STATUS`): last seq, accepted / rejected / dropped

Not shown: satellite count or constellation. Core Location does not expose them.

## Background driving session

A windshield mount does not keep the app foregrounded. Locking the screen or opening Maps is normal, and the app is usually launched by the car powering the dongle, not by the user.

- While auto-connect is on, the app holds a pending `connect` to the bonded dongle (or scans by service UUID before the first bond). It uses no location while waiting.
- When the link is bonded and `PROTOCOL_VERSION` is accepted, `DrivingSession` creates a `CLBackgroundActivitySession` and starts `liveUpdates`. When the link drops, it ends both and goes back to waiting.
- Starting location from a background BLE wake needs **Always** authorization; While In Use only covers a foregrounded start. The app requests Always. This must be validated on a device (BLE wake from suspended and from system-terminated, location starts, fixes accepted).
- `CBCentralManager` uses `CBCentralManagerOptionRestoreIdentifierKey`. Restoration and relaunch depend on pending BLE operations and system conditions. A force-quit app is not relaunched by iOS. The app does its own reconnect logic and does not assume the system will.
- The switch off ends location and BLE activity and clears the pending connect.

## Pairing

First pairing is manual and in the foreground: the first read of an encrypted characteristic makes iOS ask for the dongle's static 6-digit passkey. iOS then stores the bond and later reconnects are silent. The dongle holds one bond; a new phone replaces the old one. If the dongle's bond is reset (boot-time button or firmware command), remove "Cairn" under Settings > Bluetooth > (i) > Forget This Device on the phone, then pair again. The app cannot remove an iOS bond itself.

## Encoding rules (`PayloadEncoder`)

| CLLocation condition | Wire result |
|---|---|
| `horizontalAccuracy < 0` | `fix_type 0`, `validity b0 = 0`, firmware rejects |
| `verticalAccuracy < 0` | `fix_type 1`, `validity b1 = 0`, `alt_cm = 0x7FFFFFFF` |
| `speed < 0` | `speed_cmps = 0xFFFF`, `validity b2 = 0` (never 0 cm/s) |
| `course < 0` | `heading_cdeg = 0xFFFF`, `validity b3 = 0` (never north) |
| accuracy × 100 > 65534 | clamp to 65534 (never wrap to a small value) |
| `now − timestamp > 2 s` | drop, do not send |

`sample_age_ms` is computed at write time. `seq` increments per sent fix, wraps at 2¹⁶.

## Layout

```
CairnCompanion/
├── Sources/
│   ├── App/CairnCompanionApp.swift
│   ├── BLE/        CairnBLEManager, CairnGATTProfile, PayloadEncoder, PayloadDecoder
│   ├── Location/   LocationStream (liveUpdates), BaroStream (Phase 2)
│   ├── Session/    DrivingSession (background session lifecycle), SessionState (@Observable)
│   ├── Models/     PhoneGNSSFix (validity, staleness, fix_type), DeviceGNSSStatus
│   └── Views/      MainView (status + metric cards), CairnMark (logo)
└── Tests/          PayloadTests, ValidityTests, StalenessTests
```

## Non-goals (Phase 1)

OBD gauges, trip history, live dashboard, barometer, heading, UTC sync.
