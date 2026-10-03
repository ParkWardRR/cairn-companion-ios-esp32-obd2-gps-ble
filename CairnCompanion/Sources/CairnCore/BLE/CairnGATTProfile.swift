import CoreBluetooth

/// GATT identifiers and sizes from docs/ble-protocol.md.
/// The 128-bit base is provisional until the spec lands in the firmware repo.
/// UUIDs are computed because `CBUUID` is not `Sendable`.
public enum CairnGATTProfile {
    public static let advertisedName = "Cairn"

    public static var serviceUUID: CBUUID { uuid(suffix: "0000") }

    public static var gnssFix: CBUUID { uuid(suffix: "0001") }
    public static var gnssQuality: CBUUID { uuid(suffix: "0010") }
    public static var companionStatus: CBUUID { uuid(suffix: "0011") }
    public static var protocolVersion: CBUUID { uuid(suffix: "00F0") }

    /// Phase 2 writes. Optional: the app uses them only if the dongle exposes them.
    public static var baroAlt: CBUUID { uuid(suffix: "0002") }
    public static var utcSync: CBUUID { uuid(suffix: "0003") }

    /// Minimum `maximumWriteValueLength(for: .withoutResponse)` needed to send a `GNSS_FIX`.
    public static var requiredWriteLength: Int { GNSSFixPayload.size }

    /// Protocol major version this build speaks. The app refuses to stream to any other.
    public static let supportedMajorVersion: UInt8 = 1

    private static func uuid(suffix: String) -> CBUUID {
        CBUUID(string: "A8E3\(suffix)-4F5B-11EF-A017-325096B39F47")
    }
}
