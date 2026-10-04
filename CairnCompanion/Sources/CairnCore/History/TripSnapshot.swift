import Foundation

/// A trip record from the server's `cairn-tsdb`. This is the dongle's authoritative view of a trip,
/// as opposed to `DriveSession` which is what the phone observed.
public struct TripSnapshot: Codable, Identifiable, Sendable, Equatable {
    /// boot_id from the dongle — one power cycle = one trip.
    public let id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: TimeInterval

    public var maxSpeedKph: Int?
    public var maxRpm: Int?
    public var obdSamples: Int
    public var gnssSamples: Int
    public var fixSamples: Int
    public var phoneSamples: Int
    public var gapCount: Int
    public var gapDurationMs: Int
    public var warnings: String?

    public var startLat: Double?
    public var startLon: Double?

    /// When this snapshot was exported by the server.
    public var snapshotAt: Date

    public init(
        id: String, startedAt: Date, endedAt: Date? = nil,
        durationSeconds: TimeInterval,
        maxSpeedKph: Int? = nil, maxRpm: Int? = nil,
        obdSamples: Int = 0, gnssSamples: Int = 0,
        fixSamples: Int = 0, phoneSamples: Int = 0,
        gapCount: Int = 0, gapDurationMs: Int = 0,
        warnings: String? = nil,
        startLat: Double? = nil, startLon: Double? = nil,
        snapshotAt: Date = Date()
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.maxSpeedKph = maxSpeedKph
        self.maxRpm = maxRpm
        self.obdSamples = obdSamples
        self.gnssSamples = gnssSamples
        self.fixSamples = fixSamples
        self.phoneSamples = phoneSamples
        self.gapCount = gapCount
        self.gapDurationMs = gapDurationMs
        self.warnings = warnings
        self.startLat = startLat
        self.startLon = startLon
        self.snapshotAt = snapshotAt
    }

    public var gnssGapSeconds: TimeInterval {
        Double(gapDurationMs) / 1000.0
    }

    public var hasLocation: Bool {
        startLat != nil && startLon != nil
    }
}

/// Combined view for the History tab: a phone-observed session optionally matched with a server trip.
public struct HistoryEntry: Identifiable, Sendable {
    public let id: String
    public var phoneSession: DriveSession?
    public var serverTrip: TripSnapshot?

    public init(phoneSession: DriveSession? = nil, serverTrip: TripSnapshot? = nil) {
        if let s = phoneSession { self.id = s.id.uuidString }
        else if let t = serverTrip { self.id = t.id }
        else { self.id = UUID().uuidString }
        self.phoneSession = phoneSession
        self.serverTrip = serverTrip
    }

    public var startedAt: Date {
        phoneSession?.startedAt ?? serverTrip?.startedAt ?? .distantPast
    }

    public var isOnPhoneOnly: Bool { phoneSession != nil && serverTrip == nil }
    public var isOnServerOnly: Bool { phoneSession == nil && serverTrip != nil }
    public var isMatched: Bool { phoneSession != nil && serverTrip != nil }

    public var syncLabel: String? {
        if serverTrip != nil { return nil }
        if let session = phoneSession {
            switch session.serverState {
            case .unknown: return nil
            case .pendingSync: return "Waiting to sync"
            case .uploaded: return "Uploaded, processing"
            case .consumed: return nil
            }
        }
        return nil
    }
}
