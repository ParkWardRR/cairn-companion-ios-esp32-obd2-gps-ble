# Validation matrix

Every row is an acceptance test. Estimates in other docs (RAM, power, throughput, accuracy) are hypotheses until these pass.

## Protocol and security

| Test | Pass when |
|---|---|
| Bench: connect + passkey | Phone bonds; characteristics accessible only after authentication |
| Bench: unbonded phone | Cannot read, write, or subscribe; cannot inject location facts (NimBLE can fall back to Just Works depending on I/O caps; verify) |
| Golden vectors | Swift 28 B encoding and C decoding agree byte-for-byte, incl. sentinels and negative values |
| Bond deleted on phone | Device sees unbonded state; re-pair with passkey works |
| Bond deleted on device | Phone sees failed connect; re-bonds on next attempt |

## Sample handling

| Test | Pass when |
|---|---|
| Fact reaches queue | Appears as `FACT_GNSS_SAMPLE` with `source_flags & 0x20` |
| Timestamp mapping | `monotonic_ms` reflects measurement time, not BLE receipt |
| Stale sample | `sample_age_ms > 3000` rejected; rejected count increments; `DEGRADED_GNSS` unchanged |
| Cached fix after reconnect | Not used for `last_gnss`, health, or trip scoring |
| Invalid position | `horizontalAccuracy < 0` → rejected |
| Accuracy overflow | 700 m → `h_acc_cm = 65534`, not a wrapped small value |
| Invalid speed / course | Not recorded as 0 cm/s or valid northbound heading |
| Duplicate `seq` | Rejected, not double-recorded |
| Queue saturation | Sensing unaffected; drops visible in `COMPANION_STATUS` |

## Drive

| Test | Pass when |
|---|---|
| Both sources recorded | Phone frames have real `h_acc_cm`; internal frames have `0xFFFF` |
| Source split | `source_flags & 32` separates phone from internal in the decoded bundle |
| Screen lock | Streaming and BLE continue |
| Foreground Maps | Streaming continues |
| Phone disconnect | Internal GNSS unaffected; `phone_gnss` cleared; counters reset |
| Phone reconnect | Clean resume, no replay, new `seq` accepted |
| Bluetooth toggle / dongle reboot | Reconnects without replaying old fixes |

## Storage and analysis

| Test | Pass when |
|---|---|
| Two samples at same `mono_ms` | Both survive ingest (PostgreSQL + DuckDB), no overwrite or dedup |
| Trajectory queries | `v_telemetry` and existing queries do not zigzag between sources |
| `source_flags` in tsdb | Nonzero values stored and queryable |
| Offline comparison | Matched by measurement time; reports availability, freshness, continuity, jumps, disagreement |

## Resources and coexistence

| Test | Pass when |
|---|---|
| NimBLE stack | `uxTaskGetStackHighWaterMark` under sustained 1 Hz writes + Wi-Fi + SD load (not just boot) |
| Internal heap | Minimum free heap measured under the same load |
| IMU deadlines | 50 Hz sampling deadlines met with BLE active |
| BLE + SD | No fact-queue drops attributable to BLE |
| BLE + Wi-Fi | Phone connected, then parked sync succeeds |
| Standby | Phone BLE presence does not hold the recorder awake |
| Phone battery / current | Measured on a real drive; no target assumed |
| Disk write rate | Measured byte-rate increase on a real drive |
