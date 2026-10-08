# Cairn Companion iOS App

BLE companion app for the Cairn ESP32 OBD-II/GPS logger dongle.

## Build & Test

```bash
cd CairnCompanion && swift build   # macOS debug build
cd CairnCompanion && swift test    # 163 tests, all CairnCore (run scripts/fetch-contracts.sh first)
```

For iOS builds, use Xcode (`CairnCompanion/CairnCompanion.xcodeproj`).

## Architecture

SPM multi-target inside `CairnCompanion/`:
- **CairnCore** — pure Swift models and logic, no iOS imports. All tests live here.
- **CairnRuntime** — iOS-specific: GRDB, DuckDB, Keychain, BLE, SwiftUI views.
- **App** — `@main` entry point, wires dependencies.

### Key patterns
- **Encrypted blob storage**: plaintext index columns + AES-256-GCM encrypted JSON blob (CryptoKit). Key in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- **Swift 6 strict concurrency**: actor isolation, `nonisolated`, `any Protocol` existentials.
- **Design system**: shared `CairnDesignSystem.swift` — Card, MetricGrid, Metric, Badge, Tone, Backdrop, surface colors.

### Tab structure (4 tabs)
1. **Drive** (`MainView`) — live BLE session, connection status, GPS/OBD cards
2. **Trips** (`TripsView`) — trips grouped by day, each a card with a route sketch, distance, duration and top speed (`TripSummary` in CairnCore); tap one for the route map, headline numbers, then the phone and server detail and notes
3. **Garage** (`GarageView` → `VehicleProfileView`) — vehicle cards, maintenance, odometer
4. **Settings** (`SettingsView`) — server URL, sync status, danger zone

## Contracts

`contracts.lock` pins a release of the contracts (tag and commit). `scripts/fetch-contracts.sh` fetches it into `.contracts/` (git-ignored); run it before `swift test`. `CAIRN_CONTRACTS=<dir>` points the tests at a local checkout instead. Nothing from the contracts is vendored: BLE golden vectors and the sync/v1 vectors are read from there. Bumping the pin is the only way to change them.

## Security constraints

- **Never commit the server URL** to the repo. It lives in UserDefaults only. Use `cairn.example.lan` as placeholder in docs/code.
- Sensitive data directories use `.completeUntilFirstUserAuthentication` file protection and `isExcludedFromBackup`.

## CI

- GitHub Actions workflows must use `runs-on: self-hosted` (local OrbStack). Never use GitHub-hosted runners.

## Plan

See `ui-ux-overhaul.md` for the full UI/UX overhaul roadmap (Phases A-F). Phases A, B, and C are complete. Phases D-F are blocked on server-side work.

## Related repos

- Front door + roadmap: `ParkWardRR/cairn-driving-log-selfhosted`
- Server: `ParkWardRR/cairn-vehicle-server` (enrolment, sync, revocation APIs)
- Firmware: `ParkWardRR/cairn-esp32-device-firmware`
- Web dashboard: `ParkWardRR/cairn-vehicle-web-dashboard`
