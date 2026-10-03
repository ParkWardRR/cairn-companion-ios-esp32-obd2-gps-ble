#if DEBUG
import CairnCore
import CairnRuntime
import Foundation

/// Seeds `SessionState` with a canned scenario so the UI can be screenshotted in the simulator,
/// which has no BLE. Enabled by `CAIRN_DEMO=streaming|waiting|syncing|failed` in the launch environment.
@MainActor
enum DemoMode {
    static var scenario: String? { ProcessInfo.processInfo.environment["CAIRN_DEMO"] }

    /// `CAIRN_DEMO_SCALE=0.85` shrinks the UI so a long page fits one screenshot.
    static var scale: Double? { ProcessInfo.processInfo.environment["CAIRN_DEMO_SCALE"].flatMap(Double.init) }

    static func apply(_ scenario: String, to state: SessionState) {
        state.isArmed = true
        switch scenario {
        case "waiting":
            state.connection = .scanning
        case "syncing":
            // Dongle dropped BLE for its post-trip WiFi sync; the pending connect resumes when it advertises.
            state.connection = .connecting
        case "failed":
            state.connection = .failed("Unsupported protocol v2")
        default:
            stream(to: state)
        }
    }

    private static func stream(to state: SessionState) {
        state.connection = .ready
        state.isDriving = true
        state.isStreaming = true
        state.deviceQuality = PayloadDecoder.gnssQuality(Data([2, 9, 0x8F, 0x00, 0, 0, 0, 0])) // 3D, 9 sats, HDOP 1.43
        state.companionStatus = PayloadDecoder.companionStatus(Data([0x2B, 0x01, 0x2C, 0x01, 0, 0, 0, 0]))
        state.sentCount = 300
        Task { @MainActor in
            var tick = 0.0
            while !Task.isCancelled {
                state.phoneFix = PhoneGNSSFix(
                    latitude: 37.3349, longitude: -122.0090, ellipsoidalAltitude: 28,
                    horizontalAccuracy: 5, verticalAccuracy: 8,
                    speed: 24.6 + sin(tick) * 0.4, course: 92, timestamp: Date().addingTimeInterval(-0.2)
                )
                tick += 0.5
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
#endif
