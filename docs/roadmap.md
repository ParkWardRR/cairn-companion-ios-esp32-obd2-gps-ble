# Roadmap

Checkboxes are the Phase 1 work items from the plan. The iOS app is built and runs against the dongle; the firmware is flashed and running on hardware. Phase 1 stays open until every row of [validation.md](validation.md) passes.

Firmware items are checked only where confirmed on hardware. The [Cairn](https://github.com/ParkWardRR/Cairn) repo is the source of truth for the rest.

## Current focus

Phase 1 is waiting on a device and the firmware repo: background validation, the drive test, and the firmware rows. App-side Phase 2 payloads are built; they stay dormant until the firmware exposes `BARO_ALT` and `UTC_SYNC`. The firmware work list is in [HANDOFF-FIRMWARE.md](../HANDOFF-FIRMWARE.md).

## Phase 0 — Design ✅

- [x] Plan, protocol v1, platform corrections, design review folded in
- [x] Validation matrix

## Phase 1 — GPS reinforcement (MVP)

**Firmware** ([Cairn](https://github.com/ParkWardRR/Cairn), behind `CAIRN_BLE_COMPANION`)

- [ ] `h2zero/NimBLE-Arduino@^2.2.1`, pinned
- [x] `ble_companion.cpp`: GATT server, authenticated characteristics, static passkey (bond survives reboot, no re-pairing)
- [x] `GNSS_FIX` write: validate 28 B; reject stale (> 3 s); invalid / duplicate rejection and `source_flags` b5 per the firmware repo; back-date `monotonic_ms`
- [x] `GNSS_QUALITY`, `COMPANION_STATUS` notify; `PROTOCOL_VERSION` read (status counters reset per connection)
- [ ] Separate `internal_gnss` / `phone_gnss` state; clear phone state on disconnect
- [ ] Dual recording; explicit event-position / trip-speed / health policy
- [ ] `DEGRADED_GNSS` stays internal-receiver health
- [ ] Bond limit 1, bond reset
- [x] Radio handover: BLE stops before WiFi sync after engine off and resumes after; BLE stops before light sleep and resumes on wake
- [ ] `bundle-format-v2.md`: document `source_flags` b5
- [ ] `docs/ble-companion-protocol.md` in the firmware repo
- [ ] Server: key / dedup / trajectory queries safe with two samples per `mono_ms`

**iOS** (this repo)

- [x] SwiftUI + Observation app, iOS 17, app target with app icon and light / dark UI
- [x] `liveUpdates(.automotiveNavigation)`, ~1 Hz transmit filter with throttle tests
- [x] Validity mapping, staleness drop, clamped accuracy
- [x] 28 B `GNSS_FIX` encoder with `sample_age_ms`, `seq`, flags
- [x] CoreBluetooth: scan by service UUID, bond, reconnect, write flow control; bond reuse across dongle reboots confirmed on hardware
- [x] BLE-driven auto-start: location starts when the link is bonded and stops when it drops
- [x] Post-trip handover: dongle-initiated disconnect is not an error; the app reconnects when it re-advertises; sent / dropped counters reset per connection
- [x] `CLBackgroundActivitySession` + `location` / `bluetooth-central` modes in Info.plist
- [ ] Background validation on a device: BLE wake from suspended and from system-terminated, location starts, fixes accepted
- [x] Decode `GNSS_QUALITY` and `COMPANION_STATUS` (layouts still proposed)
- [x] Single screen: auto-connect, phone vs internal, acceptance feedback
- [x] Debug-only demo mode (`CAIRN_DEMO`) for simulator screenshots
- [x] Golden-vector tests: [golden-vectors.json](golden-vectors.json) from an independent spec implementation, replayed by the iOS tests
- [ ] Firmware repo consumes `golden-vectors.json`
- [ ] Drive test: phone vs internal accuracy, battery, write rate

**Exit:** all rows in [validation.md](validation.md) pass.

## Phase 2 — Enrichment

- [x] `BARO_ALT` app side: payload, golden vectors, `CMAltimeter` stream, sent only if the dongle exposes it. Not run against firmware or a device
- [x] `UTC_SYNC` app side: payload, golden vectors, sent on link-ready and every 60 s if exposed. Not run against firmware or a device
- [ ] Firmware: `BARO_ALT` and `UTC_SYNC` characteristics
- [ ] Compass heading (`CLHeading`)
- [ ] `OBD_LIVE`, `DEVICE_STATUS` notify
- [ ] Live dashboard

## Phase 3 — Trips and history

- [ ] Trip history from `cairn-tsdb` over LAN
- [ ] Internal-vs-phone analysis, matched by measurement time
- [ ] Decide on powering down internal GNSS when the phone is connected
