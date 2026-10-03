import CairnCore
import CoreLocation

public enum LocationEvent: Sendable {
    case fix(PhoneGNSSFix)
    case unavailable(String)
}

/// Wraps `CLLocationUpdate.liveUpdates(.automotiveNavigation)`. Cadence is system-managed;
/// do not mix with `CLLocationManager`-style `desiredAccuracy`.
public enum LocationStream {
    public static func events() -> AsyncStream<LocationEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                        if let location = update.location {
                            continuation.yield(.fix(PhoneGNSSFix(location)))
                        } else if let reason = unavailableReason(update) {
                            continuation.yield(.unavailable(reason))
                        }
                    }
                } catch {
                    continuation.yield(.unavailable("Location stopped: \(error.localizedDescription)"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The reason flags exist from iOS 18; on iOS 17 an update without a location is just skipped.
    private static func unavailableReason(_ update: CLLocationUpdate) -> String? {
        guard #available(iOS 18, macOS 15, *) else { return nil }
        if update.authorizationDenied || update.authorizationDeniedGlobally { return "Location permission denied" }
        if update.locationUnavailable { return "Location unavailable" }
        return nil
    }
}
