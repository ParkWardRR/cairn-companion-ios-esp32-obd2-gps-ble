# Roadmap

Checkboxes are the Phase 1 work items from the plan. The iOS app is built and runs against the dongle; the firmware is flashed and running on hardware. Phase 1 stays open until every row of [validation.md](validation.md) passes.

Firmware items are checked only where the firmware repo reports them done ([HANDOFF-FIRMWARE.md](../HANDOFF-FIRMWARE.md), response of 2026-10-03). Rows marked *host-tested* are covered by firmware host tests or docs, not yet by a drive. The [Cairn](https://github.com/ParkWardRR/Cairn) repo is the source of truth for the rest.

## Current focus

The Phase 1 firmware rows are done on the firmware side. What remains is on-device validation: background wake from suspended and terminated, the drive test, and the firmware resource rows (stack, heap, IMU deadlines under BLE + SD + WiFi), all of which need a drive.

On the app side, the link-health UI and the History tab are built, ahead of the original Phase 3 plan. Phase 2 `BARO_ALT` and `UTC_SYNC` stay dormant until the firmware exposes them. `OBD_LIVE` and `DEVICE_STATUS` are decoded and shown when present. Open work is listed in [HANDOFF-FIRMWARE.md](../HANDOFF-FIRMWARE.md) and [plan-link-health-and-history.md](plan-link-health-and-history.md).

## Phase 0 — Design ✅

- [x] Plan, protocol v1, platform corrections, design review folded in
- [x] Validation matrix

## Phase 1 — GPS reinforcement (MVP)

**Firmware** ([cairn-esp32-device-firmware](https://github.com/ParkWardRR/cairn-esp32-device-firmware), behind `CAIRN_BLE_COMPANION`)

- [x] `h2zero/NimBLE-Arduino@^2.2.1`, pinned
- [x] `ble_companion.cpp`: GATT server, authenticated characteristics, static passkey (bond survives reboot, no re-pairing)
- [x] `GNSS_FIX` write: validate 28 B; reject stale (> 3 s); invalid / duplicate rejection and `source_flags` b5 per the firmware repo; back-date `monotonic_ms`
- [x] `GNSS_QUALITY`, `COMPANION_STATUS` notify; `PROTOCOL_VERSION` read (status counters reset per connection)
- [x] Separate `internal_gnss` / `phone_gnss` state; clear phone state on disconnect (*host-tested*)
- [x] Dual recording; explicit event-position / trip-speed / health policy (internal-only joins in the DuckDB views, phone rows split by `source_flags` b5; *host-tested*)
- [x] `DEGRADED_GNSS` stays internal-receiver health
- [x] Bond limit 1, bond reset (`ble_companion_clear_bonds()`; no hardware button to trigger it at boot)
- [x] Radio handover: BLE stops before WiFi sync after engine off and resumes after; BLE stops before light sleep and resumes on wake
- [x] `bundle-format-v2.md`: document `source_flags` b5
- [x] `docs/ble-companion-protocol.md` in the firmware repo
- [x] Server: key / dedup / trajectory queries safe with two samples per `mono_ms` (PostgreSQL key is `(observed_at, content_root, seq)`; new `v_gnss_sources` view)

**iOS** (this repo)

- [x] SwiftUI + Observation app, iOS 18, app target with app icon and light / dark UI
- [x] `liveUpdates(.automotiveNavigation)`, ~1 Hz transmit filter with throttle tests
- [x] Validity mapping, staleness drop, clamped accuracy
- [x] 28 B `GNSS_FIX` encoder with `sample_age_ms`, `seq`, flags
- [x] CoreBluetooth: scan by service UUID, bond, reconnect, write flow control; bond reuse across dongle reboots confirmed on hardware
- [x] BLE-driven auto-start: location starts when the link is bonded and stops when it drops
- [x] Post-trip handover: dongle-initiated disconnect is not an error; the app reconnects when it re-advertises; sent / dropped counters reset per connection
- [x] `CLBackgroundActivitySession` + `location` / `bluetooth-central` modes in Info.plist
- [ ] Background validation on a device: BLE wake from suspended and from system-terminated, location starts, fixes accepted
- [x] Decode `GNSS_QUALITY` and `COMPANION_STATUS` (layouts frozen by the firmware side)
- [x] Live screen: auto-connect, phone vs internal, acceptance feedback
- [x] Link health: per-channel "last heard" freshness badges, last-known readings kept dimmed after a drop, reconnect countdown with attempt count, link timeline strip, sent-vs-accepted ack bar, heartbeat ring
- [x] Connection guide, stale-pairing detection, and a "forget dongle" flow
- [x] Persistent on-device `cairn-drive.log` (shareable from the Files app) and BLE diagnostics tracing
- [x] Debug-only demo mode (`CAIRN_DEMO`) for simulator screenshots, including dropped, silent, and stale-pairing states
- [x] Golden-vector tests: [golden-vectors.json](golden-vectors.json) from an independent spec implementation, replayed by the iOS tests
- [x] Firmware repo consumes `golden-vectors.json` (6/6 pass in `test/host/ble_vectors.c`)
- [ ] Drive test: phone vs internal accuracy, battery, write rate

**Exit:** all rows in [validation.md](validation.md) pass.

## Phase 2 — Enrichment

- [x] `BARO_ALT` app side: payload, golden vectors, `CMAltimeter` stream, sent only if the dongle exposes it. Not run against firmware or a device
- [x] `UTC_SYNC` app side: payload, golden vectors, sent on link-ready and every 60 s if exposed. Not run against firmware or a device
- [ ] Firmware: `BARO_ALT` and `UTC_SYNC` characteristics (not started)
- [ ] Compass heading (`CLHeading`)
- [x] `OBD_LIVE`, `DEVICE_STATUS` app side: decoders, telemetry and device-health cards, shown only when the dongle exposes them. Not run against firmware or a device
- [ ] Firmware: `OBD_LIVE` and `DEVICE_STATUS` characteristics
- [ ] `DEVICE_STATUS` carries `pending_bundle_count`, `oldest_pending_age_s`, and a WiFi-sync-in-progress flag (requested in the plan; lets the app say "dongle is syncing" and show un-synced drives)
- [ ] Live dashboard

## Phase 3 — Trips and history

The app side started early. Nothing here has run against a real server yet.

- [x] Local drive history: `DriveSegmenter` (10 min gap closes a drive), `DriveSession`, file-backed `DriveStore` with one JSON file per drive, crash recovery for interrupted sessions, History tab with drive detail
- [x] Trip snapshot sync: the server URL is set in Settings (kept on-device in `UserDefaults`, never in the repo), the app downloads the snapshot archive, extracts the Parquet files, and loads them into an on-device DuckDB for offline browsing
- [x] Server trip stats merged into drive detail
- [ ] Verify snapshot sync against the real server (archive format, `ETag` handling, `schema_version` check)
- [ ] Per-drive server state (`onDongle` / `uploaded` / `consumed`) matched by time overlap; until then drives show as unknown
- [ ] Location track and map in drive detail (plan decision: store a track always, so retention and delete-all matter)
- [ ] Retention limit and export
- [ ] Internal-vs-phone analysis, matched by measurement time
- [ ] Decide on powering down internal GNSS when the phone is connected

## v3 — Authenticated sync and multi-vehicle

Cairn v3 replaces the unauthenticated snapshot download with an enrolled-client model. The phone gets a Secure Enclave P-256 identity, signs every request, and syncs through a durable outbox. Data is scoped by vehicle. The protocol spec and test vectors live in the Cairn repo at `docs/app-sync-protocol.md` (not yet published).

Suggested order: #12 → #1 → #2 → #3 + #4 → #5 → #6 → #7 → #10 → #8 → #11; #9 when firmware Phase 22 freezes.

- [ ] #12 Golden vectors, CI and docs
- [ ] #1 Secure Enclave identity and enrolment
- [ ] #2 CairnServerClient: per-request signing and bearer tokens
- [ ] #3 Vehicle model, selected vehicle, per-vehicle data
- [ ] #4 Encrypted local store (SQLite, `.completeUntilFirstUserAuthentication`)
- [ ] #5 Durable outbox and SyncEngine
- [ ] #6 Local-first / Tailnet-fallback endpoint selection
- [ ] #7 Trip snapshot on authenticated API
- [ ] #8 Maintenance log, odometer corrections, trip annotations
- [ ] #9 BLE session authentication (blocked on firmware Phase 22)
- [ ] #10 Revocation state, identity reset, admin actions
- [ ] #11 Privacy and log hygiene audit
