# Cairn on CarPlay

A read-only **Driving Task** screen: is the dongle connected, is location working, is it actually
recording — answered at a glance, and answered honestly when the link is down.

Visual design: [`carplay-hud.mockup.html`](carplay-hud.mockup.html).

## What the driver sees

Three tabs, each a `CPListTemplate` inside a `CPTabBarTemplate`. The first is self-sufficient, so the
driver never has to switch while moving.

| Tab | Rows |
|---|---|
| **Now** | keystone hero · engine gauge strip · fix acceptance · phone fix quality |
| **Trip** | trip hero · accepted · rejected · dongle queue drops · link drops |
| **Device** | health hero · supply voltage · card space · firmware · identity and uptime |

There are no buttons. CarPlay cannot arm, disarm, pause, or stop anything — the coordinator is handed
`SessionState` and never `DrivingSession`, so there is no method it could call to try.

## Why it is drawn the way it is

A driving-task app may not draw its own views; the system renders Apple's templates and picks the text
colours. **The only pixels Cairn controls are the `UIImage`s inside list rows.** Everything expressive
in this screen therefore lives in a Core Graphics glyph:

- **The keystone** — Cairn's mark is a stack of stones, so the dongle's four `DeviceStatus.Health` bits
  are drawn as four stones (bottom to top: SD, IMU, GNSS, OBD). Filled is good, hollow red is a fault,
  dashed means never reported.
- **The gauge ring** — a 270° arc with the value drawn in the middle. The value goes *inside the image*
  rather than in `CPListImageRowItem.imageTitles`, because `update(_:)` is documented to replace images
  in place while nothing documents live label mutation. The static metric name (`RPM`, `COOLANT`) is
  the title, set once.

## Surviving an unstable link

This is the part that shaped the architecture.

**The row set is built once and never rebuilt.** Every row is created when the head unit connects and is
then only rewritten with `setText`, `setDetailText`, `setImage` and `CPListImageRowItem.update`.
`updateSections` is never called in steady state, so a Bluetooth dropout cannot reload the list,
collapse a section, or move a row out from under the driver's eye.

**Nothing is ever blanked.** A reading the dongle has stopped sending keeps its value and its needle and
fades through `LinkHealth.freshness`:

| Freshness | Age | Drawn at |
|---|---|---|
| `live` | < 3 s | 100 % |
| `stale` | 3–10 s | 62 % |
| `silent` | > 10 s | 32 %, and the hero names the age |
| `never` | no reading ever | empty dashed track — *not* a needle at zero |

**One 1 Hz ticker, not BLE callbacks.** It matches the dongle's notify rate, bounds how often `setImage`
can be called, and — the real reason — keeps ages counting up while no data is arriving at all, which is
exactly when the driver needs to see them.

**Images are cached by what actually changes their pixels.** `setImage` called repeatedly is known to
hang the main thread, so needles quantise to 48 buckets and glyphs are cached on
`(bucket, band, freshness, caption)`. A needle that has not moved a whole bucket costs one dictionary
lookup and no drawing. Each glyph is rendered light *and* dark into one `UIImageAsset`, so dusk costs
nothing either.

**The tile set is frozen and remembered.** Which gauges appear is chosen from the PIDs the car actually
answers and stored in `UserDefaults`, so a naturally-aspirated car never grows a boost tile and no tile
ever moves position. The one time the list is allowed to reload is the first ever connection, if the
car turns out to answer a different set than the default guess.

## Honest status

"BLE connected" is not "recording". The headline only says **Recording** when the dongle itself reported
`tripPhase == .driving` *and* that report is still fresh. Everything else is hedged and dated — see the
table in the mockup, and `HUDTests.swift`, which pins every one of these strings.

## Where the code is

| Path | What |
|---|---|
| `Sources/CairnCore/CarPlay/HUDModel.swift` | Display model: gauges, rows, decks, image keys |
| `Sources/CairnCore/CarPlay/HUDBuilder.swift` | All wording, banding and unit logic. Pure, fully tested |
| `Sources/CairnRuntime/CarPlay/HUDGlyphs.swift` | Core Graphics renderer and image cache |
| `Sources/CairnRuntime/CarPlay/CarPlayHUDCoordinator.swift` | Templates, the fixed skeleton, in-place updates |
| `Sources/CairnRuntime/CarPlay/CairnCarPlayLink.swift` | Handoff from the app's object graph; `SessionState` → `HUDInput` |
| `App/CarPlaySceneDelegate.swift` | Scene entry point. Lives in the app target so the linker cannot drop it |
| `Tests/CairnCoreTests/HUDTests.swift` | 25 tests over the above |

The scene delegate is in the **app target** on purpose: UIKit builds it by name from `Info.plist`, so no
Swift code references it, and a static library's object file that nothing references can be dropped by
the linker.

## Enabling it

The entitlement is declared in `project.yml` and generated into `App/CairnCompanion.entitlements`:

```xml
<key>com.apple.developer.carplay-driving-task</key>
<true/>
```

**Done for development as of 2026-10-08.** Apple assigned the Driving Task entitlement to the
account, the capability is enabled on the `app.cairn.companion` App ID, and the development profile
carries it. A device build signs, installs and runs with the entitlement embedded:

```
$ codesign -d --entitlements :- CairnCompanion.app
  "application-identifier" => "6U62M4232W.app.cairn.companion"
  "com.apple.developer.carplay-driving-task" => true
```

If it ever needs redoing — a new App ID, or a profile that has lost the capability — a device build
with `xcodebuild -allowProvisioningUpdates` enables it and regenerates the profile, or do it by hand
at [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
→ the App ID → Additional Capabilities → **CarPlay Driving Task App**.

**Distribution is done too**, verified on 2026-10-08 by exporting an `app-store-connect` build and
reading the entitlement back out of the shipped binary:

```
Authority=Apple Distribution: Twesh Deshetty (6U62M4232W)
  "com.apple.developer.carplay-driving-task" => true
  "get-task-allow" => false
```

Worth knowing if this ever needs redoing: **`xcodebuild archive` alone is not enough.** It signs with
the *development* profile, so the archive proves nothing about distribution. The store profile is only
resolved at `-exportArchive`:

```bash
xcodebuild archive -scheme CairnCompanion -destination 'generic/platform=iOS' \
  -archivePath <path>.xcarchive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath <path>.xcarchive -exportPath <dir> \
  -exportOptionsPlist <opts> -allowProvisioningUpdates
```

Use a copy of `ExportOptions.plist` with `destination` set to `export` rather than `upload` unless
you actually mean to ship to App Store Connect. Xcode signs this with a *cloud-managed* distribution
certificate, so no distribution private key is created on the machine.

Simulator builds never carry it: iOS strips the entitlement for the simulator. The CarPlay scene
still connects there, so the simulator remains the right place to check layout.

## Testing it

| Where | What it proves |
|---|---|
| `swift test` | Every wording, band, freshness and row-skeleton rule, without a car |
| Xcode → Simulator → I/O → External Displays → CarPlay | Scene registration, template layout, state transitions |
| CarPlay Simulator (Additional Tools for Xcode) + a real iPhone | The same, but against the real BLE and location stack |
| The car | Reconnect behaviour, locked-phone operation, vehicle list limits |

`CAIRN_DEMO=streaming|silent|dropped` seeds `SessionState` without a dongle, which drives the CarPlay
screen as well as the phone's — `silent` and `dropped` are the two worth looking at here.

Acceptance check: connect with Cairn not already open, confirm the car screen shows honest
accessory/location/recording status, lock the phone, then disconnect and reconnect CarPlay and verify
that showing or closing the screen did not start or stop the logger.
