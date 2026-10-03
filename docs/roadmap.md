# Roadmap

Checkboxes are the Phase 1 work items from the plan. Nothing is built yet.

## Phase 0 — Design ✅

- [x] Plan, protocol v1, platform corrections, design review folded in
- [x] Validation matrix

## Phase 1 — GPS reinforcement (MVP)

**Firmware** ([Cairn](https://github.com/ParkWardRR/Cairn), behind `CAIRN_BLE_COMPANION`)

- [ ] `h2zero/NimBLE-Arduino@^2.2.1`, pinned
- [ ] `ble_companion.cpp`: GATT server, authenticated characteristics, static passkey
- [ ] `GNSS_FIX` write: validate 28 B; reject stale / invalid / duplicate; `source_flags` b5; back-date `monotonic_ms`
- [ ] `GNSS_QUALITY`, `COMPANION_STATUS` notify; `PROTOCOL_VERSION` read
- [ ] Separate `internal_gnss` / `phone_gnss` state; clear phone state on disconnect
- [ ] Dual recording; explicit event-position / trip-speed / health policy
- [ ] `DEGRADED_GNSS` stays internal-receiver health
- [ ] Bond limit 1, bond reset
- [ ] `bundle-format-v2.md`: document `source_flags` b5
- [ ] `docs/ble-companion-protocol.md` in the firmware repo
- [ ] Server: key / dedup / trajectory queries safe with two samples per `mono_ms`

**iOS** (this repo)

- [ ] SwiftUI + Observation app, iOS 17
- [ ] `liveUpdates(.automotiveNavigation)`, ~1 Hz transmit filter
- [ ] Validity mapping, 2 s staleness drop, clamped accuracy
- [ ] 28 B `GNSS_FIX` encoder with `sample_age_ms`, `seq`, flags
- [ ] CoreBluetooth: scan by service UUID, bond, state restoration, write flow control
- [ ] `CLBackgroundActivitySession` + `location` / `bluetooth-central` modes
- [ ] Decode `GNSS_QUALITY` and `COMPANION_STATUS`
- [ ] Single screen: session control, phone vs internal, acceptance feedback
- [ ] Golden-vector tests shared with firmware

**Exit:** all rows in [validation.md](validation.md) pass.

## Phase 2 — Enrichment

- [ ] `BARO_ALT` (CMAltimeter, relative)
- [ ] `UTC_SYNC` (phone wall clock)
- [ ] Compass heading (`CLHeading`)
- [ ] `OBD_LIVE`, `DEVICE_STATUS` notify
- [ ] Live dashboard

## Phase 3 — Trips and history

- [ ] Trip history from `cairn-tsdb` over LAN
- [ ] Internal-vs-phone analysis, matched by measurement time
- [ ] Decide on powering down internal GNSS when the phone is connected
