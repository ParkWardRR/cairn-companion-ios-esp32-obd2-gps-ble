# Cairn Companion iOS App

BLE companion app for the Cairn ESP32 OBD-II/GPS logger dongle.

## Build & Test

```bash
cd CairnCompanion && swift build   # macOS debug build
cd CairnCompanion && swift test    # 333 tests in 66 suites, all CairnCore (run scripts/fetch-contracts.sh first)
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
2. **Trips** (`TripsView`) — trips grouped by day, each an overview card: small map (`TripMapThumbnail`, MapKit snapshot over a route sketch), distance, duration, estimated mpg and average speed (`TripSummary` and `FuelEstimate` in CairnCore; the server snapshot's `position`, `obd` and `boost` tables feed distance, route and fuel samples); tap one for the route map, headline numbers, then the phone and server detail and notes
3. **Garage** (`GarageView` → `VehicleProfileView`) — vehicle cards, maintenance, odometer
4. **Settings** (`SettingsView`) — server URL, dashboard passkeys (`Passkey/`: `AuthenticationServices` sign-in and creation, in-app dashboard), sync status, danger zone

### CarPlay

Read-only Driving Task screen in `Sources/*/CarPlay/` plus `App/CarPlaySceneDelegate.swift`. See
`docs/carplay.md`. Two rules it depends on: the row skeleton is built once and only mutated in place
(so a BLE dropout never reloads the list), and readings fade through `LinkHealth.freshness` instead of
being blanked. All wording and banding lives in `HUDBuilder` in CairnCore, under test.

## Contracts

`contracts.lock` pins a release of the contracts (tag and commit). `scripts/fetch-contracts.sh` fetches it into `.contracts/` (git-ignored); run it before `swift test`. `CAIRN_CONTRACTS=<dir>` points the tests at a local checkout instead. Nothing from the contracts is vendored: BLE golden vectors and the sync/v1 vectors are read from there. Bumping the pin is the only way to change them.

## Security constraints

- **Never commit the server URL** to the repo. It lives in UserDefaults only. Use `cairn.example.lan` as placeholder in docs/code.
- Sensitive data directories use `.completeUntilFirstUserAuthentication` file protection and `isExcludedFromBackup`.

## CI

- GitHub Actions workflows must use `runs-on: self-hosted`. Never use GitHub-hosted runners.
- This repo's runner is a **macOS** LaunchAgent on the author's Mac (`cairn-mac-ios`), not the Podman host the other four repos use: a Linux runner cannot build `CairnRuntime` (CoreBluetooth, CoreLocation, UIKit, CryptoKit). If CI sits queued, check the LaunchAgent is up.

## Plan

The project keeps **one** roadmap, in the front door repo (`ROADMAP.md`). Do not start one here. This app's next work is its Phase 29 (become the dongle's relay: CoreBluetooth offload wiring plus an enrolment screen) and Phase 35 (routes, stretches and marking a drive -- designed in `docs/routes-and-marking.md`, two naming decisions open).

`ui-ux-overhaul.md` covers the UI restructure (Phases A-F); A, B and C are complete and D-F are blocked on server-side work.

## Related repos

- Front door + the one roadmap: `ParkWardRR/cairn-driving-log-selfhosted`
- Server: `ParkWardRR/cairn-vehicle-server` (enrolment, sync, revocation APIs)
- Firmware: `ParkWardRR/cairn-esp32-device-firmware`
- Web dashboard: `ParkWardRR/cairn-vehicle-web-dashboard`
- Modules: `ParkWardRR/cairn-modules`
