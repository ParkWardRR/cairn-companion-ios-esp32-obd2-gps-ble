#if DEBUG
import CairnCore
import CairnRuntime
import Foundation

/// Seeds `SessionState` with a canned scenario so the UI can be screenshotted in the simulator,
/// which has no BLE. Enabled by `CAIRN_DEMO=streaming|waiting|syncing|failed|staleBond|dropped|silent` in the launch environment.
@MainActor
enum DemoMode {
    static var scenario: String? { ProcessInfo.processInfo.environment["CAIRN_DEMO"] }

    /// `CAIRN_DEMO_SCALE=0.85` shrinks the UI so a long page fits one screenshot.
    static var scale: Double? { ProcessInfo.processInfo.environment["CAIRN_DEMO_SCALE"].flatMap(Double.init) }

    /// `CAIRN_DEMO_TRIPS=1` writes a few finished drives with tracks, so the Trips tab has something to show.
    static var seedsTrips: Bool { ProcessInfo.processInfo.environment["CAIRN_DEMO_TRIPS"] != nil }

    static func seedTrips(into store: any DriveStore) async {
        let now = Date()
        // (hours ago, minutes long, loop radius in degrees, bench?)
        let drives: [(Double, Double, Double, Bool)] = [(2, 24, 0.020, false), (5, 11, 0.008, false), (27, 52, 0.045, false), (30, 1, 0, true), (52, 33, 0.030, false)]
        for (hoursAgo, minutes, radius, bench) in drives {
            let start = now.addingTimeInterval(-hoursAgo * 3600)
            var s = DriveSession(startedAt: start)
            s.lifecycle = .closed
            s.closedAt = start.addingTimeInterval(minutes * 60)
            s.obdReceived = !bench
            s.deviceReportedDriving = !bench
            s.streamingSeconds = minutes * 60 * 0.97
            s.observedSeconds = minutes * 60
            let n = Int(minutes * 12)
            s.track = radius == 0 ? [] : (0..<n).map { i in
                let a = Double(i) / Double(n) * 2 * .pi
                // a lopsided loop, so each route has its own shape
                let lat = 37.35 + radius * sin(a) * (1 + 0.3 * cos(2 * a))
                let lon = -122.03 + radius * 1.4 * cos(a) * (1 + 0.2 * sin(3 * a))
                return TrackPoint(fix: PhoneGNSSFix(latitude: lat, longitude: lon, ellipsoidalAltitude: 30, horizontalAccuracy: 6, verticalAccuracy: 8, speed: 13 + 6 * sin(a * 2), course: 0, timestamp: start.addingTimeInterval(Double(i) * 5)))
            }
            try? await store.save(s)
        }
    }

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
        case "staleBond":
            state.connection = .failed("Stale pairing")
            state.record(.failed, "Stale pairing", at: Date().addingTimeInterval(-2))
        case "dropped":
            // Link lost after a stretch of streaming: last-known readings stay, dimmed, with a retry countdown.
            seedReadings(to: state, heardAgo: 38)
            state.record(.ready, at: Date().addingTimeInterval(-900))
            state.record(.dropped, "Bluetooth turned off", at: Date().addingTimeInterval(-300))
            state.record(.ready, at: Date().addingTimeInterval(-240))
            state.record(.dropped, "Peer disconnected", at: Date().addingTimeInterval(-38))
            state.connection = .connecting
            state.retryAttempt = 2
            state.nextRetryAt = Date().addingTimeInterval(7)
        case "silent":
            // Link up, but the dongle has stopped notifying.
            seedReadings(to: state, heardAgo: 24)
            state.connectedSince = Date().addingTimeInterval(-600)
            state.connection = .ready
            state.record(.ready, at: Date().addingTimeInterval(-600))
            state.record(.streamingLost, at: Date().addingTimeInterval(-21))
        default:
            stream(to: state)
        }
    }

    private static func seedReadings(to state: SessionState, heardAgo: TimeInterval) {
        state.deviceQuality = PayloadDecoder.gnssQuality(Data([2, 9, 0x8F, 0x00, 0, 0, 0, 0]))
        state.companionStatus = PayloadDecoder.companionStatus(Data([0x2B, 0x01, 0x2C, 0x01, 0, 0, 0, 0]))
        state.lastQualityAt = Date().addingTimeInterval(-heardAgo)
        state.lastStatusAt = Date().addingTimeInterval(-heardAgo)
        state.sentCount = 300
    }

    private static func stream(to state: SessionState) {
        state.connection = .ready
        state.isDriving = true
        state.isStreaming = true
        state.deviceQuality = PayloadDecoder.gnssQuality(Data([2, 9, 0x8F, 0x00, 0, 0, 0, 0])) // 3D, 9 sats, HDOP 1.43
        state.companionStatus = PayloadDecoder.companionStatus(Data([0x2B, 0x01, 0x2C, 0x01, 0, 0, 0, 0]))
        state.sentCount = 300
        state.lastQualityAt = Date()
        state.lastStatusAt = Date()
        state.connectedSince = Date().addingTimeInterval(-252)
        state.record(.ready, at: Date().addingTimeInterval(-252))
        state.record(.dropped, "Peer disconnected", at: Date().addingTimeInterval(-72))
        Task { @MainActor in
            var tick = 0.0
            while !Task.isCancelled {
                state.phoneFix = PhoneGNSSFix(
                    latitude: 37.3349, longitude: -122.0090, ellipsoidalAltitude: 28,
                    horizontalAccuracy: 5, verticalAccuracy: 8,
                    speed: 24.6 + sin(tick) * 0.4, course: 92, timestamp: Date().addingTimeInterval(-0.2)
                )
                state.lastQualityAt = Date() // keeps the freshness badges and health ring live
                state.lastStatusAt = Date()
                tick += 0.5
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
#endif
