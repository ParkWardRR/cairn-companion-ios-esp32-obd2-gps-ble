# Decisions and design review

## Decisions

| # | Decision | Alternative rejected | Reason |
|---|---|---|---|
| 1 | Record both GNSS sources as separate `GNSS_SAMPLE` frames | Pick best fix per tick; phone-only when connected | Preserves evidence to compare receivers offline; recording stays source-neutral |
| 2 | Static passkey in gitignored `secrets.h`, enforced on every characteristic | Just Works | Blocks drive-by connections; no display on the dongle |
| 3 | Phase 1 has no live dashboard | OBD gauges, full telemetry | Scope: phone feeds GPS, nothing more |
| 4 | Separate repo for the iOS app | Monorepo `ios/` | Independent App Store / CI lifecycle. Cost: protocol drift, mitigated by shared spec and golden vectors |
| 5 | Typed GATT characteristics | Serial-style BLE UART | One message type per characteristic; no framing or reassembly on a small-stack target |
| 6 | NimBLE | Bluedroid | Smaller flash/RAM footprint |
| 7 | Locked-screen driving session in Phase 1 | Foreground-only MVP | A mounted phone is routinely locked or running Maps; foreground-only would not be a dependable driving companion |
| 8 | `DEGRADED_GNSS` = internal receiver health | Clear when any source has a fix | Otherwise the phone masks an internal hardware fault |
| 9 | Swift + SwiftUI + Observation + async/await | Combine, UIKit | Preferred stack; iOS 17 minimum |

## Design review: what changed

An external review of the first draft produced these changes, all folded into the docs.

| Priority | Gap | Resolution |
|---|---|---|
| Critical | No measurement timestamp in `GNSS_FIX` | Added `sample_age_ms`, `seq`, `validity_flags`; payload 20 → 28 B; firmware back-dates `monotonic_ms` |
| Critical | "No source selection" contradicted lifecycle behavior | Explicit operational policy; independent per-source state |
| Critical | Foreground-only undermines driving use | `CLBackgroundActivitySession` + background modes in Phase 1 |
| High | CLLocation validity underspecified | Negative accuracy/speed/course handling, staleness gates, clamped overflow, `fix_type` mapping |
| High | "Streaming" only proved attempted transmission | `COMPANION_STATUS` acceptance feedback |
| High | Static passkey treated as sufficient | Characteristic-level encryption + auth, bond limit, bond reset, unbonded-injection test |
| High | Dual-source storage compatibility assumed | Key / dedup / trajectory-query tests |
| Medium | Resource and power numbers asserted | Reframed as validation targets |

## Platform corrections applied

| Earlier claim | Now |
|---|---|
| iPhone "sub-meter accuracy" | "Potentially better positioning with reported accuracy"; unproven in this vehicle |
| Phone is a "GNSS antenna" | It supplies Core Location estimates, not raw observations |
| `fix_type = 3` because altitude present | Mapped from horizontal/vertical validity independently; Core Location has no 3D/DGPS flag |
| Satellite count / constellation on screen | Removed; not exposed by Core Location |
| "1 Hz" and "10 Hz" Core Location | Transmit cadence is separate from system-managed arrival cadence |
| `liveUpdates` + `kCLLocationAccuracyBestForNavigation` | Use `LiveConfiguration` (`.automotiveNavigation`) only |
| "CoreBluetooth auto-reconnects" | App-level reconnect plus state restoration; no blanket guarantee |
| GATT gives "type safety" | GATT gives boundaries; decoders still validate length, range, version, semantics |
| BLE SPP needs MFi | Classic SPP and BLE serial-over-GATT are different; framing is a design choice |
| "NTP-disciplined clock" | Phone wall clock, unless sync is implemented and validated |
| Placeholder `CAIRN001-…` UUID | Not valid hex; real 128-bit base assigned |

## Open questions

1. **NimBLE host stack depth.** GATT write callbacks run on NimBLE's host task. Measure whether the default depth holds under sustained traffic.
2. **Cadence filtering.** System-managed update rate vs the ~1 Hz transmit target; confirm drop/tolerate behavior on a drive.
3. **Advertising.** Advertise when disconnected, stop on connect (~1 mA on 12 V). Confirm reconnect latency.
4. **Frozen layouts.** `GNSS_QUALITY` and `COMPANION_STATUS` offsets are proposed, not frozen.
5. **UUID registration.** Final 16-bit suffixes and base assigned when the spec lands in the firmware repo.
