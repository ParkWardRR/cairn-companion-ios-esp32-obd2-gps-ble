---
planStatus:
  planId: plan-cairn-ui-ux-overhaul
  title: "Cairn Companion — UI/UX Overhaul & Forward Plan"
  status: draft
  planType: initiative
  priority: high
  owner: twesh
  stakeholders: []
  tags: [ios, ui-ux, cairn-v3, restructure]
  created: "2026-10-05"
  updated: "2026-10-05T22:50:00.000Z"
  progress: 0
---

# Cairn Companion — UI/UX Overhaul & Forward Plan

## Problem

The app started as a one-screen BLE GPS relay and has grown into a vehicle management + telemetry + maintenance + sync platform. The current 3-tab layout (Live, History, Settings) is straining:

- **Settings is a dumping ground** — vehicles, maintenance, server config, sync status, and danger zone are all in one scrolling form. The maintenance log (15 service categories, odometer, cost tracking) is buried below the vehicle picker.
- **No vehicle identity** — the Live screen doesn't show which car is active. Switching vehicles requires navigating to Settings.
- **History is flat** — no search, no date filter, no favorites-only view. The only filter is vehicle selection (set elsewhere, in Settings).
- **No home for v3 features** — enrolment, sync engine diagnostics, route selection, and admin panels have nowhere to land in the current layout.
- **No first-run experience** — new users see a blank Live screen with no guidance beyond a "?" button.

## Current Architecture (3 tabs)

```
Live                    History                 Settings
 - Header + icon         - Vehicle nav title     - Vehicle list + add
 - Status card            - Drive list             - Maintenance (last 5)
 - Auto-connect toggle    - Server trips merge     - Odometer
 - Pairing card           - Drive detail:          - Server URL
 - Location banner          phone stats            - Sync status
 - Phone GPS card            server stats           - Danger zone
 - Device GPS card           event timeline
 - OBD telemetry card       annotations
 - Device health card
 - Acceptance card
```

## Proposed Architecture (4 tabs)

```
Drive           History           Garage           Settings
 (live session)  (drives + trips)  (vehicles + mx)  (app config)
```

### Tab 1: Drive

The live session screen. Keeps all existing cards but adds vehicle context.

| Element | Source | Notes |
|---------|--------|-------|
| Vehicle chip (top bar) | NEW | Tappable pill showing active vehicle name; tap to switch |
| Current drive summary | NEW | Appears during active session: elapsed time, streaming %, sent/accepted |
| Connection status card | existing | Unchanged |
| Auto-connect toggle | existing | Unchanged |
| Pairing card | existing | Unchanged |
| Location banner | existing | Unchanged |
| Phone GPS card | existing | Unchanged |
| Device GPS card | existing | Unchanged |
| OBD telemetry card | existing | Unchanged |
| Device health card | existing | Unchanged |
| Acceptance card | existing | Unchanged |
| Connection guide sheet | existing | Unchanged |

### Tab 2: History

Drive sessions with proper filtering and search.

| Element | Source | Notes |
|---------|--------|-------|
| Vehicle filter | ENHANCED | Segmented/dropdown at top, not derived from Settings |
| Date range picker | NEW | Quick filters: Today, This Week, This Month, All |
| Favorites toggle | NEW | Filter to starred drives only |
| Search bar | NEW | Search annotation text |
| Drive list | existing | Grouped by date; merged phone + server trips |
| Drive detail | existing | Phone stats, server stats, annotations, event timeline |
| Inline annotation editing | ENHANCED | Edit/delete notes directly in detail view |

### Tab 3: Garage

Vehicle-centric hub. This is the new tab — all vehicle and maintenance content moves here from Settings.

| Element | Source | Notes |
|---------|--------|-------|
| Vehicle cards | MOVED from Settings | Card-based layout instead of form rows |
| Vehicle profile page | NEW | Push navigation from card tap |
| - Identity section | MOVED | Year, make, model, engine code, edit in place |
| - Dongle assignment | NEW | Shows assigned dongle ID, assign/unassign |
| - Odometer section | MOVED from Settings | Latest reading + history chart |
| - Maintenance timeline | MOVED from Settings | Full log with category icons, costs, dates |
| - Drive stats | NEW | Total drives, last drive date, drive quality breakdown |
| Add vehicle | MOVED from Settings | FAB or toolbar button |
| Log service sheet | MOVED from Settings | Opened from vehicle profile |
| Record odometer sheet | MOVED from Settings | Opened from vehicle profile |
| Archive/restore | MOVED from Settings | Swipe action on vehicle card |

### Tab 4: Settings

Lean app configuration. Everything vehicle-specific has moved to Garage.

| Section | Source | Notes |
|---------|--------|-------|
| **Identity** | NEW (v3) | Enrolment status, client ID, role, scope, instance |
| **Server** | MOVED | LAN URL + Tailnet URL (two fields for #6) |
| **Sync** | MOVED | Last sync, outbox queue count, route indicator |
| **Diagnostics** | NEW (v3) | Current route (LAN/Tailnet), latency, connection log |
| **Admin** | NEW (v3) | List enrolled clients, revoke (admin role only) |
| **Data** | MOVED | Delete all history, forget dongle, reset identity |
| **About** | NEW | Version, build, open-source licenses |

## First-Run Flow (v3 Enrolment)

When the app launches for the first time (no Keychain identity found):

```
Welcome screen
  "Cairn connects your phone to your in-car logger"
  [Get Started]
    |
    v
Add Vehicle
  Year / Make / Model / Engine Code
  [Next]
    |
    v
Server Setup (optional, skippable)
  Enter server URL
  -or- "Set up later"
  [Next]
    |
    v
Enrol (if server configured)
  Enter invitation code
  → Secure Enclave key generation
  → POST /v1/enrol
  → Enrolled confirmation
  [Done → Drive tab]
```

If server setup is skipped, the app works offline — all local features (BLE, recording, maintenance) function without a server. Enrolment can happen later from Settings.

## Issue Mapping

Where each open companion issue lands in the new UI:

| Issue | Tab | Phase | Server dependency |
|-------|-----|-------|-------------------|
| #1 Secure Enclave enrolment | Settings (Identity) + first-run | D | Cairn #1 |
| #2 Per-request signing | invisible (infra) | D | Cairn #1 |
| #5 SyncEngine + outbox | Settings (Sync) | E | Cairn #2 |
| #6 LAN/Tailnet endpoint | Settings (Server + Diagnostics) | E | none |
| #7 Authenticated snapshot | invisible (infra) | E | Cairn #4 |
| #9 BLE auth | Drive (connection) | BLOCKED | firmware Phase 22 |
| #10 Revocation + admin | Settings (Admin + Data) | F | Cairn #3 |
| #12 Golden vectors | invisible (CI) | any | Cairn #1 |

## Implementation Phases

### Phase A — Tab Restructure

**Goal**: Move from 3 tabs to 4 without adding new features. Pure reorganization.

**Status**: COMPLETE (commit b8f906f, 2026-10-05)

**Scope**:
- [x] Create `GarageView` — vehicle list as cards, push to `VehicleProfileView`
- [x] Create `VehicleProfileView` — identity, maintenance timeline, odometer
- [x] Move vehicle section from `SettingsView` → `GarageView`
- [x] Move maintenance section from `SettingsView` → `VehicleProfileView`
- [ ] Add vehicle picker chip to `MainView` header (deferred to Phase B)
- [x] Update `RootView` tab bar: Drive, History, Garage, Settings
- [x] Clean up `SettingsView` — only server, sync, danger zone remain
- [x] Update store/dependency wiring through new views
- [x] Verify all existing tests still pass

**Estimated size**: ~400 lines new, ~200 lines moved, 0 new models

### Phase B — Garage Buildout

**Goal**: Make the Garage tab a proper vehicle management hub.

**Scope**:
- [ ] Dongle assignment UI in vehicle profile (assign/unassign)
- [ ] Odometer history chart (line chart of corrections over time)
- [ ] Per-vehicle drive stats (total drives, last drive, quality breakdown)
- [ ] Full maintenance timeline with date grouping
- [ ] Maintenance detail view (tap a row to see notes, cost, parts)
- [ ] Edit vehicle in-place (tap fields to modify)

**Estimated size**: ~600 lines new

### Phase C — History Improvements

**Goal**: Make drive history searchable and filterable.

**Scope**:
- [ ] Vehicle filter segmented control at top of History
- [ ] Date range quick filters (Today, Week, Month, All)
- [ ] Favorites-only toggle
- [ ] Search bar filtering on annotation text
- [ ] Better empty states for each filter combination
- [ ] Inline annotation editing in drive detail

**Estimated size**: ~300 lines new/modified

### Phase D — First-Run + Enrolment (companion #1, #2)

**Goal**: Guided first-run experience and Secure Enclave enrolment.

**Depends on**: Cairn server #1 (protocol spec with test vectors)

**Scope**:
- [ ] `OnboardingView` — welcome, add vehicle, server setup, enrol
- [ ] Show onboarding when no Keychain identity exists
- [ ] Enrolment status section in Settings (Identity)
- [ ] Enrolment state indicator in Settings header
- [ ] Wire `SecureEnclaveIdentity` + `CairnServerClient` into onboarding
- [ ] Handle "enrol later" gracefully (offline-first)

**Estimated size**: ~500 lines new

### Phase E — Sync Engine UI (companion #5, #6, #7)

**Goal**: Visible sync status, background transfers, route diagnostics.

**Depends on**: Cairn server #2 (authenticated sync API), #4 (authenticated snapshot)

**Scope**:
- [ ] Outbox queue count badge on Settings tab
- [ ] Sync section in Settings: queue depth, last push/pull, errors
- [ ] Dual server URL fields (LAN + Tailnet) with probe indicator
- [ ] Diagnostics section: current route, latency, last probe result
- [ ] Background sync via `BGAppRefreshTask` + `BGProcessingTask`
- [ ] Move `TripSyncClient` to authenticated `CairnServerClient`

**Estimated size**: ~800 lines new/modified

### Phase F — Admin + Revocation (companion #10)

**Goal**: Admin panel for multi-device management, identity reset flow.

**Depends on**: Cairn server #3 (client revocation)

**Scope**:
- [ ] Admin section in Settings (visible only for admin-role enrolments)
- [ ] List enrolled clients with last-seen, role, device name
- [ ] Revoke client action with confirmation
- [ ] Detect 401 + show revocation banner
- [ ] "Reset Identity" in Data section — wipes Keychain, SE key, server data
- [ ] Re-enrol flow after reset

**Estimated size**: ~400 lines new

## Dependency Graph

```
Phase A (restructure) ← no dependencies, start now
Phase B (garage)      ← Phase A
Phase C (history)     ← Phase A
Phase D (enrolment)   ← Cairn #1 (protocol spec)
Phase E (sync)        ← Phase D + Cairn #2, #4
Phase F (admin)       ← Phase E + Cairn #3
```

Phases B and C are independent of each other and of server work — they can run in parallel after Phase A. Phases D/E/F form a serial chain gated by server-side issues.

## Mockups

### Drive Tab (enhanced with vehicle picker + current drive card)

[Drive Tab](nimbalyst-local/plans/mockups/drive-tab.mockup.html "width=390 height=900")

### History Tab (with filters, search, smart grouping)

[History Tab](nimbalyst-local/plans/mockups/history-tab.mockup.html "width=390 height=900")

### Garage Tab (vehicle cards with stats)

[Garage Tab](nimbalyst-local/plans/mockups/garage-tab.mockup.html "width=390 height=900")

### Vehicle Profile (pushed from Garage)

[Vehicle Profile](nimbalyst-local/plans/mockups/vehicle-profile.mockup.html "width=390 height=1100")

## Design Decisions

1. **Tab icons** — Drive: `location.fill`, History: `clock.arrow.circlepath`, Garage: `building.2`, Settings: `gear`
2. **Vehicle switcher** — Pill chip in the nav bar showing active vehicle name (e.g. "2017 M240i"); tapping opens a compact menu to switch
3. **Garage card style** — Reuse `MainView`'s Card/MetricGrid/Tone design system for visual consistency across the entire app
4. **History grouping** — Smart adaptive grouping: by day for recent drives, by week for older, by month for oldest. Adapts to volume.
