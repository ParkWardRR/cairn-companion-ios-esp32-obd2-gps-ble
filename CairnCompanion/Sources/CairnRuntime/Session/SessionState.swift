import CairnCore
import Foundation
import Observation

/// Everything the single Phase 1 screen shows. Written by `CairnBLEManager` and `DrivingSession`.
@MainActor @Observable
public final class SessionState {
    public enum Connection: Equatable, Sendable {
        case idle
        case bluetoothUnavailable(String)
        case scanning
        case connecting
        /// Link up; discovering services and reading `PROTOCOL_VERSION`, which triggers passkey bonding.
        case bonding
        case ready
        case failed(String)
    }

    /// Auto-connect is on: the app is waiting for, or connected to, the Cairn dongle.
    public var isArmed = false
    /// The dongle link is up and location is streaming to it. Starts and stops with the link.
    public var isDriving = false
    public var connection: Connection = .idle
    /// True only while the device recently acknowledged acceptance via `COMPANION_STATUS`,
    /// not merely because the phone called `write`.
    public var isStreaming = false

    public var locationMessage: String?
    public var phoneFix: PhoneGNSSFix?
    public var lastSent: GNSSFixPayload?

    public var deviceQuality: GNSSQuality?
    public var companionStatus: CompanionStatus?
    public var lastStatusAt: Date?

    public var sentCount = 0
    /// Fixes dropped before the wire: stale, or BLE write backpressure.
    public var droppedCount = 0

    public init() {}

    public var stage: String {
        switch connection {
        case .idle: "Off"
        case .bluetoothUnavailable(let why): why
        case .scanning: "Waiting for Cairn"
        case .connecting: "Connecting"
        case .bonding: "Bonding"
        case .ready: isStreaming ? "Streaming" : "Bonded"
        case .failed(let why): why
        }
    }

    func resetDeviceState() {
        isStreaming = false
        deviceQuality = nil
        companionStatus = nil
        lastStatusAt = nil
    }

    func resetAll() {
        connection = .idle
        resetDeviceState()
        locationMessage = nil
        phoneFix = nil
        lastSent = nil
        sentCount = 0
        droppedCount = 0
    }
}
