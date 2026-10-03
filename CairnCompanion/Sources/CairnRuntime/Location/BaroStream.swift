import CairnCore
import Foundation

#if os(iOS)
import CoreMotion

/// Relative altitude from the barometer via `CMAltimeter`. Relative to when updates started, not MSL.
/// Updates arrive around 1 Hz; nothing is emitted when the device has no barometer.
public enum BaroStream {
    /// `CMAltimeter` is not `Sendable`; start and stop are the only calls and are safe from any thread.
    private final class Box: @unchecked Sendable {
        let altimeter = CMAltimeter()
    }

    public static var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    public static func readings() -> AsyncStream<BaroAltPayload> {
        AsyncStream { continuation in
            guard isAvailable else {
                continuation.finish()
                return
            }
            let box = Box()
            box.altimeter.startRelativeAltitudeUpdates(to: .main) { data, _ in
                guard let data else { return }
                continuation.yield(BaroAltPayload(relativeAltitudeMetres: data.relativeAltitude.doubleValue))
            }
            continuation.onTermination = { _ in box.altimeter.stopRelativeAltitudeUpdates() }
        }
    }
}
#else
public enum BaroStream {
    public static var isAvailable: Bool { false }
    public static func readings() -> AsyncStream<BaroAltPayload> { AsyncStream { $0.finish() } }
}
#endif
