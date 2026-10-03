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

- **Start / Stop** driving session (explicit user action)
- Connection state: scanning → connecting → bonded → streaming
- Phone location: accuracy (m), fix age, speed, validity
- Device GNSS (from `GNSS_QUALITY`): fix type, sats used, HDOP
- Acceptance (from `COMPANION_STATUS`): last seq, accepted / rejected / dropped

Not shown: satellite count or constellation. Core Location does not expose them.

## Background driving session

A windshield mount does not keep the app foregrounded. Locking the screen or opening Maps is normal.

- Start taps create a `CLBackgroundActivitySession`; While In Use authorization is enough for an explicitly started session.
- `CBCentralManager` uses `CBCentralManagerOptionRestoreIdentifierKey`. Restoration and relaunch depend on pending BLE operations and system conditions; the app does its own reconnect logic and does not assume the system will.
- Stop ends location and BLE activity. A Live Activity or persistent indicator shows the session is running.

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
│   └── Views/      MainView, GPSComparisonView
└── Tests/          PayloadTests, ValidityTests, StalenessTests
```

## Non-goals (Phase 1)

OBD gauges, trip history, live dashboard, barometer, heading, UTC sync.
