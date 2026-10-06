import CairnCore
import Foundation
import GRDB

public final class GRDBSyncStateStore: SyncStateStore, Sendable {
    private let db: CairnDatabase
    private static let stateID = "global"

    public init(db: CairnDatabase) {
        self.db = db
    }

    public func load() async throws -> SyncCursor? {
        try await db.dbPool.read { dbConn in
            guard let row = try Row.fetchOne(dbConn, sql: """
                SELECT serverInstance, cursor, lastSuccessAt FROM syncState WHERE id = ?
            """, arguments: [Self.stateID]) else { return nil }

            let instanceID: String = row["serverInstance"]
            let cursor: String? = row["cursor"]
            let lastSuccess: Date? = row["lastSuccessAt"]
            return SyncCursor(instanceID: instanceID, cursor: cursor, lastSuccessAt: lastSuccess)
        }
    }

    public func save(_ cursor: SyncCursor) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR REPLACE INTO syncState (id, serverInstance, cursor, lastSuccessAt, retryCount)
                VALUES (?, ?, ?, ?, 0)
            """, arguments: [
                Self.stateID,
                cursor.instanceID,
                cursor.cursor,
                cursor.lastSuccessAt,
            ])
        }
    }

    public func clear() async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM syncState WHERE id = ?", arguments: [Self.stateID])
        }
    }
}
