import CairnCore
import Foundation
import os

/// Downloads the snapshot archive from the Cairn server, decompresses and extracts it,
/// loads the Parquet files into an in-memory DuckDB, and provides trip data for the History tab.
///
/// The server URL is stored in UserDefaults so it can be set from Settings. No URL is hardcoded.
///
/// Sync triggers:
/// - Manual sync button in the History tab or Settings
/// - On app launch if the cached snapshot is stale
///
/// The snapshot is replaced atomically. If the download fails, the previous cache stays valid.
@MainActor
public final class TripSyncClient {
    private static let log = Logger(subsystem: "app.cairn.companion", category: "sync")
    private static let staleAfter: TimeInterval = 3600
    private static let serverURLKey = "cairn.tripSyncServerURL"
    private static let etagKey = "cairn.snapshotETag"
    private static let lastSyncKey = "cairn.lastSnapshotSync"
    private static let manifestKey = "cairn.snapshotManifest"

    public enum SyncState: Sendable, Equatable {
        case idle
        case syncing
        case failed(String)
    }

    public private(set) var state: SyncState = .idle
    public private(set) var lastSyncAt: Date?
    public private(set) var manifest: SnapshotManifest?

    private let store = SnapshotStore()
    private var cachedSnapshots: [TripSnapshot] = []

    private var snapshotDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("snapshot", isDirectory: true)
    }

    public init() {
        lastSyncAt = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        if let data = UserDefaults.standard.data(forKey: Self.manifestKey) {
            manifest = try? JSONDecoder().decode(SnapshotManifest.self, from: data)
        }
        Self.protectSnapshotDir(snapshotDir)
    }

    private static func protectSnapshotDir(_ dir: URL) {
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path
        )
        #endif
    }

    public var serverURL: String {
        get { UserDefaults.standard.string(forKey: Self.serverURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.serverURLKey) }
    }

    public var hasServer: Bool {
        !serverURL.isEmpty && URL(string: serverURL) != nil
    }

    /// Load cached Parquet files into DuckDB on launch. Runs off the main actor.
    public func loadCachedSnapshot() async {
        let dir = snapshotDir.appendingPathComponent("parquet", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        let tables = manifest?.tables ?? [
            "bundles", "position", "imu", "obd", "boost",
            "status", "transition", "gap", "drive_summary",
        ]

        do {
            try await store.load(parquetDir: dir, tables: tables)
            cachedSnapshots = try await store.trips()
            Self.log.notice("loaded \(self.cachedSnapshots.count) cached trips")
        } catch {
            Self.log.error("failed to load cached snapshot: \(error)")
        }
    }

    /// Trip snapshots from the last loaded snapshot.
    public func cachedTrips() -> [TripSnapshot] {
        cachedSnapshots
    }

    /// Trigger a sync. Downloads the snapshot archive, decompresses, and loads into DuckDB.
    public func sync() {
        guard state != .syncing else { return }
        guard let base = URL(string: serverURL), !serverURL.isEmpty else {
            state = .failed("No server configured")
            return
        }
        state = .syncing
        Task { await performSync(baseURL: base) }
    }

    private func performSync(baseURL: URL) async {
        do {
            var components = URLComponents(url: baseURL.appendingPathComponent("api/snapshot"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "format", value: "tar")]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 30

            if let etag = UserDefaults.standard.string(forKey: Self.etagKey) {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                state = .failed("Invalid response")
                return
            }

            if http.statusCode == 304 {
                lastSyncAt = Date()
                UserDefaults.standard.set(lastSyncAt, forKey: Self.lastSyncKey)
                state = .idle
                Self.log.notice("snapshot unchanged (304)")
                return
            }

            guard http.statusCode == 200 else {
                state = .failed("Server returned \(http.statusCode)")
                return
            }

            let extracted = try SnapshotArchive.extract(archive: data, to: snapshotDir)

            try await store.load(parquetDir: extracted.parquetDir, tables: extracted.manifest.tables)
            cachedSnapshots = try await store.trips()

            if let etag = http.value(forHTTPHeaderField: "ETag") {
                UserDefaults.standard.set(etag, forKey: Self.etagKey)
            }
            manifest = extracted.manifest
            if let mData = try? JSONEncoder().encode(extracted.manifest) {
                UserDefaults.standard.set(mData, forKey: Self.manifestKey)
            }
            lastSyncAt = Date()
            UserDefaults.standard.set(lastSyncAt, forKey: Self.lastSyncKey)
            state = .idle
            Self.log.notice("synced \(self.cachedSnapshots.count) trips from \(extracted.manifest.bundleCount) bundles")
        } catch {
            state = .failed(error.localizedDescription)
            Self.log.error("sync failed: \(error)")
        }
    }

    public var isStale: Bool {
        guard hasServer else { return false }
        guard let lastSync = lastSyncAt else { return true }
        return Date().timeIntervalSince(lastSync) > Self.staleAfter
    }
}
