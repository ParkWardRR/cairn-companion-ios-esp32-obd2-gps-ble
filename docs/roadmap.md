# Roadmap

Checkboxes are the Phase 1 work items from the plan. The iOS app is built and runs against the dongle; the firmware is flashed and running on hardware. Phase 1 stays open until every row of [validation.md](validation.md) passes.

Firmware items are checked only where the firmware repo reports them done ([HANDOFF-FIRMWARE.md](../HANDOFF-FIRMWARE.md), response of 2026-10-03). Rows marked *host-tested* are covered by firmware host tests or docs, not yet by a drive. The [Cairn](https://github.com/ParkWardRR/cairn-driving-log-selfhosted) repo is the source of truth for the rest.

## Current focus

The Phase 1 firmware rows are done on the firmware side. What remains is on-device validation: background wake from suspended and terminated, the drive test, and the firmware resource rows (stack, heap, IMU deadlines under BLE + SD + WiFi), all of which need a drive.

On the app side, the link-health UI and the History tab are built, ahead of the original Phase 3 plan. Phase 2 `BARO_ALT` and `UTC_SYNC` stay dormant until the firmware exposes them. `OBD_LIVE` and `DEVICE_STATUS` are decoded and shown when present. Open work is listed in [HANDOFF-FIRMWARE.md](../HANDOFF-FIRMWARE.md) and [plan-link-health-and-history.md](plan-link-health-and-history.md).

CarPlay shipped on 2026-10-08 and now needs the App ID capability and a drive. [Phase 4](#phase-4--routes-stretches-and-in-drive-marking) is new and not started: routes and stretches, and marking a drive by voice or one tap. It is blocked on server-side model work and on two naming decisions recorded there.

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
- [x] Golden-vector tests: golden-vectors.json from the pinned contracts release, from an independent spec implementation, replayed by the iOS tests
- [x] Firmware repo consumes the same `golden-vectors.json` (6/6 pass in `test/host/ble_vectors.c`)
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

## Phase 4 — Routes, stretches and in-drive marking

Owner's brief, 2026-10-08. Two halves that only pay off together: a **shape** for a drive that is
richer than one flat polyline, and a way to **mark something while driving** without looking at a
screen. The marks are what make the shapes worth having — an "I drove this road" record is only
interesting once you can say *this* part, and *that* felt wrong.

Nothing here has started. The model work lands server-side first; this repo consumes it.

### The model

| Term | What it is | Detected how |
|---|---|---|
| **Stretch** | A bounded piece of a route, with a start and an end. May be named and reused ("the canyon run") | User-marked, or cut at a stop |
| **Route** | A sequence of stretches that forms one shape: **out-and-back**, **loop**, or **one-way** | Auto-detected from the track |
| **Trip** | One or more routes | Existing drive/stop/gap segmentation |

Two decisions are open and need the owner's call before any code:

- **Naming.** "Segment" is already taken three times over in Cairn: the AEAD-encrypted on-SD storage
  unit in bundle format v3 (`CRN3` segment header, HKDF per-segment keys — a frozen contract), the
  iOS `DriveSegmenter`'s 10-minute gap split, and the server's drive/stop/gap segmentation. A fourth
  meaning would make every conversation ambiguous. **Recommendation: use "stretch"**, which the brief
  already offers, and leave "segment" to storage.
- **Hierarchy.** "Multiple routes make up a trip" inverts how Cairn uses "trip" today, where a trip is
  one drive and a route is the line it drew. It works if a trip is the whole outing — drive to the
  canyon (one-way), run the loop, drive home (one-way) — but that is a different trip boundary from
  the one the server's derived trip builder already uses. Either redefine the boundary or put the
  outing above the trip under a new name.

### Depends on

- Server: route and stretch tables, the out-and-back / loop / one-way classifier, and stretch
  matching across drives so the same road recognises itself. Tracked in
  [cairn-driving-log-selfhosted](https://github.com/ParkWardRR/cairn-driving-log-selfhosted) — its
  ROADMAP already carries "bookmark, tag and search a route" under History (#1).
- Contracts: new `store/v1` views for routes and stretches, and a `sync/v1` carrier for marks.
  Additive, so the pin bumps rather than breaks.
- Phase 3 track storage: a route cannot be classified without the track, and that row is still open.
- v3 #8 (annotations) for syncing marks off the phone. `Annotation` already has `targetID`, `kind`,
  `text` and `tags`, so a mark is a new `AnnotationKind` rather than a new store.

### Marking while driving — capture

Every mark is captured **on the phone**, timestamped against the drive, and reconciled to dongle data
afterwards. This is deliberate: the BLE link drops, and a mark that needed a live link would be lost
exactly when something interesting was happening. A mark taken with the dongle silent is still a
valid mark; it just resolves its telemetry later.

- [ ] `DriveMark` in CairnCore: kind, timestamp, drive id, optional location, optional text, and the
      telemetry actually held at that moment with its freshness — never a fabricated reading
- [ ] Reconciliation pass: once the dongle's data for that window arrives, attach it to the mark
- [ ] One-tap marks, no category chooser, from the Drive tab
- [ ] Action button and Control Center control (iPhone 15 Pro and later) for a mark without unlocking
- [ ] Lock Screen Live Activity with the same single button
- [ ] CarPlay: a mark button on the Now deck. Driving Task templates allow `headerGridButtons` and
      row handlers, so this stays inside the entitlement — it is the first write the car screen does,
      and must not touch recording state
- [ ] Haptic and spoken confirmation, because the driver is not looking

| Mark | What Cairn saves | Why |
|---|---|---|
| Something felt off | Telemetry and location either side of the tap | Catch an intermittent hesitation without watching instruments |
| Heard a noise | Marker with speed, RPM and whatever else is live — **not audio** | Correlate a noise with operating conditions afterwards |
| Save data clip | A bounded excerpt of the existing recording | Pull an event out of a long trip |
| Tag this drive | A whole-trip flag | Tie a drive to maintenance or a fuel change without typing |
| Check this later | A generic review marker | One universal button when choosing would distract |

> **"Either side of the tap" needs a pre-roll.** You can only save what came *before* if something
> was already keeping it. Two ways: a phone-side ring buffer of the last N seconds of `OBD_LIVE` and
> fixes, which is cheap but only holds what BLE actually delivered; or asking the dongle for the
> window, which is complete but needs a new characteristic and firmware work. **Recommendation: ship
> the ring buffer first**, since it works with today's firmware, and treat the dongle-side excerpt as
> the upgrade that makes "save data clip" exact.

### Marking while driving — voice

App Intents plus App Shortcuts, so the phrases work from Siri, Spotlight, the Action button and
CarPlay without a custom voice stack. Not started; no `AppIntent` exists in the project yet.

| Phrase | Action | Response |
|---|---|---|
| "Mark this stretch" | Bookmark the recent route context | "Stretch marked." |
| "Start a favorite stretch" | Open a bounded stretch bookmark | "Stretch started." |
| "End the stretch" | Close it | "Stretch saved." |
| "Something felt off" | Diagnostic mark with the surrounding data | "Event saved." |
| "Save this view" | Scenic location mark | "Location saved." |
| "Add a note to this drive" | Takes a short spoken string | "Note saved." |
| "How long have I been driving?" | Current session duration | "Thirty-two minutes." |
| "Is my drive recording?" | Session status | "Recording confirmed." / "I can't confirm recording." |

- [ ] `AppIntent` per phrase, with `AppShortcutsProvider` phrases and synonyms
- [ ] Intents run without launching the UI, and work from the Lock Screen
- [ ] "Is my drive recording?" answers off the **same evidence rule as the CarPlay HUD** —
      `HUDBuilder.hero`, which only claims recording on the dongle's own fresh word. The negative
      answer is a feature: a logger that cannot say "I can't confirm" is not trustworthy
- [ ] "How long have I been driving?" reports the session, and says so when the link has been down
      for part of it
- [ ] Donate intents so Siri suggests them in the car

### Review, afterwards

- [ ] Trips tab: routes drawn with their shape named, stretches selectable within a route
- [ ] Marks on the route map and on the speed trace, tappable
- [ ] Named stretches as first-class objects: every run of the same stretch, compared
- [ ] Filter and search drives by mark kind and tag
- [ ] Export a marked clip

**Exit:** a drive can be marked by voice with the phone locked, and the mark is found afterwards on
the right stretch with the telemetry that was actually live at the time.

## CarPlay

**Apple approved the Driving Task entitlement on 2026-10-08, which reverses the earlier decision.** [carplay-design.md](carplay-design.md) argued for widgets instead on the grounds that approval was unlikely; that reasoning is superseded, though its widget analysis still stands on its own. The screen that shipped is described in [carplay.md](carplay.md).

- [x] Read-only Driving Task screen: three tabs (Now, Trip, Device) under a `CPTabBarTemplate`
- [x] Fixed row skeleton built once per connection and mutated in place, so a BLE dropout never reloads the list
- [x] Readings held and faded through `LinkHealth.freshness` rather than blanked; "never read" drawn differently from "reading zero"
- [x] Keystone and gauge glyphs drawn in Core Graphics, cached per bucket, light and dark in one `UIImageAsset`
- [x] CarPlay is handed `SessionState` and never `DrivingSession`, so the car screen cannot start or stop recording
- [ ] Enable **CarPlay Driving Task App** on the App ID and regenerate the provisioning profile (device builds will not sign until this is done)
- [ ] Simulator check: scene registration and state transitions via I/O → External Displays → CarPlay
- [ ] Drive test: cold launch from the head unit, locked phone, disconnect and reconnect
- [ ] Widgets and Live Activities, still worth doing on their own merits — the Lock Screen and StandBy reach a phone on a mount in a car with no CarPlay head unit at all
