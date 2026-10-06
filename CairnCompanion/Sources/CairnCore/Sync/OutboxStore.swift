import Foundation

public protocol OutboxStore: Sendable {
    func enqueue(_ operation: SyncOperation) async throws
    func pending(limit: Int) async throws -> [SyncOperation]
    func markDone(_ operationIDs: Set<String>) async throws
    func markFailed(_ operationID: String, error: String) async throws
    func pendingCount() async throws -> Int
    func clear() async throws
}

public actor InMemoryOutboxStore: OutboxStore {
    private var operations: [SyncOperation] = []
    private var failed: [String: String] = [:]

    public init() {}

    public func enqueue(_ operation: SyncOperation) {
        operations.append(operation)
    }

    public func pending(limit: Int) -> [SyncOperation] {
        Array(operations.prefix(limit))
    }

    public func markDone(_ operationIDs: Set<String>) {
        operations.removeAll { operationIDs.contains($0.operationID) }
        for id in operationIDs { failed.removeValue(forKey: id) }
    }

    public func markFailed(_ operationID: String, error: String) {
        failed[operationID] = error
    }

    public func pendingCount() -> Int {
        operations.count
    }

    public func clear() {
        operations.removeAll()
        failed.removeAll()
    }

    public func allOperations() -> [SyncOperation] { operations }
}
