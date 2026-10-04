import Foundation

public struct SnapshotManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var builtAt: Date
    public var decoderVersion: Int
    public var bundleCount: Int
    public var rowCounts: [String: Int]
    public var tables: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case builtAt = "built_at"
        case decoderVersion = "decoder_version"
        case bundleCount = "bundle_count"
        case rowCounts = "row_counts"
        case tables
    }

    public static let supportedSchemaVersion = 1

    public var isSupported: Bool { schemaVersion == Self.supportedSchemaVersion }

    public var totalRows: Int { rowCounts.values.reduce(0, +) }

    public var tripCount: Int { rowCounts["drive_summary"] ?? 0 }

    public static func decode(from data: Data) throws -> SnapshotManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SnapshotManifest.self, from: data)
    }
}
