# Firmware changes (firmware repo)

All changes land in [ParkWardRR/cairn-esp32-device-firmware](https://github.com/ParkWardRR/cairn-esp32-device-firmware) (this was `firmware/cairn-v2/` before the repositories were split). Behind `CAIRN_BLE_COMPANION` (default 0).

## Why the internal GNSS is bad

| Fact | Source |
|---|---|
| Receiver sits behind the Freematics co-processor link (`ATGPS`, 38400 baud soft serial) under the dash | `sensors.cpp` |
| `h_acc_cm`, `v_acc_cm` always `0xFFFF`; `sats_visible` always unknown; `source_flags` always 0 | `sensors_read_gnss()` |
| Fix type inferred from sats used: ≥4 + altitude = 3D, ≥3 = 2D | `sensors_read_gnss()` |
| Gap reported when newest fix older than `CAIRN_GNSS_STALE_MS` (3000 ms) | `sensor_task.cpp` |

## New module: `src/ble_companion.cpp`

| Context | Work |
|---|---|
| NimBLE host task (GATT write callback) | Validate 28 B, apply staleness/validity/dup checks, map to `cairn_gnss_sample_t` with `source_flags \|= 0x20`, back-date `monotonic_ms`, non-blocking `xQueueSend` to the existing fact queue, bump counters |
| Core 1 (lifecycle tick or small helper) | 1 Hz notify of `GNSS_QUALITY` and `COMPANION_STATUS` |

No allocation, blocking, or SD I/O in callbacks. NimBLE: `h2zero/NimBLE-Arduino@^2.2.1`, pinned to a tested release. Chosen over Bluedroid for footprint (~60 KB flash / ~10 KB RAM vs ~200 KB / ~60 KB). The vendor `ble_spp_server.h` is not used.

## `source_flags` (bundle format v2 §4.1, offset 25)

| Bit | Meaning | Status |
|---:|---|---|
| 0 | GPS | existing |
| 1 | GLONASS | existing |
| 2 | Galileo | existing |
| 3 | BeiDou | existing |
| 4 | Dead-reckoned | existing |
| 5 | External source (phone) | **new** |
| 6–7 | Reserved | |

One-line addition to `docs/bundle-format-v2.md`. No structural format change; C, Go, and Rust implementations are unaffected. Merkle tree, signatures, and sync are untouched.

## Lifecycle: independent source state

```c
typedef struct {
    cairn_gnss_sample_t last_sample;
    uint32_t last_mono_ms;
    bool position_valid, speed_valid, altitude_valid;
    bool connected;      // internal: always true; phone: BLE session active
    uint16_t last_seq;   // phone only
} gnss_source_state_t;

gnss_source_state_t internal_gnss, phone_gnss;
```

`phone_gnss` is cleared on BLE disconnect.

## Policy: recording vs operational decisions

**Recording is source-neutral:** both sources are always written as separate `GNSS_SAMPLE` frames, distinguished by `source_flags` b5.

**Operational decisions need an explicit policy:**

| Decision | Rule |
|---|---|
| Event position (`last_gnss`) | Freshest source with valid position and age < `CAIRN_GNSS_STALE_MS`. Between two fresh valid sources, prefer phone (has accuracy metadata) |
| Trip speed (start/stop scoring) | Freshest source with valid speed. Valid position ≠ valid speed |
| `DEGRADED_GNSS` | Means *internal receiver* degradation. Phone does not mask it. "No source available" is a separate condition |
| `have_recent_gnss` | True if any source delivered a valid, fresh fix |
| Hysteresis | No per-sample toggling; same 3 s dwell as internal |

## Config

```c
#ifndef CAIRN_BLE_COMPANION
#define CAIRN_BLE_COMPANION 0
#endif
#define CAIRN_BLE_NAME "Cairn"            // display only
#define CAIRN_PHONE_GNSS_STALE_MS 3000
// secrets.h (gitignored): CAIRN_BLE_COMPANION 1, CAIRN_BLE_PASSKEY <6 digits>
```

## Storage compatibility (must be tested, not assumed)

Two samples can share a `mono_ms`.

- PostgreSQL `norm.position_samples`: key must not dedupe on `(boot_id, mono_ms)` alone.
- DuckDB `cairn-tsdb` `position`: both rows must survive.
- `v_telemetry` ASOF join and trajectory queries must not zigzag between sources.

```sql
SELECT mono_ms, lat_e7, lon_e7, h_acc_cm,
       CASE WHEN source_flags & 32 != 0 THEN 'phone' ELSE 'internal' END AS source
FROM position WHERE boot_id = ? ORDER BY mono_ms;
```

Offline comparison must match by measurement time, not receipt time. Disagreement between receivers does not prove which is correct.

## Write-rate estimate (validate on a drive)

One extra `GNSS_SAMPLE` per second: 32 B payload + 28 B frame overhead = 60 B/s on disk. The percentage increase depends on the real byte mix; measure it.

## Standby

Phone BLE presence must not hold the recorder awake. Internal GNSS stays powered down when parked; on wake the phone fix can arrive before the internal receiver reacquires.
