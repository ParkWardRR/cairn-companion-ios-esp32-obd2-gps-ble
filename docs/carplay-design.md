# CarPlay Design Note

## Summary

CarPlay requires a specific entitlement from Apple, and approval odds for a personal OBD logger are low. The recommended path is iOS widgets and Live Activities, which deliver the most useful information to the driver without any entitlement gate.

## CarPlay Entitlement

Apple restricts CarPlay to apps in approved categories: navigation, audio, messaging, VoIP, EV charging, fueling, parking, and quick food ordering. An OBD/GPS data logger does not fit any of these.

There is no "general purpose" or "diagnostics" CarPlay category. The `com.apple.developer.carplay-maps` (navigation) entitlement is the closest fit, but Apple reviews the entitlement request against the app's primary purpose. A dongle companion that shows live telemetry and trip logs would likely be rejected — it is not a turn-by-turn navigation app.

**Entitlement process**: Submit a request via the [CarPlay Entitlement Request Form](https://developer.apple.com/contact/carplay/). Apple reviews on a case-by-case basis with no published timeline. Rejection is final per submission, though resubmission with a changed app is possible.

**Recommendation**: Do not pursue the CarPlay entitlement. The approval odds are low for this app category, and the entitlement review can take months with no guarantee. The widget route achieves the same driver-facing goals without Apple's gatekeeping.

## Widget Route (Recommended)

iOS 18 widgets and Live Activities run on the Lock Screen and in StandBy mode (landscape on a car mount), which covers the CarPlay use case for a passenger-free data display.

### What widgets can show

| Widget | Size | Content |
|--------|------|---------|
| Dongle status | Small | Connection state (connected/scanning/off), streaming indicator |
| Last drive | Medium | Date, duration, distance, route thumbnail |
| Today's drives | Medium | Count of today's trips, total distance, total time |
| Live Activity | Dynamic Island + Lock Screen | Active drive: duration, connection state, fixes sent |

### Implementation sketch

- **Widget extension** target with `WidgetKit` and `ActivityKit`.
- Shared `AppGroup` container for the widget to read dongle state and recent drive data.
- `DrivingSession` writes connection state and drive stats to the shared container on each checkpoint.
- Live Activity starts when a drive begins (`ActivityKit.Activity.request`) and ends when the link drops.
- Timeline provider reloads on drive completion via `WidgetCenter.shared.reloadAllTimelines()`.

### Constraints

- Widgets cannot initiate Bluetooth connections — the main app must be running (which it already is during a drive via background modes).
- Live Activities are limited to 8 hours and require Dynamic Island on supported hardware.
- Widget content updates are budgeted by the system; real-time data requires a Live Activity.

## Decision

**Chosen route: widgets and Live Activities.** No CarPlay entitlement will be pursued. Implementation is planned after the core BLE offload and sync features are stable.
