import Foundation

public struct SyncCursor: Codable, Sendable, Equatable {
    public var instanceID: String
    public var cursor: String?
    public var lastSuccessAt: Date?

    public init(instanceID: String, cursor: String? = nil, lastSuccessAt: Date? = nil) {
        self.instanceID = instanceID
        self.cursor = cursor
        self.lastSuccessAt = lastSuccessAt
    }
}

public protocol SyncStateStore: Sendable {
    func load() async throws -> SyncCursor?
    func save(_ cursor: SyncCursor) async throws
    func clear() async throws
}

public actor InMemorySyncStateStore: SyncStateStore {
    private var cursor: SyncCursor?

    public init() {}

    public func load() -> SyncCursor? { cursor }

    public func save(_ cursor: SyncCursor) {
        self.cursor = cursor
    }

    public func clear() {
        cursor = nil
    }
}
