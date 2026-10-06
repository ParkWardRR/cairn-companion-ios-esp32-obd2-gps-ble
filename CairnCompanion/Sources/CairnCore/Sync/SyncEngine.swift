import Foundation

public actor SyncEngine {
    private let client: CairnServerClient
    private let outbox: any OutboxStore
    private let stateStore: any SyncStateStore
    private let applier: any SyncApplier
    private let instanceID: String

    private static let pushBatchSize = 200

    public init(
        client: CairnServerClient,
        outbox: any OutboxStore,
        stateStore: any SyncStateStore,
        applier: any SyncApplier,
        instanceID: String
    ) {
        self.client = client
        self.outbox = outbox
        self.stateStore = stateStore
        self.applier = applier
        self.instanceID = instanceID
    }

    public struct SyncResult: Sendable, Equatable {
        public var pushed: Int
        public var pulled: Int
        public var conflicts: Int
        public var rejected: Int

        public init(pushed: Int = 0, pulled: Int = 0, conflicts: Int = 0, rejected: Int = 0) {
            self.pushed = pushed
            self.pulled = pulled
            self.conflicts = conflicts
            self.rejected = rejected
        }
    }

    public func sync() async throws -> SyncResult {
        let pushResult = try await pushAll()
        let pullResult = try await pullAll()
        return SyncResult(
            pushed: pushResult.accepted + pushResult.duplicate,
            pulled: pullResult,
            conflicts: pushResult.conflicts,
            rejected: pushResult.rejected
        )
    }

    // MARK: - Push

    private struct PushTally {
        var accepted = 0
        var duplicate = 0
        var conflicts = 0
        var rejected = 0
    }

    private func pushAll() async throws -> PushTally {
        var tally = PushTally()

        while true {
            let batch = try await outbox.pending(limit: Self.pushBatchSize)
            if batch.isEmpty { break }

            let response = try await client.push(batch)

            var doneIDs = Set<String>()
            for (i, result) in response.results.enumerated() {
                let opID = result.operationID
                switch result.status {
                case .accepted:
                    doneIDs.insert(opID)
                    tally.accepted += 1
                case .duplicate:
                    doneIDs.insert(opID)
                    tally.duplicate += 1
                case .conflict:
                    tally.conflicts += 1
                    let reason = result.conflicts?.map {
                        "\($0.field):r\($0.currentRevision)"
                    }.joined(separator: ",") ?? "conflict"
                    try await outbox.markFailed(opID, error: reason)
                case .rejected:
                    tally.rejected += 1
                    try await outbox.markFailed(opID, error: result.reason ?? "rejected")
                case .unknown(let raw):
                    try await outbox.markFailed(opID, error: "unknown_status:\(raw)")
                }
            }

            if !doneIDs.isEmpty {
                try await outbox.markDone(doneIDs)
            }

            if batch.count < Self.pushBatchSize { break }
        }

        return tally
    }

    // MARK: - Pull

    private func pullAll() async throws -> Int {
        var syncCursor = try await stateStore.load()

        if let existing = syncCursor, existing.instanceID != instanceID {
            try await applier.handleCursorReset()
            try await stateStore.clear()
            syncCursor = nil
        }

        var cursor = syncCursor?.cursor
        var totalApplied = 0

        pullLoop: while true {
            let outcome = try await client.pull(cursor: cursor)

            switch outcome {
            case .cursorReset:
                try await applier.handleCursorReset()
                try await stateStore.clear()
                cursor = nil
                continue pullLoop

            case .page(let page):
                if !page.changes.isEmpty {
                    try await applier.apply(changes: page.changes, cursor: page.cursor)
                    totalApplied += page.changes.count
                }

                let newState = SyncCursor(
                    instanceID: instanceID,
                    cursor: page.cursor,
                    lastSuccessAt: Date()
                )
                try await stateStore.save(newState)

                _ = try await client.ack(cursor: page.cursor)

                cursor = page.cursor

                if !page.hasMore { break pullLoop }
            }
        }

        return totalApplied
    }
}
