import Foundation

public protocol SyncApplier: Sendable {
    func apply(changes: [SyncChange], cursor: String) async throws
    func handleCursorReset() async throws
}

public actor NoOpSyncApplier: SyncApplier {
    public var appliedChanges: [SyncChange] = []
    public var cursorResetCount = 0

    public init() {}

    public func apply(changes: [SyncChange], cursor: String) {
        appliedChanges.append(contentsOf: changes)
    }

    public func handleCursorReset() {
        appliedChanges.removeAll()
        cursorResetCount += 1
    }
}
