import CairnCore
import DuckDB
import Foundation
import os

actor SnapshotStore {
    private static let log = Logger(subsystem: "app.cairn.companion", category: "store")
    private var database: Database?
    private var connection: Connection?

    func load(parquetDir: URL, tables: [String]) throws {
        let db = try Database(store: .inMemory)
        let conn = try db.connect()

        for table in tables {
            let path = parquetDir.appendingPathComponent("\(table).parquet").path
            guard FileManager.default.fileExists(atPath: path) else {
                Self.log.warning("parquet file missing: \(table)")
                continue
            }
            try conn.execute("""
                CREATE TABLE \(table) AS SELECT * FROM read_parquet('\(path)')
            """)
        }

        self.database = db
        self.connection = conn
        Self.log.notice("loaded \(tables.count) tables from snapshot")
    }

    func trips() throws -> [TripSnapshot] {
        guard let conn = connection else { return [] }

        let hasDriveSummary = (try? conn.query("SELECT 1 FROM drive_summary LIMIT 1")) != nil
        guard hasDriveSummary else { return [] }

        let hasPosition = (try? conn.query("SELECT 1 FROM position LIMIT 1")) != nil

        let sql: String
        if hasPosition {
            sql = """
                SELECT
                    d.boot_id,
                    d.duration_s,
                    d.max_speed_kph,
                    d.max_rpm,
                    d.obd_samples,
                    d.gnss_samples,
                    d.fix_samples,
                    d.phone_samples,
                    d.gap_count,
                    d.gap_duration_ms,
                    d.warnings,
                    p.observed_at,
                    p.lat,
                    p.lon
                FROM drive_summary d
                LEFT JOIN (
                    SELECT boot_id, observed_at, lat, lon
                    FROM (
                        SELECT *, row_number() OVER (
                            PARTITION BY boot_id ORDER BY mono_ms
                        ) AS rn
                        FROM position
                        WHERE coalesce(source_flags, 0) & 32 = 0
                    )
                    WHERE rn = 1
                ) p USING (boot_id)
                ORDER BY p.observed_at DESC NULLS LAST
            """
        } else {
            sql = """
                SELECT
                    boot_id,
                    duration_s,
                    max_speed_kph,
                    max_rpm,
                    obd_samples,
                    gnss_samples,
                    fix_samples,
                    phone_samples,
                    gap_count,
                    gap_duration_ms,
                    warnings,
                    NULL::TIMESTAMP AS observed_at,
                    NULL::DOUBLE AS lat,
                    NULL::DOUBLE AS lon
                FROM drive_summary
            """
        }

        let result = try conn.query(sql)
        var snapshots: [TripSnapshot] = []

        for i: DBInt in 0..<result.rowCount {
            guard let bootId = strVal(result, col: 0, row: i) else { continue }
            let durationS = dblVal(result, col: 1, row: i) ?? 0

            let startDate: Foundation.Date
            if let ts = tsVal(result, col: 11, row: i) {
                startDate = ts
            } else {
                startDate = .distantPast
            }

            snapshots.append(TripSnapshot(
                id: bootId,
                startedAt: startDate,
                endedAt: startDate.addingTimeInterval(durationS),
                durationSeconds: durationS,
                maxSpeedKph: i16Val(result, col: 2, row: i),
                maxRpm: i16Val(result, col: 3, row: i),
                obdSamples: i64Val(result, col: 4, row: i) ?? 0,
                gnssSamples: i64Val(result, col: 5, row: i) ?? 0,
                fixSamples: i64Val(result, col: 6, row: i) ?? 0,
                phoneSamples: i64Val(result, col: 7, row: i) ?? 0,
                gapCount: i64Val(result, col: 8, row: i) ?? 0,
                gapDurationMs: i64Val(result, col: 9, row: i) ?? 0,
                warnings: strVal(result, col: 10, row: i),
                startLat: dblVal(result, col: 12, row: i),
                startLon: dblVal(result, col: 13, row: i),
                snapshotAt: Foundation.Date()
            ))
        }
        return snapshots
    }

    func close() {
        connection = nil
        database = nil
    }

    // MARK: - Column helpers

    private nonisolated func strVal(_ r: ResultSet, col: Int, row: DBInt) -> String? {
        (try? r[DBInt(col)].cast(to: String.self)[row])
    }

    private nonisolated func dblVal(_ r: ResultSet, col: Int, row: DBInt) -> Double? {
        (try? r[DBInt(col)].cast(to: Double.self)[row])
    }

    private nonisolated func i16Val(_ r: ResultSet, col: Int, row: DBInt) -> Int? {
        guard let v = try? r[DBInt(col)].cast(to: Int16.self)[row] else { return nil }
        return Int(v)
    }

    private nonisolated func i64Val(_ r: ResultSet, col: Int, row: DBInt) -> Int? {
        guard let v = try? r[DBInt(col)].cast(to: Int64.self)[row] else { return nil }
        return Int(v)
    }

    private nonisolated func tsVal(_ r: ResultSet, col: Int, row: DBInt) -> Foundation.Date? {
        guard let ts = try? r[DBInt(col)].cast(to: Timestamp.self)[row] else { return nil }
        return Foundation.Date(timeIntervalSince1970: Double(ts.microseconds) / 1_000_000)
    }
}
