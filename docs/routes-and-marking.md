# Routes, stretches and marking a drive

**A design, not a schedule.** The owner's brief of 2026-10-08, worked through. What is scheduled, and
in what order relative to everything else, is
[Phase 35](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/ROADMAP.md#phase-35--routes-stretches-and-marking-a-drive--planned-two-decisions-open)
of the project's single [roadmap](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/ROADMAP.md).

**Nothing here has started**, and two naming decisions need the owner's call before any code does.

Two halves that only pay off together: a **shape** for a drive that is
richer than one flat polyline, and a way to **mark something while driving** without looking at a
screen. The marks are what make the shapes worth having — an "I drove this road" record is only
interesting once you can say *this* part, and *that* felt wrong.

The model work lands server-side first; this repository consumes it.

## The model

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

## Depends on

- Server: route and stretch tables, the out-and-back / loop / one-way classifier, and stretch
  matching across drives so the same road recognises itself. Scheduled as
  [Phase 35](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/ROADMAP.md#phase-35--routes-stretches-and-marking-a-drive--planned-two-decisions-open)
  in the project's single roadmap, which already carries "bookmark, tag and search a route" under
  History.
- Contracts: new `store/v1` views for routes and stretches, and a `sync/v1` carrier for marks.
  Additive, so the pin bumps rather than breaks.
- Phase 3 track storage: a route cannot be classified without the track, and that row is still open.
- v3 #8 (annotations) for syncing marks off the phone. `Annotation` already has `targetID`, `kind`,
  `text` and `tags`, so a mark is a new `AnnotationKind` rather than a new store.

## Marking while driving — capture

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

## Marking while driving — voice

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

## Review, afterwards

- [ ] Trips tab: routes drawn with their shape named, stretches selectable within a route
- [ ] Marks on the route map and on the speed trace, tappable
- [ ] Named stretches as first-class objects: every run of the same stretch, compared
- [ ] Filter and search drives by mark kind and tag
- [ ] Export a marked clip

**Exit:** a drive can be marked by voice with the phone locked, and the mark is found afterwards on
the right stretch with the telemetry that was actually live at the time.
