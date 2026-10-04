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

    /// Last values from the device. Kept (and shown dimmed) when the link drops, and cleared when the
    /// next link becomes ready, because the dongle's counters restart on every connection.
    public var deviceQuality: GNSSQuality?
    public var companionStatus: CompanionStatus?
    public var lastQualityAt: Date?
    public var lastStatusAt: Date?

    /// Phase 2: live OBD telemetry and device health. Nil when the dongle doesn't expose them.
    public var obdLive: OBDLiveSnapshot?
    public var deviceStatus: DeviceStatus?
    public var lastOBDAt: Date?
    public var lastDeviceStatusAt: Date?
    /// The last accepted `GNSS_FIX` write.
    public var lastWriteAt: Date?

    /// When the current link became ready; nil while down.
    public var connectedSince: Date?
    /// When the next reconnect attempt fires; nil when none is scheduled.
    public var nextRetryAt: Date?
    /// Consecutive failed attempts of a link that did connect; 0 for a plain reconnect.
    public var retryAttempt = 0
    public private(set) var linkLog = LinkEventLog()

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
        case .ready:
            if isStreaming { "Streaming" } else if lastStatusAt == nil { "Bonded" } else { "Connected, no data" }
        case .failed(let why): why
        }
    }

    public func record(_ kind: LinkEventKind, _ detail: String? = nil, at date: Date = Date()) {
        linkLog.append(LinkEvent(at: date, kind: kind, detail: detail))
    }

    /// The link went away. Device readings stay visible as last-known; they are cleared when the next link is ready.
    func resetDeviceState() {
        isStreaming = false
        connectedSince = nil
    }

    /// A new link is ready, so readings from the previous one no longer describe the device.
    func clearDeviceReadings() {
        deviceQuality = nil
        companionStatus = nil
        lastQualityAt = nil
        lastStatusAt = nil
        lastWriteAt = nil
        obdLive = nil
        deviceStatus = nil
        lastOBDAt = nil
        lastDeviceStatusAt = nil
    }

    func resetAll() {
        connection = .idle
        resetDeviceState()
        clearDeviceReadings()
        nextRetryAt = nil
        retryAttempt = 0
        linkLog.removeAll()
        locationMessage = nil
        phoneFix = nil
        lastSent = nil
        sentCount = 0
        droppedCount = 0
    }

    /// Device readings describe a live link only while it is ready and the channel is still being heard.
    public func isLive(lastHeard: Date?, now: Date) -> Bool {
        connection == .ready && LinkHealth.freshness(lastHeard: lastHeard, now: now) != .silent
    }

    /// One line under the status title that says what the link is doing right now.
    public func linkDetail(now: Date) -> String? {
        switch connection {
        case .idle, .bluetoothUnavailable, .failed:
            return nil
        case .scanning, .connecting, .bonding:
            if let next = nextRetryAt, next > now {
                var text = "Reconnecting in \(Int(next.timeIntervalSince(now).rounded(.up))) s"
                if retryAttempt > 0 { text += " · attempt \(retryAttempt + 1) of \(ReconnectPolicy.maxConsecutiveFailures)" }
                return text
            }
            return linkLog.lastDrop.map { "Link lost \(LinkHealth.ageLabel(now.timeIntervalSince($0))) ago" }
        case .ready:
            if isStreaming { return connectedSince.map { "Connected for \(LinkHealth.ageLabel(now.timeIntervalSince($0)))" } }
            if let last = lastStatusAt { return "No data for \(LinkHealth.ageLabel(now.timeIntervalSince(last)))" }
            return "Waiting for first status"
        }
    }

    /// `2 drops · last 1 m 12 s ago`; nil until the link has dropped once.
    public func dropSummary(now: Date) -> String? {
        guard let last = linkLog.lastDrop else { return nil }
        let count = linkLog.dropCount
        return "\(count) \(count == 1 ? "drop" : "drops") · last \(LinkHealth.ageLabel(now.timeIntervalSince(last))) ago"
    }
}
