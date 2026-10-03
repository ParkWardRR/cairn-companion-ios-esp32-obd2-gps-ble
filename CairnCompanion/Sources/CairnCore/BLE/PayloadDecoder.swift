import Foundation

/// `GNSS_QUALITY` notify: internal receiver state. Layout is proposed, not frozen (docs/ble-protocol.md).
public struct GNSSQuality: Sendable, Equatable {
    public static let size = 8

    public var fixType: UInt8
    public var satsUsed: UInt8
    public var hdopE2: UInt16
    public var fixAgeMs: UInt32

    /// HDOP in natural units, or nil when the receiver reports unknown (`0xFFFF`).
    public var hdop: Double? { hdopE2 == 0xFFFF ? nil : Double(hdopE2) / 100 }
}

/// `COMPANION_STATUS` notify: firmware acceptance feedback. Layout is proposed, not frozen.
public struct CompanionStatus: Sendable, Equatable {
    public static let size = 8

    public var lastAcceptedSeq: UInt16
    public var acceptedCount: UInt16
    public var rejectedCount: UInt16
    public var queueDropCount: UInt16
}

/// `PROTOCOL_VERSION` read: `u8 version` + `u8 capabilities`.
public struct ProtocolVersion: Sendable, Equatable {
    public static let size = 2

    public var version: UInt8
    public var capabilities: UInt8

    /// False for unknown major versions; the app must not stream in that case.
    public var isSupported: Bool { version == CairnGATTProfile.supportedMajorVersion }
}

/// Decoders validate length before reading. GATT gives boundaries, not guarantees.
public enum PayloadDecoder {
    public static func gnssQuality(_ data: Data) -> GNSSQuality? {
        guard data.count == GNSSQuality.size else { return nil }
        let d = Data(data)
        return GNSSQuality(fixType: d[0], satsUsed: d[1], hdopE2: d.readLE(at: 2), fixAgeMs: d.readLE(at: 4))
    }

    public static func companionStatus(_ data: Data) -> CompanionStatus? {
        guard data.count == CompanionStatus.size else { return nil }
        let d = Data(data)
        return CompanionStatus(
            lastAcceptedSeq: d.readLE(at: 0), acceptedCount: d.readLE(at: 2),
            rejectedCount: d.readLE(at: 4), queueDropCount: d.readLE(at: 6)
        )
    }

    public static func protocolVersion(_ data: Data) -> ProtocolVersion? {
        guard data.count == ProtocolVersion.size else { return nil }
        let d = Data(data)
        return ProtocolVersion(version: d[0], capabilities: d[1])
    }
}
