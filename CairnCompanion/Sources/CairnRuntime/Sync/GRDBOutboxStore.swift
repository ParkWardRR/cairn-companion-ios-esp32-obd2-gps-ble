import CairnCore
import CryptoKit
import Foundation
import GRDB

public final class GRDBOutboxStore: OutboxStore, Sendable {
    private let db: CairnDatabase

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(db: CairnDatabase) {
        self.db = db
    }

    public func enqueue(_ operation: SyncOperation) async throws {
        let json = try encoder.encode(operation)
        let encrypted = try StoreEncryption.encrypt(json, using: db.encryptionKey)

        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR IGNORE INTO outbox (id, vehicleID, kind, encryptedPayload, createdAt, attempts)
                VALUES (?, ?, ?, ?, ?, 0)
            """, arguments: [
                operation.operationID,
                operation.vehicleID,
                operation.kind,
                encrypted,
                Date(),
            ])
        }
    }

    public func pending(limit: Int) async throws -> [SyncOperation] {
        try await db.dbPool.read { [decoder, db] dbConn in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT encryptedPayload FROM outbox
                ORDER BY createdAt ASC LIMIT ?
            """, arguments: [limit])
            return rows.compactMap { row -> SyncOperation? in
                guard let blob: Data = row["encryptedPayload"],
                      let json = try? StoreEncryption.decrypt(blob, using: db.encryptionKey) else { return nil }
                return try? decoder.decode(SyncOperation.self, from: json)
            }
        }
    }

    public func markDone(_ operationIDs: Set<String>) async throws {
        guard !operationIDs.isEmpty else { return }
        try await db.dbPool.write { dbConn in
            let placeholders = operationIDs.map { _ in "?" }.joined(separator: ",")
            try dbConn.execute(
                sql: "DELETE FROM outbox WHERE id IN (\(placeholders))",
                arguments: StatementArguments(Array(operationIDs))
            )
        }
    }

    public func markFailed(_ operationID: String, error: String) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE outbox SET attempts = attempts + 1, lastAttemptAt = ?, lastError = ?
                WHERE id = ?
            """, arguments: [Date(), error, operationID])
        }
    }

    public func pendingCount() async throws -> Int {
        try await db.dbPool.read { dbConn in
            try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM outbox") ?? 0
        }
    }

    public func clear() async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM outbox")
        }
    }
}
