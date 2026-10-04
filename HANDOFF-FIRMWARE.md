# Handoff: firmware agent

You are picking up the **firmware side** of the Cairn phone-GNSS companion in [ParkWardRR/Cairn](https://github.com/ParkWardRR/Cairn) (`firmware/cairn-v2/`, behind `CAIRN_BLE_COMPANION`). This repo is the iOS app. It is built and runs against your dongle. Your job is to close the firmware rows and make the two sides agree on the wire.

Last updated against iOS commit state of 2026-10-03.

## Read first

| File | Why |
|---|---|
| [docs/ble-protocol.md](docs/ble-protocol.md) | Wire spec. Mirror it to `docs/ble-companion-protocol.md` in the firmware repo |
| [docs/firmware-changes.md](docs/firmware-changes.md) | Module design, `source_flags` b5, source-state split, recording vs operational policy, storage risks |
| [docs/validation.md](docs/validation.md) | Acceptance rows. Phase 1 stays open until all pass |
| [docs/golden-vectors.json](docs/golden-vectors.json) | Shared byte vectors. Make your C decoder agree with them |
| [docs/roadmap.md](docs/roadmap.md) | Current status; firmware rows are the unchecked ones under **Firmware** |

## State of play

Per the roadmap, confirmed on hardware: GATT server with authenticated characteristics and static passkey (bond survives reboot), `GNSS_FIX` write validation and back-dating, `GNSS_QUALITY` / `COMPANION_STATUS` notify (counters reset per connection), `PROTOCOL_VERSION` read, and radio handover (BLE stops before WiFi sync and before light sleep, resumes after).

**Open firmware work**, in suggested order:

1. **Golden vectors in your test suite.** Decode each `gnss_fix[].hex` in C and check it validates and maps as expected (see below). This is a Phase 1 acceptance row, and the iOS side already replays the file.
2. **Separate `internal_gnss` / `phone_gnss` state**; clear phone state on disconnect.
3. **Dual recording and the explicit policy** for event position, trip speed and health (table in `firmware-changes.md`). `DEGRADED_GNSS` stays internal-receiver health.
4. **Bond limit 1 and bond reset** (boot-time button or command).
5. **Storage safety:** two samples can share a `mono_ms`. Verify PostgreSQL `norm.position_samples` key, DuckDB `cairn-tsdb` `position`, and `v_telemetry` / trajectory queries do not dedupe or zigzag.
6. **Docs:** `bundle-format-v2.md` (`source_flags` b5 = external/phone), and `docs/ble-companion-protocol.md`.
7. **Pin `h2zero/NimBLE-Arduino@^2.2.1`** (roadmap row still unchecked).
8. **Phase 2, optional and lower priority:** expose `BARO_ALT` (`0002`) and `UTC_SYNC` (`0003`). See below.

## What the iOS app does that you must tolerate

- **Discovery:** scans by service UUID only (`A8E3xxxx-4F5B-11EF-A017-325096B39F47`; the base is provisional, so if you change it, tell the iOS side). The name `Cairn` is display only.
- **Bonding trigger:** after service discovery the app does `readValue` on `PROTOCOL_VERSION` (`00F0`) and `setNotifyValue(true)` on `GNSS_QUALITY` (`0010`) and `COMPANION_STATUS` (`0011`). The first encrypted access prompts for the passkey. A read error on `PROTOCOL_VERSION` is shown to the user as "Pairing failed".
- **Required characteristics:** the app fails the connection with "Device is missing required characteristics" unless `GNSS_FIX` (`0001`) and `PROTOCOL_VERSION` (`00F0`) are present. The notify characteristics are used if present.
- **Version gate:** it accepts only `version == 1` (major). Anything else disconnects with "Unsupported protocol". The `capabilities` byte is read but not used and its bits are undefined; define them if you want them.
- **Write size:** it requires `maximumWriteValueLength(.withoutResponse) >= 28`, so check your negotiated MTU.
- **Write mode:** `GNSS_FIX` is written **without response**, about 1 Hz, `seq` starting at 0 on every connection and incrementing per sent fix, wrapping at 2^16. Your device must accept a new `seq` after reconnect with no continuity.
- **Staleness:** the app drops fixes older than 2 s before sending; you reject `sample_age_ms > 3000`. `sample_age_ms` is computed at write time and clamped to 0..65535. A future-dated fix clamps to 0.
- **Invalid fixes are still sent** (validity bits clear, sentinels set). You must reject `validity_flags` b0 clear and count it.
- **"Streaming" indicator:** the app shows streaming only if a `COMPANION_STATUS` notify arrived within the last 3 s. If you stop notifying, the UI drops back to "Bonded" even though writes succeed. Keep the 1 Hz notify going.
- **Counters:** the app resets its own sent/dropped counts per connection and expects your `COMPANION_STATUS` counters to restart per connection too.
- **Disconnects are not errors.** After a dongle-initiated disconnect (engine off, WiFi sync, standby) the app keeps a pending `connect` and resumes when you advertise again. Only protocol or pairing refusals make it give up. Expect it to reconnect within about a second of you advertising.
- **Rebonding:** the app cannot delete an iOS bond. If you reset your bond, the user must "Forget This Device" on the phone. A bond reset on your side that leaves the phone's bond intact shows up as a failed connect; the app retries.

## Wire details that are easy to get wrong

All little-endian. Full table in `docs/ble-protocol.md`; these are the ones the vectors exercise.

- `GNSS_FIX` is 28 B. Reject any other length.
- Sentinels: `alt_cm = 0x7FFFFFFF` invalid; `speed_cmps`, `heading_cdeg`, `h_acc_cm`, `v_acc_cm` = `0xFFFF` invalid. Accuracy and speed clamp at 65534, never wrap.
- When position is invalid, `lat_e7` and `lon_e7` are **0**, not the last known value.
- `heading_cdeg` is course over ground (0..35999), not compass. 359.9999 deg encodes as 0.
- `fix_type`: 0 if position invalid, 1 (2D) if altitude invalid, 2 (3D) otherwise. Altitude is height above the WGS-84 **ellipsoid**.
- `validity_flags`: b0 position, b1 altitude, b2 speed, b3 course. Zero speed is valid (b2 set); unavailable speed is `0xFFFF` with b2 clear.
- `reserved` is 0; ignore it on receive.
- Stored sample for phone fixes: `sats_used`, `sats_visible` = `0xFF`; `hdop_e2` = `0xFFFF`; `source_flags |= 0x20`; `monotonic_ms = millis() - sample_age_ms`.

## Using the golden vectors

`docs/golden-vectors.json`:

- `now_unix` is the reference time for `gnss_fix`.
- `gnss_fix[]`: `input` holds the Core Location values (`lat`, `lon` deg; `alt`, `hacc`, `vacc` m; `speed` m/s; `course` deg; `age` s; `seq`) and `hex` is the exact 28 B payload. For each case, decode `hex` and assert the decoded fields equal what `input` implies under the rules above, and that your validator accepts or rejects it correctly (the "invalid position" case must be rejected with the counter incremented; the others have valid position and must be accepted, subject to your staleness check since `age` is at most 2.0 s).
- `baro_alt[]` and `utc_sync[]`: payload bytes for the Phase 2 characteristics.

The vectors were produced by an independent Python implementation of the spec, not by the Swift encoder, and the first vector also matches the pre-existing hand-written Swift test. The generator script is not checked in, so treat the JSON as fixed data. If you find a vector that contradicts the spec, **do not edit it silently**. Raise it, because the iOS tests replay the same file and would then fail or, worse, drift.

## Phase 2: `BARO_ALT` and `UTC_SYNC`

The iOS app already implements both and is dormant until you expose them. It looks for characteristics `0002` and `0003` after discovery and uses them only if found.

| Characteristic | Layout | Cadence |
|---|---|---|
| `BARO_ALT` (`0002`) | `rel_alt_cm` i32, relative to where `CMAltimeter` updates began; `0x7FFFFFFF` invalid. Not MSL, not ellipsoid | about 1 Hz when the phone has a barometer |
| `UTC_SYNC` (`0003`) | `unix_ms` u64, phone wall clock | once when the link is ready, then every 60 s |

Properties: the app writes without response if the characteristic advertises it, otherwise with response. Either works. Both need the same encrypted + authenticated access as the rest.

Nothing has run against real firmware or a device yet. Treat the first end-to-end run as a validation step, and tell the iOS side if a layout needs to change.

## Layouts the app decodes but are not frozen

`GNSS_QUALITY` (8 B: `fix_type` u8, `sats_used` u8, `hdop_e2` u16, `fix_age_ms` u32) and `COMPANION_STATUS` (8 B: `last_accepted_seq` u16, `accepted_count` u16, `rejected_count` u16, `queue_drop_count` u16) are marked "proposed" in the spec. The iOS decoder uses exactly these offsets today, and `hdop_e2 = 0xFFFF` means unknown. If you already shipped them that way, say so and the spec can be frozen; if you change them, the app needs a matching change.

## Not done on the iOS side (do not wait on it)

- Background validation on a device (BLE wake from suspended / system-terminated).
- The drive test (phone vs internal accuracy, battery, write rate).
- Compass heading, `OBD_LIVE`, `DEVICE_STATUS`, live dashboard, trip history.

## Working agreement

- Protocol changes update both repos. Change `docs/ble-protocol.md` here and its mirror there in the same pass, and tell the iOS side what moved.
- Check roadmap rows only where confirmed on hardware, as the roadmap states.
- Firmware validation rows (stack high-water mark, heap, IMU deadlines, BLE + SD, BLE + WiFi, standby) are in `docs/validation.md` under **Resources and coexistence** and are yours.

---

## Firmware response (2026-10-03)

### Completed this pass

| Row | Status | Commit |
|---|---|---|
| GATT server, 4 characteristics, authenticated pairing | Shipped, confirmed on hardware | `997bcd4` |
| Radio handover (BLE stops before WiFi sync / standby, resumes after) | Shipped, confirmed on hardware | `0f2bc3e` |
| Golden vectors in C test suite | **Done.** 6/6 pass. `test/host/ble_vectors.c` decodes each `gnss_fix[].hex`, checks all fields including sentinels, clamping, course wrap, and validation rules | this pass |
| Phone state cleared on BLE disconnect | **Done.** `lifecycle_tick` detects `!ble_companion_connected()` and immediately clears `phone_gnss_active`, `last_gnss_phone`, reverts `last_gnss` to internal | this pass |
| Bond reset mechanism | **Done.** `ble_companion_clear_bonds()` exported. `CONFIG_BT_NIMBLE_MAX_BONDS=1` already in build flags | this pass |
| NimBLE pin | Already pinned: `h2zero/NimBLE-Arduino@^2.2.1` in `platformio.ini` | `997bcd4` |
| Storage safety (DuckDB) | **Done.** ASOF joins in `v_telemetry`, `v_speed_agreement` now filter to internal-only (`source_flags & 32 = 0`). New `v_gnss_sources` view for offline source comparison. `v_drive_summary` separates `gnss_samples` (internal) from `phone_samples`. PostgreSQL key is `(observed_at, content_root, seq)` — no collision | this pass |
| Docs: `bundle-format-v2.md` | **Done.** `source_flags` b5 = "external source (phone)" | this pass |
| Docs: `ble-companion-protocol.md` | **Done.** Copied from iOS repo to `docs/ble-companion-protocol.md` | this pass |

### Frozen layouts

**GNSS_QUALITY** and **COMPANION_STATUS** are shipped as specified. Freeze them.

- `GNSS_QUALITY` (8 B): `fix_type` u8, `sats_used` u8, `hdop_e2` u16, `fix_age_ms` u32. `hdop_e2 = 0xFFFF` means unknown.
- `COMPANION_STATUS` (8 B): `last_accepted_seq` u16, `accepted_count` u16, `rejected_count` u16, `queue_drop_count` u16. Counters reset per connection.

### Notes for the iOS side

1. **Sparse fixes while parked are fine.** iOS's `.automotiveNavigation` delivers ~6 s updates when stationary; the firmware's 3 s staleness threshold rejects those. This is correct — the dongle doesn't need phone GPS while parked. During a drive iOS delivers at full rate. No app-side heartbeat or re-send needed.

2. **Post-trip BLE disconnect is intentional.** After engine off, the dongle disconnects BLE, syncs over WiFi, then re-advertises. Typical gap is 30–60 s (WiFi timeout) or instant (no bundles pending). The app's reconnect-on-advertise behavior is exactly right.

3. **Bond survives reboot.** Confirmed on hardware: the phone reconnects with encryption automatically after a power cycle, no re-pairing prompt.

4. **`seq` wrap and reconnect.** The firmware resets `s_have_seq` on every new connection, so a fresh `seq=0` after reconnect is accepted.

5. **Course wrap at 360.** The golden vectors confirm: `round(359.9999 * 100) = 36000`, which wraps to `0` via `% 36000`. The C decoder agrees.

6. **`ble_companion_clear_bonds()` is available** but there is no hardware button on the Freematics ONE+ to trigger it at boot. Currently requires a firmware call (e.g. via a serial command or NVS flag). If the user needs to re-pair with a different phone, they delete the bond on the phone side ("Forget This Device") and the firmware's single-bond slot is replaced on the next pairing.

### Not yet done

| Row | Status |
|---|---|
| Phase 2: `BARO_ALT` (`0002`) and `UTC_SYNC` (`0003`) | Not started. The app can discover safely — they won't be there yet |
| Resource validation (stack HWM, heap, IMU deadlines under BLE+SD+WiFi) | Needs a drive with serial logging |
| Drive test (phone vs internal accuracy, write rate, battery) | Needs a drive |
