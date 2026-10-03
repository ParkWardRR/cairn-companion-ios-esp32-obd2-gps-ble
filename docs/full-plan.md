---
planStatus:
  planId: plan-cairn-companion-ios
  title: Cairn Companion — iOS app for GPS reinforcement and live telemetry
  status: draft
  planType: feature
  priority: high
  owner: ParkWardRR
  stakeholders: []
  tags:
    - ios
    - ble
    - gps
    - firmware
    - swift
  created: "2026-10-03"
  updated: "2026-10-03T00:00:00.000Z"
  progress: 0
---
# Cairn Companion — iOS App

## Problem

The Cairn dongle's internal GNSS receiver sits under the dashboard near the driver's feet. The OBD-II port gives it power and diagnostic access but terrible sky view. The result is frequent `DEGRADED_GNSS`, slow time-to-fix, poor satellite geometry, and no accuracy estimates at all — `h_acc_cm` and `v_acc_cm` are permanently `0xFFFF` because the receiver simply doesn't report them. An iPhone in a windshield mount or on the dashboard has potentially better positioning with reported accuracy estimates — multi-constellation GNSS, a barometric altimeter, and a magnetometer. Actual accuracy in-vehicle is a validation target, not an assumption.

## Solution

A lightweight iOS app that feeds the ESP32 Core Location estimates over BLE. The phone supplies location data with accuracy metadata that the internal receiver cannot provide. Cairn records internal receiver samples and phone-provided location estimates independently. Operational decisions use an explicit freshness-and-validity policy, while source identity and timing remain available for offline analysis.

---

## Architecture

### Data flow (Phase 1)

```
┌──────────────────────┐       BLE GATT (encrypted)      ┌────────────────────┐
│   iPhone              │ ──── phone → device ───────────▶ │   ESP32 Dongle      │
│                        │                                  │                      │
│  CLLocationUpdate      │  GNSS_FIX (28 bytes, ~1Hz)      │  NimBLE callback     │
│   .liveUpdates         │  validity + age + seq            │   validate, enqueue  │
│   (.automotiveNav)     │                                  │      ↓               │
│                        │                                  │  fact queue          │
│  CLBackgroundActivity  │                                  │  (source_flags 0x20) │
│   Session (locked OK)  │ ◀──── device → phone ────────── │      ↓               │
│                        │  GNSS_QUALITY (8 bytes)          │  lifecycle (core 1)  │
│  GPS comparison +      │  COMPANION_STATUS (8 bytes)      │   ├─ internal_gnss   │
│  acceptance feedback   │   (accepted/rejected/dropped)    │   ├─ phone_gnss      │
│                        │                                  │   └─ both recorded   │
│                        │                                  │      ↓               │
│                        │                                  │  SD card             │
└──────────────────────┘                                  └────────────────────┘
```

### BLE protocol — custom GATT service

A single custom service with typed characteristics rather than a serial stream. Each characteristic carries one message type with a known, fixed layout. No framing overhead, no reassembly, no parser on the ESP32.

**Service UUID:** `A8E3xxxx-4F5B-11EF-A017-325096B39F47` (v1 UUID, registered in `docs/ble-companion-protocol.md`)

Scan by service UUID, not by local name. The advertised name `"Cairn"` is for display only.

#### Phone → Device (write-without-response)

Phase 1:

| Characteristic | UUID suffix | Payload | Target cadence | Description |
| --- | --- | --- | --- | --- |
| `GNSS_FIX` | `0001` | 28 bytes | ~1 Hz | Location estimate with timing, validity, and sequencing |

**`GNSS_FIX` wire layout (28 bytes, little-endian):**

| Offset | Size | Field | Type | Units / sentinel |
| --- | --- | --- | --- | --- |
| 0 | 4 | `lat_e7` | i32 | degrees × 10⁷; 0 when position invalid |
| 4 | 4 | `lon_e7` | i32 | degrees × 10⁷; 0 when position invalid |
| 8 | 4 | `alt_cm` | i32 | cm above WGS-84 ellipsoid; 0x7FFFFFFF when altitude invalid |
| 12 | 2 | `speed_cmps` | u16 | cm/s; `0xFFFF` when speed unavailable (negative CLLocation.speed) |
| 14 | 2 | `heading_cdeg` | u16 | centidegrees course-over-ground; `0xFFFF` when course unavailable (negative CLLocation.course) |
| 16 | 2 | `h_acc_cm` | u16 | horizontal accuracy in cm; `0xFFFF` when invalid (negative horizontalAccuracy). Clamped to 65534 on overflow. |
| 18 | 2 | `v_acc_cm` | u16 | vertical accuracy in cm; `0xFFFF` when invalid (negative verticalAccuracy). Clamped to 65534 on overflow. |
| 20 | 1 | `fix_type` | u8 | Mapped from CLLocation validity (see below) |
| 21 | 1 | `validity_flags` | u8 | bit 0: position valid, bit 1: altitude valid, bit 2: speed valid, bit 3: course valid |
| 22 | 2 | `sample_age_ms` | u16 | Age of the CLLocation measurement at time of BLE write. `age = now - location.timestamp`. Reject on device if > `CAIRN_PHONE_GNSS_STALE_MS`. |
| 24 | 2 | `seq` | u16 | Monotonic sequence number, wrapping. For duplicate detection and acceptance feedback. |
| 26 | 2 | `reserved` | u16 | 0x0000 |

**`fix_type` mapping from CLLocation validity:**

| Condition | fix_type | Notes |
| --- | --- | --- |
| `horizontalAccuracy < 0` | 0 (no fix) | Apple uses negative accuracy to indicate invalid |
| `horizontalAccuracy >= 0`, `verticalAccuracy < 0` | 1 (2D) | Valid position, no valid altitude |
| `horizontalAccuracy >= 0`, `verticalAccuracy >= 0` | 2 (3D) | Valid position and altitude |

The phone does not report fix types beyond 3D (no DGPS/RTK distinction from Core Location).

**Staleness policy:** The app must not send cached or stale locations. Before encoding, check `abs(Date.now - location.timestamp)` and discard samples older than 2 seconds. The firmware applies a second staleness gate (`CAIRN_PHONE_GNSS_STALE_MS`, default 3000 ms) to reject late arrivals.

Phase 2 (future):

| Characteristic | UUID suffix | Payload | Target cadence | Description |
| --- | --- | --- | --- | --- |
| `BARO_ALT` | `0002` | 4 bytes | ~1 Hz | relative_altitude_cm (i32, from CMAltimeter) |
| `UTC_SYNC` | `0003` | 8 bytes | on connect + 1/min | unix_ms (u64, phone wall clock) |

#### Device → Phone (notify)

Phase 1:

| Characteristic | UUID suffix | Payload | Rate | Description |
| --- | --- | --- | --- | --- |
| `GNSS_QUALITY` | `0010` | 8 bytes | 1 Hz | Internal receiver: fix_type, sats_used, hdop_e2, fix_age_ms |
| `COMPANION_STATUS` | `0011` | 8 bytes | 1 Hz | Acceptance feedback: last_accepted_seq, accepted_count, rejected_count, queue_drop_count |

Phase 2 (future):

| Characteristic | UUID suffix | Payload | Rate | Description |
| --- | --- | --- | --- | --- |
| `OBD_LIVE` | `0020` | 48 bytes | ~1 Hz | OBD snapshot + extended, combined |
| `DEVICE_STATUS` | `0021` | 12 bytes | 1 Hz | trip state, health bitmap, battery_mv |

#### Read-only characteristics

| Characteristic | UUID suffix | Description |
| --- | --- | --- |
| `PROTOCOL_VERSION` | `00F0` | u8 protocol version + u8 firmware capabilities bitmap. Allows the app to detect incompatible firmware. |

All payloads are little-endian, matching the bundle format. No CBOR, no JSON, no strings on the wire. All characteristics require authenticated/encrypted access (NimBLE `BLE_GATT_CHR_F_READ_ENC` / `_WRITE_ENC`).

#### Write flow control

Use `canSendWriteWithoutResponse` and the `peripheralIsReady(toSendWriteWithoutResponse:)` callback. Do not assume every scheduled write can immediately enter CoreBluetooth's transmit queue. Verify the peripheral's `maximumWriteValueLength(for: .withoutResponse)` is >= 28 bytes at connection time.

### Why GATT characteristics, not a serial-style BLE service

The vendor library includes a BLE serial service (UART-over-GATT), but typed characteristics are better here:

- A serial service requires framing, length prefixes, and reassembly — complexity on a 4 KB stack task
- GATT characteristics provide message boundaries, MTU negotiation, and subscribe/unsubscribe
- Each characteristic maps to exactly one message type — the ESP32 code validates length and enqueues, no parsing
- The payload decoder on both sides still performs length, range, and sentinel validation — GATT provides boundaries, not semantic type safety

Note: BLE serial services (like the vendor's UART profile) use CoreBluetooth/GATT like any other BLE service. The choice here is about message framing, not about API availability.

### BLE security

**Pairing:** Static passkey authentication. A 6-digit PIN is compiled into the firmware via `secrets.h`. The phone prompts for the PIN on first connection and bonds — subsequent connections are automatic.

```c
/* In secrets.h (gitignored): */
#define CAIRN_BLE_PASSKEY <six-digit-PIN>
```

**Characteristic protection:** All read/write/notify characteristics require an authenticated, encrypted connection (NimBLE `BLE_GATT_CHR_F_READ_ENC | BLE_GATT_CHR_F_READ_AUTHEN` and equivalent for writes). An unbonded phone can discover the service but cannot read, write, or subscribe. This must be verified: NimBLE can fall back to Just Works pairing depending on I/O capabilities, which would bypass the passkey. Test that an unbonded phone without the PIN cannot inject location facts.

**Enrollment and bond management:**
- Bond limit: 1 (single phone at a time). A second phone bonding replaces the first.
- Bond reset: Hold a button during boot (or a firmware command) to clear all bonds and force re-pairing.
- On disconnect: clear all inbound phone state (last fix, sequence counter, acceptance counts). Do not replay stale data on reconnect.
- On reconnect: the phone re-establishes subscriptions and resumes from its own sequence counter. The device accepts the new sequence without requiring continuity from the previous session.

### Why NimBLE, not Bluedroid

The ESP-IDF ships two BLE stacks. NimBLE is the right choice:

- ~60 KB flash + ~10 KB RAM vs Bluedroid's ~200 KB flash + ~60 KB RAM
- NimBLE's GATT server API is cleaner for a small number of characteristics
- PlatformIO: `lib_deps = h2zero/NimBLE-Arduino@^2.2.1` (pin a tested release)

**Stack and callback separation:** NimBLE runs its own host task. GATT write callbacks execute on NimBLE's task stack, not the application BLE worker. Callbacks must be bounded: validate payload length, copy 28 bytes, perform a nonblocking `xQueueSend`, and count failures. No allocations, no blocking, no SD I/O in callbacks.

The application BLE worker (which feeds `GNSS_QUALITY` notifications to the phone) runs on core 1 alongside the lifecycle controller. NimBLE's host task is left on its default core assignment. Validate that NimBLE's host stack depth is sufficient under sustained write-without-response traffic — measure `uxTaskGetStackHighWaterMark` under load, not just at boot.

---

## Firmware Changes

### New: BLE companion module (`src/ble_companion.cpp`)

Two execution contexts, not a standalone task:

1. **NimBLE callbacks** (run on NimBLE's host task): GATT write handler validates the 28-byte `GNSS_FIX` payload, applies staleness and validity checks, converts to `cairn_gnss_sample_t` with `source_flags` bit 5, and posts to the existing fact queue via nonblocking `xQueueSend`. On failure, increments a rejection or drop counter. Bounded: validate, copy, enqueue, return.

2. **Outbound notification loop** (on core 1, called from the lifecycle tick or a small helper task): Pushes `GNSS_QUALITY` and `COMPANION_STATUS` to the phone at 1 Hz via GATT notify. Fed from the lifecycle controller's internal/phone state.

Phase 1 responsibilities:
1. Advertise the Cairn GATT service (by service UUID), stop on connect, resume on disconnect
2. Enforce authenticated/encrypted pairing with static passkey
3. Accept `GNSS_FIX` writes — reject if: payload != 28 bytes, `sample_age_ms` > `CAIRN_PHONE_GNSS_STALE_MS`, `validity_flags` bit 0 clear (position invalid), or duplicate `seq`
4. Convert accepted fixes: map phone fields into `cairn_gnss_sample_t`, set `source_flags |= 0x20`, post as `FACT_GNSS_SAMPLE`
5. Notify `GNSS_QUALITY` — internal receiver state
6. Notify `COMPANION_STATUS` — last_accepted_seq, accepted/rejected/dropped counts
7. On disconnect: clear phone GNSS state in the lifecycle controller, reset acceptance counters

**Timestamp mapping:** The phone's `sample_age_ms` is used to backdate the fact's `monotonic_ms`: `fact.monotonic_ms = millis() - sample_age_ms`. This places the phone sample at approximately the right point in the monotonic timeline, rather than at BLE receipt time. The approximation error is bounded by BLE latency (~10–30 ms) plus the phone's own measurement-to-send delay.

Stack budget: NimBLE callbacks use NimBLE's host stack. The outbound notification loop needs ~2 KB if separated, or can run inline in the lifecycle tick (no additional stack). Measure `uxTaskGetStackHighWaterMark` on NimBLE's host task under sustained 1 Hz write traffic.

### Modified: `source_flags` encoding

The spec defines bits 0–4 of `source_flags`:

| Bit | Meaning |
| --- | --- |
| 0 | GPS |
| 1 | GLONASS |
| 2 | Galileo |
| 3 | BeiDou |
| 4 | Dead-reckoned |

Bits 5–7 are free. The proposal:

| Bit | Meaning |
| --- | --- |
| 5 | External source (phone-provided) |
| 6 | Reserved |
| 7 | Reserved |

When the BLE task posts a phone-sourced GNSS fact, it sets bit 5. The lifecycle controller and the server decode pipeline can then distinguish internal vs phone-sourced fixes. The recorded data is honestly labeled.

### Modified: Dual GPS recording with source-aware lifecycle state

The lifecycle controller already consumes `FACT_GNSS_SAMPLE` from the queue. The changes are structural: two independent source states, both recorded, with an explicit policy for operational decisions.

#### Independent source state

The lifecycle controller maintains separate tracking for each source:

```c
typedef struct {
    cairn_gnss_sample_t last_sample;
    uint32_t            last_mono_ms;    /* when this source last delivered */
    bool                position_valid;  /* validity_flags bit 0 (phone) or fix_type > 0 (internal) */
    bool                speed_valid;     /* validity_flags bit 2 (phone) or speed != sentinel (internal) */
    bool                altitude_valid;  /* validity_flags bit 1 (phone) or fix_type >= 2 (internal) */
    bool                connected;       /* always true for internal; BLE session active for phone */
    uint16_t            last_seq;        /* phone only: for duplicate detection */
} gnss_source_state_t;

gnss_source_state_t internal_gnss;
gnss_source_state_t phone_gnss;
```

On BLE disconnect, `phone_gnss` is cleared entirely — no stale phone state persists.

#### Recording policy

**Both sources are always recorded.** When the phone provides a fix in the same tick as the internal receiver, both samples are written to the bundle as separate `GNSS_SAMPLE` frames with different `source_flags`. This lets offline tools compare accuracy, availability, and agreement.

#### Operational selection policy

Recording both is source-neutral. But choosing event positions, health state, and trip speed is a selection policy. Define it explicitly:

| Decision | Rule |
| --- | --- |
| **Event position** (`last_gnss` for trip events) | Prefer the freshest source with `position_valid` and `sample_age < CAIRN_GNSS_STALE_MS`. Between two fresh valid sources, prefer phone (it has accuracy metadata). |
| **Trip speed** (for start/stop scoring) | Use whichever source has `speed_valid` and is freshest. Valid position does not imply valid speed — CLLocation reports `speed < 0` when unavailable. |
| **`DEGRADED_GNSS` health bit** | Split semantics: this bit means *internal receiver degradation*, not "no positioning available." It reflects the hardware state of the internal receiver regardless of whether the phone is compensating. A separate "positioning unavailable" condition (no valid source of any kind) is reported in the overall health bitmap but does not mask the internal receiver's status. |
| **`have_recent_gnss`** (lifecycle freshness) | True when *any* source has delivered a valid, fresh fix. Used for determining whether position is available for event tagging. |
| **Staleness threshold** | `CAIRN_PHONE_GNSS_STALE_MS = 3000` (same as internal). A phone fix older than this is not used for operational decisions, even if recorded. |
| **Hysteresis** | Do not toggle `DEGRADED_GNSS` on every sample. Require sustained absence (same dwell as internal: 3 seconds of no valid fix from the internal receiver). |

### Modified: `config.h`

```c
/* BLE companion. Disabled by default; enabled in secrets.h or build flags. */
#ifndef CAIRN_BLE_COMPANION
#define CAIRN_BLE_COMPANION 0
#endif

/* The advertised device name (display only; scan by service UUID). */
#ifndef CAIRN_BLE_NAME
#define CAIRN_BLE_NAME "Cairn"
#endif

/* Maximum age of a phone GNSS sample before the firmware rejects it. */
#define CAIRN_PHONE_GNSS_STALE_MS 3000

/* In secrets.h (gitignored):
 * #define CAIRN_BLE_COMPANION 1
 * #define CAIRN_BLE_PASSKEY <six-digit-PIN>
 */
```

### Impact on bundle format

**No structural changes.** Every field the phone populates already exists in `cairn_gnss_sample_t`. The phone fills in fields that the internal receiver leaves as sentinels:

- `h_acc_cm` — from `CLLocation.horizontalAccuracy` (meters × 100 → cm). Clamped to 65534; `0xFFFF` when `horizontalAccuracy < 0` (invalid).
- `v_acc_cm` — from `CLLocation.verticalAccuracy` (meters × 100 → cm). Clamped to 65534; `0xFFFF` when `verticalAccuracy < 0` (invalid altitude).
- `source_flags` bit 5 — marks the fix as phone-sourced
- `fix_type` — mapped from CLLocation validity (see wire layout above), not assumed to be 3D
- `sats_used` — `0xFF` (Core Location doesn't expose satellite count; sentinel is honest)
- `sats_visible` — `0xFF` (same)
- `hdop_e2` — `0xFFFF` (Core Location doesn't report DOP; `h_acc_cm` is the accuracy measure)

With dual recording, a bundle contains interleaved `GNSS_SAMPLE` frames from both sources, distinguished by `source_flags` bit 5:

```sql
-- cairn-tsdb query: phone vs internal GPS comparison
SELECT mono_ms, lat_e7, lon_e7, h_acc_cm, source_flags,
       CASE WHEN source_flags & 32 != 0 THEN 'phone' ELSE 'internal' END as source
FROM position
WHERE boot_id = ?
ORDER BY mono_ms;
```

**Storage compatibility:** Two sources can produce frames at the same `mono_ms`. The database must handle this:

- PostgreSQL `norm.position_samples`: ensure the primary/unique key includes `source_flags` (or at minimum does not deduplicate on `(boot_id, mono_ms)` alone)
- DuckDB `cairn-tsdb`: the `position` table must accept both rows without overwrite
- Existing trajectory queries (e.g. `v_telemetry` ASOF join) must be tested with interleaved sources to confirm they don't zigzag between internal and phone positions

The three format implementations (C, Go, Rust) need no changes. `bundle-format-v2.md` needs a one-line addition documenting bit 5 of `source_flags`. The bundle Merkle tree, signatures, and sync protocol are unaffected.

---

## iOS App Design

### Technology

- **Swift + SwiftUI + Observation + async/await** — modern Swift concurrency throughout, `@Observable` models instead of Combine/ObservableObject, structured concurrency for BLE and location streams
- **CoreBluetooth** — GATT client, scan/connect/subscribe. App implements reconnection logic and state restoration (`willRestoreState`). Restoration/relaunch depends on pending Bluetooth operations and system conditions — not a blanket guarantee.
- **CoreLocation** — `CLLocationUpdate.liveUpdates(.automotiveNavigation)` async stream (iOS 17+). This delivers an async sequence of updates; the cadence is system-managed, not a fixed-rate contract. The app filters and transmits at a target cadence of ~1 Hz.
- **CoreMotion / CMAltimeter** — barometric altitude (Phase 2, relative, not MSL)
- **Minimum iOS 17** — required for Observation framework, `CLLocationUpdate.liveUpdates`, and `CLBackgroundActivitySession`

### Screens

#### 1. Main screen — driving session

- **Start/Stop session** button — explicit user action to begin and end GPS streaming
- Scan and connect to Cairn device (passkey entry on first bond)
- Connection state: scanning / connecting / bonded / streaming
- **Phone location:** accuracy (m), fix age, speed, validity status
- **Device GPS:** fix_type, sats_used, HDOP (from `GNSS_QUALITY` notifications)
- **Acceptance status:** last accepted seq, accepted/rejected/dropped counts (from `COMPANION_STATUS` notifications). "Streaming" means "device recently acknowledged acceptance," not merely "phone called write."

Note: Core Location does not expose satellite count or constellation. Those fields are not shown; the app displays accuracy and validity instead.

That's it for Phase 1. No OBD, no dashboard, no trip history.

### Background behavior — locked-screen driving sessions

A windshield mount doesn't keep the app foregrounded. Locking the screen or switching to a navigation app is an ordinary driving workflow. Phase 1 supports this:

- **`CLBackgroundActivitySession`** — the app starts a background activity session when the user taps "Start." This maintains location access when the screen locks or the user switches apps, using While In Use authorization (no Always authorization required for an explicitly started session).
- **`location` background mode** — enabled in `Info.plist`. Required for `CLBackgroundActivitySession`.
- **`bluetooth-central` background mode** — enabled in `Info.plist`. Maintains the BLE connection and allows write operations while backgrounded.
- **Session lifecycle:** Start → location + BLE active in foreground and background → Stop (user taps Stop, or the app is terminated). The Live Activity or persistent notification shows the session is active.
- **CoreBluetooth state restoration** — `CBCentralManager` initialized with `CBCentralManagerOptionRestoreIdentifierKey` so the system can relaunch the app if the BLE connection drops and the peripheral reappears.

This is a reliability requirement for the driving use case, not scope expansion.

### Repository

Separate repository (not in the Cairn monorepo). The BLE protocol contract is documented in this plan and in a shared `ble-protocol.md` spec that both repos reference.

### Project structure

```
CairnCompanion/
├── CairnCompanion.xcodeproj
├── Sources/
│   ├── App/
│   │   └── CairnCompanionApp.swift
│   ├── BLE/
│   │   ├── CairnBLEManager.swift       — scan, connect, bond, reconnect, state restoration
│   │   ├── CairnGATTProfile.swift       — service/characteristic UUIDs, wire constants
│   │   ├── PayloadEncoder.swift         — CLLocation → 28-byte GNSS_FIX with validity/staleness
│   │   └── PayloadDecoder.swift         — decode GNSS_QUALITY and COMPANION_STATUS notifications
│   ├── Location/
│   │   ├── LocationStream.swift         — CLLocationUpdate.liveUpdates(.automotiveNavigation) async stream
│   │   └── BaroStream.swift             — CMAltimeter stream (Phase 2)
│   ├── Session/
│   │   ├── DrivingSession.swift         — start/stop, CLBackgroundActivitySession lifecycle
│   │   └── SessionState.swift           — @Observable session + connection + acceptance state
│   ├── Models/
│   │   ├── PhoneGNSSFix.swift           — CLLocation validity mapping, staleness check, fix_type derivation
│   │   └── DeviceGNSSStatus.swift       — parsed internal receiver state
│   └── Views/
│       ├── MainView.swift               — session control + GPS status
│       └── GPSComparisonView.swift      — side-by-side phone vs internal
└── Tests/
    ├── PayloadTests.swift               — round-trip encode/decode, sentinel preservation
    ├── ValidityTests.swift              — CLLocation edge cases: negative accuracy, stale, overflow
    └── StalenessTests.swift             — sample age filtering
```

---

## Phased Rollout

### Phase 1: GPS reinforcement (MVP)

The phone supplies location estimates to the dongle. Both sources are recorded. The app supports locked-screen driving sessions.

**Firmware:**
- [ ] Add `h2zero/NimBLE-Arduino@^2.2.1` to platformio.ini, pin version
- [ ] Implement `ble_companion.cpp` — GATT server, service UUID, authenticated characteristics
- [ ] Static passkey pairing with `BLE_GATT_CHR_F_WRITE_ENC | _AUTHEN` on all characteristics
- [ ] `GNSS_FIX` write characteristic — validate 28 bytes, reject stale/invalid/duplicate, post to fact queue with `source_flags` bit 5
- [ ] Timestamp mapping: `fact.monotonic_ms = millis() - sample_age_ms`
- [ ] `GNSS_QUALITY` notify characteristic — internal receiver state (8 bytes, 1 Hz)
- [ ] `COMPANION_STATUS` notify characteristic — last_accepted_seq, accepted/rejected/dropped counts (8 bytes, 1 Hz)
- [ ] `PROTOCOL_VERSION` read characteristic — protocol version + capabilities
- [ ] Separate `internal_gnss` and `phone_gnss` source state in lifecycle
- [ ] Dual recording — write both sources as separate `GNSS_SAMPLE` frames
- [ ] Explicit operational selection policy for event position, trip speed, health
- [ ] `DEGRADED_GNSS` means internal receiver degradation (not masked by phone)
- [ ] `have_recent_gnss` reflects any valid source (for event positioning)
- [ ] Clear phone state on BLE disconnect
- [ ] Bond limit = 1, bond reset procedure
- [ ] `CAIRN_BLE_COMPANION` build flag (default off), `CAIRN_BLE_PASSKEY` and `CAIRN_PHONE_GNSS_STALE_MS` in config
- [ ] Update `bundle-format-v2.md`: document `source_flags` bit 5
- [ ] Write `docs/ble-companion-protocol.md`: full wire layouts, UUIDs, staleness rules, validity semantics

**iOS (separate repo):**
- [ ] Scaffold SwiftUI + Observation + async/await app, minimum iOS 17
- [ ] `CLLocationUpdate.liveUpdates(.automotiveNavigation)` async stream, filtered to ~1 Hz target cadence
- [ ] CLLocation validity mapping: negative accuracy → invalid, negative speed/course → sentinel, staleness check (discard > 2s)
- [ ] Encode CLLocation → 28-byte GNSS_FIX with sample_age_ms, seq, validity_flags, proper fix_type
- [ ] Numeric overflow handling: h_acc_cm / v_acc_cm clamped to 65534, not wrapped
- [ ] CoreBluetooth manager — scan by service UUID, bond with passkey, state restoration
- [ ] Write flow control: `canSendWriteWithoutResponse`, `peripheralIsReady(toSendWriteWithoutResponse:)`, check `maximumWriteValueLength`
- [ ] Decode `GNSS_QUALITY` and `COMPANION_STATUS` notifications
- [ ] `CLBackgroundActivitySession` — driving session continues when screen locks or user switches apps
- [ ] `location` + `bluetooth-central` background modes in `Info.plist`
- [ ] Start/Stop session UI with clear lifecycle
- [ ] Single screen: session control + GPS comparison + acceptance feedback

**Validation:**

| Test | Acceptance criterion |
| --- | --- |
| Bench: BLE connect + passkey | Phone bonds, characteristics accessible only after authentication |
| Bench: unbonded phone | Cannot read, write, or subscribe to any characteristic |
| Bench: facts reach queue | Phone fix appears as `FACT_GNSS_SAMPLE` with `source_flags & 0x20` |
| Bench: timestamp mapping | `monotonic_ms` reflects measurement time, not BLE receipt time |
| Bench: stale sample rejection | Samples with `sample_age_ms > CAIRN_PHONE_GNSS_STALE_MS` are rejected; rejection count increments |
| Bench: invalid sample handling | CLLocation with negative accuracy → fix_type 0, validity_flags bit 0 clear → firmware rejects |
| Bench: accuracy overflow | `horizontalAccuracy = 700m` → `h_acc_cm = 65534` (clamped), not wrapped to a small value |
| Bench: duplicate detection | Same `seq` → rejected, not double-recorded |
| Drive: phone on windshield | Both sources recorded; phone fixes have valid h_acc_cm; internal fixes have sentinel |
| Drive: source separation | `source_flags & 32` correctly splits phone vs internal in decoded bundle |
| Drive: screen lock | Session continues streaming after locking screen; BLE stays connected |
| Drive: switch to Maps | Session continues streaming while another app is foregrounded |
| Drive: phone disconnect | Internal GNSS unaffected; phone_gnss state cleared; acceptance counters reset |
| Drive: phone reconnect | Resumes cleanly; no replay of old fixes; new seq accepted |
| DB: two sources at same mono_ms | Both survive ingestion without overwrite or deduplication |
| DB: trajectory query | `v_telemetry` / existing queries don't zigzag between sources |
| DB: source_flags in tsdb | DuckDB position table stores and queries nonzero source_flags correctly |
| Golden vectors | Swift 28-byte encoding and C decoding agree on every byte, including sentinels and negative values |
| Stack/RAM: NimBLE under load | `uxTaskGetStackHighWaterMark` on NimBLE host task under sustained 1 Hz writes; internal heap free measured |
| Stack/RAM: sensor task unaffected | IMU 50 Hz sampling deadlines met with BLE active |
| Coexistence: BLE + Wi-Fi | Connect phone, then sync over Wi-Fi while parked; both succeed |
| Coexistence: BLE + SD writes | No fact queue drops attributable to BLE during active recording |
| Bond: deletion on phone | Device detects unbonded state; re-pairing with passkey succeeds |
| Bond: deletion on device | Phone detects failed connection; re-bonds on next attempt |
| Standby: phone connected | Phone BLE presence alone does not hold the device awake indefinitely |

### Phase 2: Enrichment (future)

- [ ] Barometric altitude characteristic (CMAltimeter → ESP32)
- [ ] UTC sync characteristic (phone NTP clock → device)
- [ ] Heading characteristic (CLHeading → device)
- [ ] Device→phone: OBD + trip state notifications
- [ ] Live dashboard screen on iOS

### Phase 3: Trips and history (future)

- [ ] Trip history on iOS — query cairn-tsdb over LAN when on home Wi-Fi
- [ ] GPS accuracy analysis tools — compare internal vs phone fixes from recorded bundles
- [ ] Decide whether to power down internal GNSS when phone is connected

---

## Open Questions

1. **NimBLE host task core and stack** — NimBLE's host task runs on its default core (typically core 0). GATT write callbacks execute on that task's stack. Need to measure whether NimBLE's default stack depth (4 KB) is sufficient for the validate-copy-enqueue callback path under sustained traffic, or whether it needs to be increased. The application outbound loop runs on core 1 alongside lifecycle, which is the simpler concern.

2. **Phone location cadence** — `CLLocationUpdate.liveUpdates(.automotiveNavigation)` delivers updates at a system-managed rate, not a fixed 1 Hz. The app filters to a target of ~1 Hz transmission. If the system delivers faster, discard extras; if slower, the device tolerates gaps (same as the internal receiver's variable fix rate).

3. **Advertising strategy** — Advertise when no phone is connected; stop on connect, resume on disconnect. ~1 mA, negligible on OBD 12V power. The phone scans by service UUID and reconnects when it sees the advertisement.

4. **Internal GNSS during standby** — Currently powered down when parked. When the phone reconnects to a waking device, the phone fix arrives before the internal receiver reacquires — faster effective time-to-first-fix.

5. **Coordinate datum** — CLLocation coordinates are WGS-84, matching the bundle format's `lat_e7`/`lon_e7` specification. CLLocation altitude is relative to the WGS-84 ellipsoid (not MSL). Both are consistent with the internal receiver. Document this explicitly in the protocol spec.

6. **Heading semantics** — `heading_cdeg` in the wire format means course-over-ground (from `CLLocation.course`), not magnetic compass heading. The internal receiver also reports COG. Document this distinction; compass heading (`CLHeading`) is a Phase 2 enrichment.

---

## Risk Assessment

| Risk | Mitigation |
| --- | --- |
| BLE + Wi-Fi contention on ESP32 radio | ESP-IDF coexistence controller handles arbitration. Sync happens only while parked (BLE idle or disconnected), so they rarely compete. Validate with the coexistence test. |
| NimBLE RAM pressure | NimBLE needs ~10 KB. ESP32-WROVER has 520 KB SRAM + 4 MB PSRAM. Validation target: measure free internal heap under sustained BLE + recording + Wi-Fi. |
| NimBLE stack depth | GATT write callbacks run on NimBLE's host task stack. The callback is bounded (validate, copy, enqueue), but measure `uxTaskGetStackHighWaterMark` under load, not at boot. |
| Dual GNSS write rate | Two 32-byte GNSS samples per second adds ~32 bytes/s additional payload before framing overhead. Validate actual byte-rate increase on a real drive. 16 GB card has years of headroom. |
| Phone location drains battery | `.automotiveNavigation` configuration uses ~5% per hour. Acceptable — phone is typically charging in the car. Measure on a real drive. |
| BLE disconnects during drive | App reconnects via CoreBluetooth state restoration. Firmware clears phone state and continues internal GNSS. No gap in recording, just no phone-sourced samples until reconnect. |
| Cached CLLocation on reconnect | A stale CLLocation can arrive immediately after reconnect. The staleness check (`sample_age_ms` > threshold) prevents it from entering operational state or clearing `DEGRADED_GNSS`. |
| NimBLE passkey fallback to Just Works | NimBLE can fall back depending on I/O capability configuration. Validate that an unbonded phone without the PIN cannot inject facts. Enforce characteristic-level encryption + authentication. |
| Format compatibility | No structural format changes. `source_flags` bit 5 is additive. Existing decoders already read the field. Test that database keys and trajectory queries handle two samples at the same `mono_ms`. |
| Separate repo drift | BLE protocol spec lives in `docs/ble-companion-protocol.md` in the Cairn repo. Protocol changes require updating both repos. Golden encoding vectors are shared as test fixtures. |
| Phone accuracy not validated | "Potentially better positioning" is a hypothesis. The dual-recording design exists specifically to collect the evidence. Do not assume phone superiority until drives confirm it. |
