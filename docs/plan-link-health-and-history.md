# Plan: link-health UI and History tab

Status: Part 1 (steps 1 and 2) implemented: ideas 1 to 6 in the Part 1 table. Idea 7 (haptic/notification) was not selected. Part 2 (History tab) is still a plan.

Decisions so far: store a location track in drive history **always** (the plan had recommended an opt-in toggle; that is now overridden, so retention and a delete-all control matter more).

## Part 1: Link-health UI

### Problem

The BLE link is a set of discrete events (connect, bond, ready, drop, retry) plus two slow notify channels. It is not a continuous stream. The UI treats it like one:

- `SessionState` holds one timestamp, `lastStatusAt`. `GNSS_QUALITY`, writes, and connection transitions are not timestamped.
- `linkLost()` and `retry()` call `resetDeviceState()`, which sets `deviceQuality` and `companionStatus` to nil. The cards go blank and the user loses "what was it doing just before it dropped".
- `ready` with no ack shows "Bonded". That could mean "just connected, ack imminent" or "dongle went silent 40 s ago". The user can't tell.
- Reconnect backoff (1 s up to 15 s, 8 attempts) is invisible. `.connecting` looks the same on attempt 1 and attempt 7.
- `sentCount` climbs even when the dongle isn't accepting. Nothing shows the gap between sent and acknowledged.
- A drop and a recovery leave no trace in the UI. They only appear in `DriveLog`.

### Ideas (ranked by value for effort)

| # | Idea | What the user sees | Needs |
|---|------|--------------------|-------|
| 1 | **Per-channel "last heard" with a freshness state** | Each card header shows `Heard 2 s ago`. Dot colour: live (< 3 s), stale (3 to 10 s), silent (> 10 s). Replaces the vague "Bonded". | Timestamps per channel in `SessionState`; a pure `Freshness` classifier in `CairnCore` |
| 2 | **Keep last-known data, dimmed, when the link drops** | Cards keep their last values, greyed, with `as of 14 s ago`, instead of going to placeholders | Stop nulling in `resetDeviceState`; add `isStale` flag or derive from freshness |
| 3 | **Reconnect countdown** | `Reconnecting in 4 s · attempt 3 of 8` | `nextRetryAt` and `failureStreak` published from `CairnBLEManager` |
| 4 | **Link timeline strip** | One line under the status card: `Connected 4 m 12 s · 2 drops this drive · last drop 1 m ago` | `LinkEvent` ring buffer in `SessionState` |
| 5 | **Ack health bar** | Sent vs accepted delta (`Unacked: 3`). Turns amber when sent outpaces accepted | Derive from `sentCount` and `companionStatus.acceptedCount` (already available) |
| 6 | **Heartbeat pulse** | The status icon pulses once per `COMPANION_STATUS`. A drain ring empties over the 3 s streaming timeout, so a dying link is visible before it flips | `lastStatusAt` plus `TimelineView` |
| 7 | **Haptic or local notification on drop mid-drive** | Tap when the link drops or recovers, and an optional notification when backgrounded | `UNUserNotificationCenter`, opt-in |

Recommend building 1 to 5 together. Idea 6 is cheap polish once 1 is in. Idea 7 is optional and needs a permission prompt. Live Activity and Dynamic Island are a possible later step and out of scope here.

### Design

**Model (CairnCore, testable on macOS)**

```swift
public enum LinkEventKind: String, Codable, Sendable {
    case armed, disarmed, scanning, connected, bonded, ready
    case dropped, retry, failed, bluetoothOff, streamingLost, streamingResumed
}
public struct LinkEvent: Codable, Sendable, Equatable { let at: Date; let kind: LinkEventKind; let detail: String? }

public enum Freshness: Sendable { case live, stale, silent, never }
public enum LinkHealth {
    static func freshness(lastHeard: Date?, now: Date) -> Freshness   // 3 s / 10 s thresholds
}
```

The thresholds are constants in one place. `streamingTimeout` (3 s) in `CairnBLEManager` should use the same constant so the UI and the manager never disagree.

**SessionState additions**

- `lastQualityAt`, `lastWriteAt` (last successful `.sent`), `connectedSince`
- `nextRetryAt: Date?`, `failureStreak: Int`
- `linkEvents: [LinkEvent]` (capped, about 200)
- `dropCount` for the current arm session

`resetDeviceState()` stops clearing values. It marks them stale instead. `resetAll()` (user disarm) still clears everything.

**Writers.** Only `CairnBLEManager` and `DrivingSession` write these. Add one helper, `state.record(.dropped, detail:)`, called next to the existing `trace(...)` calls so the in-app timeline and `DriveLog` stay in step. Do not add a second logging path.

**Views.** Everything time-based goes through one `TimelineView(.periodic(by: 1))` wrapper so ages tick without extra state. `StatusCard` gets the countdown and the timeline strip. Each data card gets a `FreshnessBadge` in its header. Stage text changes:

- `ready` and silent: `Connected, no data` (replaces `Bonded`)
- `connecting` with `nextRetryAt`: `Reconnecting in N s`

**Tests (CairnCoreTests)**

- `Freshness` boundaries at 3 s and 10 s, and `never`
- `LinkEvent` cap and ordering
- Stage-text mapping if it moves into CairnCore

**Demo mode.** Add `CAIRN_DEMO=dropped` and `silent` so the new states can be screenshot for the README.

## Part 2: History tab

### What "history" means here

Two different things are being called history:

1. **Local drive history.** What the phone knows: link up/down periods, sent and accepted counts, link events, optionally a breadcrumb track. Available now, offline.
2. **Trip history from cairn-tsdb over LAN.** The dongle-side record. This is roadmap Phase 3 and depends on firmware and a home server.

Build (1) now with a model that (2) can later merge into. `docs/ios-app.md` currently lists trip history as a non-goal, so that line must be updated.

### Drives the server has not consumed yet

The History tab also shows drives the server (`cairn-tsdb`) has not consumed. After engine off the dongle disconnects BLE and syncs bundles over WiFi (`HANDOFF-FIRMWARE.md`: "instant (no bundles pending)" otherwise). A drive is therefore in one of three states:

| State | Meaning | Where it shows |
|-------|---------|----------------|
| `onDongle` | Recorded by the phone, dongle has not finished syncing it | "Waiting to sync" badge |
| `uploaded` | Dongle synced it, server has not ingested it yet | "Uploaded, processing" badge |
| `consumed` | Server has it | no badge, trip stats can be merged in |

The app cannot know this today. Two sources, and the plan needs a decision on which:

1. **Dongle reports pending bundles over BLE.** The Phase 2 `DEVICE_STATUS` characteristic (`0021`, 12 B) is not implemented. Ask firmware to include `pending_bundle_count` and `oldest_pending_age_s`. Cheap and works away from home, but gives counts only, not per-drive identity.
2. **App asks the server over LAN.** `GET` the trip list from `cairn-tsdb`, match by time overlap with local `DriveRecord`s. Gives per-drive state and later the merged trip stats, but only works on the home network. This is the roadmap Phase 3 item.

Recommended: model `serverState` on `DriveRecord` now (default `unknown`), show a **pending count** banner from source 1 as soon as firmware exposes it, and add source 2 for per-drive status in Phase 3. Until either exists every drive shows `unknown`, and the UI should not claim "not synced".

New firmware ask for `HANDOFF-FIRMWARE.md`: `DEVICE_STATUS` carries `pending_bundle_count` and `oldest_pending_age_s`, and a wifi-sync-in-progress flag so the "reconnecting" UI can say "dongle is syncing" instead of counting down retries.

### Defining a "drive"

`beginDriving` and `endDriving` fire on every reconnect, so one real drive would become many records. Rule:

- A drive **starts** on the first `ready` after arming (or after a gap).
- A drive **ends** when the user disarms, or when the link has been down longer than a gap threshold (proposal: 10 min).
- Drops shorter than the gap stay inside the drive and are recorded as `LinkEvent`s.

This rule lives in a pure `DriveSegmenter` in CairnCore so it can be unit tested.

### Data model (CairnCore)

```swift
public struct DriveRecord: Codable, Identifiable, Sendable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date?          // nil while in progress or after a crash
    var sent, dropped, accepted, rejected, queueDrops: Int
    var reconnects: Int
    var streamingSeconds: TimeInterval
    var events: [LinkEvent]
    var track: [TrackPoint]?    // optional, decimated
    var endReason: EndReason    // disarmed, linkGap, appTerminated, failed
}
```

### Persistence

Recommend **Codable JSON, one file per drive** under Application Support, plus a small index. Reasons:

- `CairnCore` stays free of frameworks and testable with `swift test` on macOS. SwiftData `@Model` under Swift 6 strict concurrency in a SwiftPM package is more friction than this data volume justifies.
- It matches how `DriveLog` already works.
- Volume is small: a drive is a few KB without a track.

A `DriveStore` protocol in CairnCore, with a file-backed implementation in CairnRuntime and an in-memory one for tests.

**Crash safety.** The app is killed by the system routinely (background, state restoration). So the recorder writes a snapshot every 30 s, reusing the existing `logSummary` cadence, and on launch closes any record with `endedAt == nil` using `endReason = .appTerminated` and the last snapshot time.

### Recorder (CairnRuntime)

`DriveRecorder` observes the same hooks as the log (`onReady`, `onLinkLost`, disarm, counters) and feeds `DriveSegmenter`. It does not poll `SessionState` independently. Better: both the UI timeline and the recorder consume the single `LinkEvent` stream from Part 1, so Part 1 is a prerequisite.

### Navigation and UI

- Wrap the app in a `TabView`: **Live** (current `MainView`), **History**, and optionally **Diagnostics** (share `cairn-drive.log`, firmware/protocol version, forget dongle).
- **History list.** Row: date, duration, streaming percentage, drop count. Empty state follows the existing `Placeholder` style. Swipe to delete.
- **Drive detail** (push in a `NavigationStack`):
  - Summary tiles (`Metric` grid): duration, streamed %, sent, accepted, rejected, dropped, reconnects
  - Link timeline: the `LinkEvent` list, plus a horizontal bar of connected, reconnecting and silent spans
  - Map with the track polyline, only if the track option is on
  - Share/export JSON
- Extract `Card`, `Metric`, `MetricGrid`, `Tone`, `Placeholder`, `Backdrop` and the surface colours out of `MainView.swift` into `Views/Components.swift` and make them `internal`. They are `private` today.

### Decisions needed

1. **Store a location track?** It is the most useful part of a drive detail and also the most sensitive data the app would keep. Options: no track; track on-device only with a toggle (default off); track always. Recommend a toggle, default off, with a retention limit.
2. **Retention.** Keep last N drives (proposal: 100) or last N days.
3. **Gap threshold** for ending a drive: 10 min proposed.
4. **Diagnostics tab** in this change or later.

## Phasing

| Step | Scope | Depends on |
|------|-------|-----------|
| 1 | `LinkEvent`, `Freshness`, `SessionState` fields, writers in BLE manager, tests | none |
| 2 | Health UI (ideas 1 to 5), demo states, README screenshots | 1 |
| 3 | `TabView` shell, extract shared components, empty History tab | none (can run parallel with 1) |
| 4 | `DriveSegmenter`, `DriveRecord`, `DriveStore`, `DriveRecorder`, crash-recovery, tests | 1 |
| 5 | History list and Drive detail UI | 3, 4 |
| 6 | Optional track and map, retention, export | 5, decision 1 |
| 7 | Docs: `ios-app.md` (non-goal and stale layout section), the README's Status table, `validation.md` rows for drop/recover and crash recovery | all |

## Risks

- **Background execution.** The recorder must not do work that relies on the app being foregrounded. Snapshot writes are cheap and run on the existing 30 s timer, which only fires while location keeps the app alive.
- **Main-actor load.** `linkEvents` is capped and ages are derived in `TimelineView`, so no per-second state mutation.
- **Two sources of truth.** If the in-app timeline and `DriveLog` diverge, debugging gets harder. One `record(...)` call feeds both.
- **Uncommitted work.** The tree has uncommitted changes in `CairnBLEManager.swift`, `DrivingSession.swift`, `CairnCompanionApp.swift` and `Info.plist`, plus untracked `DriveLog.swift`, `ReconnectPolicy.swift` and `DriveLogTests.swift`. Step 1 edits the first two, so commit or stash that work first.
