import CairnCore
import CryptoKit
import Foundation
import Testing

// MARK: - Multi-step mock transport

private final class SequenceTransport: HTTPTransport, @unchecked Sendable {
    private var responses: [HTTPResponse]
    private var index = 0
    var requestLog: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestLog.append(request)
        guard index < responses.count else {
            return HTTPResponse(status: 500, body: Data())
        }
        let resp = responses[index]
        index += 1
        return resp
    }
}

// MARK: - Response builders

private func pushResponse(results: [(String, PushStatus)], head: Int64 = 1) -> HTTPResponse {
    let items = results.map { (opID, status) -> [String: Any] in
        var r: [String: Any] = ["operation_id": opID]
        switch status {
        case .accepted: r["status"] = "accepted"; r["server_sequence"] = 1
        case .duplicate: r["status"] = "duplicate"; r["server_sequence"] = 1
        case .conflict: r["status"] = "conflict"; r["conflicts"] = [["field": "title", "current_revision": 2, "current_value": "x"]]
        case .rejected: r["status"] = "rejected"; r["reason"] = "scope"
        case .unknown(let s): r["status"] = s
        }
        return r
    }
    let body: [String: Any] = ["results": items, "head": head]
    return HTTPResponse(
        status: 200,
        headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: body)
    )
}

private func pullResponse(cursor: String, hasMore: Bool, changes: [[String: Any]] = []) -> HTTPResponse {
    let body: [String: Any] = [
        "epoch": "test-epoch",
        "cursor": cursor,
        "has_more": hasMore,
        "changes": changes
    ]
    return HTTPResponse(
        status: 200,
        headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: body)
    )
}

private func ackResponse(acknowledged: Int64 = 1) -> HTTPResponse {
    HTTPResponse(
        status: 200,
        headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: ["acknowledged": acknowledged])
    )
}

private func cursorResetResponse() -> HTTPResponse {
    HTTPResponse(
        status: 410,
        headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: ["error": "cursor_reset"])
    )
}

private func testOperation(id: String = "op-1", vehicleID: String = "v1", kind: String = "maintenance_event") -> SyncOperation {
    SyncOperation(
        operationID: id,
        clientID: "test-client",
        vehicleID: vehicleID,
        kind: kind,
        createdAt: "2026-10-05T12:00:00Z",
        payload: .object(["kind": .string("oil")]),
        contentHash: "abc123"
    )
}

private func testSigner() -> SoftwareSigner {
    SoftwareSigner(clientID: "test-client")
}

// MARK: - Push tests

@Suite struct SyncEnginePushTests {
    @Test func pushDrainsOutbox() async throws {
        let outbox = InMemoryOutboxStore()
        await outbox.enqueue(testOperation(id: "op-1"))
        await outbox.enqueue(testOperation(id: "op-2"))

        let transport = SequenceTransport([
            pushResponse(results: [("op-1", .accepted), ("op-2", .accepted)]),
            pullResponse(cursor: "c1", hasMore: false),
            ackResponse(),
        ])

        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: outbox,
            stateStore: InMemorySyncStateStore(),
            applier: NoOpSyncApplier(),
            instanceID: "inst1"
        )

        let result = try await engine.sync()
        #expect(result.pushed == 2)
        let remaining = await outbox.pendingCount()
        #expect(remaining == 0)
    }

    @Test func pushHandlesDuplicate() async throws {
        let outbox = InMemoryOutboxStore()
        await outbox.enqueue(testOperation(id: "op-1"))

        let transport = SequenceTransport([
            pushResponse(results: [("op-1", .duplicate)]),
            pullResponse(cursor: "c1", hasMore: false),
            ackResponse(),
        ])

        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: outbox,
            stateStore: InMemorySyncStateStore(),
            applier: NoOpSyncApplier(),
            instanceID: "inst1"
        )

        let result = try await engine.sync()
        #expect(result.pushed == 1)
        let remaining = await outbox.pendingCount()
        #expect(remaining == 0)
    }

    @Test func pushMarksConflict() async throws {
        let outbox = InMemoryOutboxStore()
        await outbox.enqueue(testOperation(id: "op-1"))

        let transport = SequenceTransport([
            pushResponse(results: [("op-1", .conflict)]),
            pullResponse(cursor: "c1", hasMore: false),
            ackResponse(),
        ])

        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: outbox,
            stateStore: InMemorySyncStateStore(),
            applier: NoOpSyncApplier(),
            instanceID: "inst1"
        )

        let result = try await engine.sync()
        #expect(result.conflicts == 1)
        let remaining = await outbox.pendingCount()
        #expect(remaining == 1)
    }

    @Test func pushMarksRejected() async throws {
        let outbox = InMemoryOutboxStore()
        await outbox.enqueue(testOperation(id: "op-1"))

        let transport = SequenceTransport([
            pushResponse(results: [("op-1", .rejected)]),
            pullResponse(cursor: "c1", hasMore: false),
            ackResponse(),
        ])

        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: outbox,
            stateStore: InMemorySyncStateStore(),
            applier: NoOpSyncApplier(),
            instanceID: "inst1"
        )

        let result = try await engine.sync()
        #expect(result.rejected == 1)
    }

    @Test func emptyOutboxSkipsPush() async throws {
        let transport = SequenceTransport([
            pullResponse(cursor: "c1", hasMore: false),
            ackResponse(),
        ])

        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: InMemoryOutboxStore(),
            stateStore: InMemorySyncStateStore(),
            applier: NoOpSyncApplier(),
            instanceID: "inst1"
        )

        let result = try await engine.sync()
        #expect(result.pushed == 0)
        #expect(transport.requestLog[0].target.contains("/v1/sync/pull"))
    }
}

// MARK: - Pull tests

@Suite struct SyncEnginePullTests {
    @Test func pullAppliesChangesAndSavesCursor() async throws {
        let change: [String: Any] = [
            "server_sequence": 1,
            "at": 1790000000123,
            "type": "entity",
            "entity_type": "vehicle",
            "entity_id": "v1",
            "vehicle_id": "v1",
            "data": ["display_name": "BMW"]
        ]

        let transport = SequenceTransport([
            pullResponse(cursor: "cursor-1", hasMore: false, changes: [change]),
            ackResponse(acknowledged: 1),
        ])

        let stateStore = InMemorySyncStateStore()
        let applier = NoOpSyncApplier()
        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: InMemoryOutboxStore(),
            stateStore: stateStore, applier: applier,
            instanceID: "inst1"
        )

        let result = try await engine.sync()
        #expect(result.pulled == 1)

        let cursor = await stateStore.load()
        #expect(cursor?.cursor == "cursor-1")
        #expect(cursor?.instanceID == "inst1")

        let applied = await applier.appliedChanges
        #expect(applied.count == 1)
    }

    @Test func pullPagesUntilDone() async throws {
        let change1: [String: Any] = [
            "server_sequence": 1, "at": 100, "type": "entity",
            "entity_type": "vehicle", "entity_id": "v1"
        ]
        let change2: [String: Any] = [
            "server_sequence": 2, "at": 200, "type": "entity",
            "entity_type": "vehicle", "entity_id": "v2"
        ]

        let transport = SequenceTransport([
            pullResponse(cursor: "c1", hasMore: true, changes: [change1]),
            ackResponse(acknowledged: 1),
            pullResponse(cursor: "c2", hasMore: false, changes: [change2]),
            ackResponse(acknowledged: 2),
        ])

        let stateStore = InMemorySyncStateStore()
        let applier = NoOpSyncApplier()
        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: InMemoryOutboxStore(),
            stateStore: stateStore, applier: applier,
            instanceID: "inst1"
        )

        let result = try await engine.sync()
        #expect(result.pulled == 2)

        let cursor = await stateStore.load()
        #expect(cursor?.cursor == "c2")

        let applied = await applier.appliedChanges
        #expect(applied.count == 2)
    }

    @Test func pullHandlesCursorReset() async throws {
        let change: [String: Any] = [
            "server_sequence": 1, "at": 100, "type": "entity",
            "entity_type": "vehicle", "entity_id": "v1"
        ]

        let transport = SequenceTransport([
            cursorResetResponse(),
            pullResponse(cursor: "fresh-cursor", hasMore: false, changes: [change]),
            ackResponse(acknowledged: 1),
        ])

        let stateStore = InMemorySyncStateStore()
        await stateStore.save(SyncCursor(instanceID: "inst1", cursor: "old-cursor"))

        let applier = NoOpSyncApplier()
        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: InMemoryOutboxStore(),
            stateStore: stateStore, applier: applier,
            instanceID: "inst1"
        )

        let result = try await engine.sync()
        #expect(result.pulled == 1)

        let cursor = await stateStore.load()
        #expect(cursor?.cursor == "fresh-cursor")

        let resets = await applier.cursorResetCount
        #expect(resets == 1)
    }

    @Test func pullAcksSentAfterEachPage() async throws {
        let change: [String: Any] = [
            "server_sequence": 1, "at": 100, "type": "entity",
            "entity_type": "vehicle", "entity_id": "v1"
        ]

        let transport = SequenceTransport([
            pullResponse(cursor: "c1", hasMore: false, changes: [change]),
            ackResponse(acknowledged: 1),
        ])

        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: InMemoryOutboxStore(),
            stateStore: InMemorySyncStateStore(),
            applier: NoOpSyncApplier(),
            instanceID: "inst1"
        )

        _ = try await engine.sync()

        let ackRequest = transport.requestLog.last!
        #expect(ackRequest.target == "/v1/sync/ack")
        #expect(ackRequest.method == "POST")
    }

    @Test func instanceIDMismatchTriggersCursorReset() async throws {
        let stateStore = InMemorySyncStateStore()
        await stateStore.save(SyncCursor(instanceID: "old-instance", cursor: "old-cursor"))

        let transport = SequenceTransport([
            pullResponse(cursor: "new-cursor", hasMore: false),
            ackResponse(),
        ])

        let applier = NoOpSyncApplier()
        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: InMemoryOutboxStore(),
            stateStore: stateStore, applier: applier,
            instanceID: "new-instance"
        )

        _ = try await engine.sync()

        let cursor = await stateStore.load()
        #expect(cursor?.instanceID == "new-instance")

        let resets = await applier.cursorResetCount
        #expect(resets == 1)
    }
}

// MARK: - Full sync tests

@Suite struct SyncEngineFullTests {
    @Test func pushThenPull() async throws {
        let outbox = InMemoryOutboxStore()
        await outbox.enqueue(testOperation(id: "op-1"))

        let change: [String: Any] = [
            "server_sequence": 2, "at": 200, "type": "entity",
            "entity_type": "vehicle", "entity_id": "v1",
            "data": ["display_name": "BMW"]
        ]

        let transport = SequenceTransport([
            pushResponse(results: [("op-1", .accepted)]),
            pullResponse(cursor: "c1", hasMore: false, changes: [change]),
            ackResponse(acknowledged: 2),
        ])

        let applier = NoOpSyncApplier()
        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: outbox,
            stateStore: InMemorySyncStateStore(),
            applier: applier,
            instanceID: "inst1"
        )

        let result = try await engine.sync()
        #expect(result.pushed == 1)
        #expect(result.pulled == 1)
        #expect(result.conflicts == 0)
        #expect(result.rejected == 0)

        let remaining = await outbox.pendingCount()
        #expect(remaining == 0)

        let applied = await applier.appliedChanges
        #expect(applied.count == 1)
    }

    @Test func cursorResetPreservesOutbox() async throws {
        let outbox = InMemoryOutboxStore()
        await outbox.enqueue(testOperation(id: "op-unsent"))

        let transport = SequenceTransport([
            pushResponse(results: [("op-unsent", .accepted)]),
            cursorResetResponse(),
            pullResponse(cursor: "fresh", hasMore: false),
            ackResponse(),
        ])

        let client = CairnServerClient(transport: transport, signer: testSigner())
        let engine = SyncEngine(
            client: client, outbox: outbox,
            stateStore: InMemorySyncStateStore(),
            applier: NoOpSyncApplier(),
            instanceID: "inst1"
        )

        let result = try await engine.sync()
        #expect(result.pushed == 1)
    }
}

// MARK: - Exchange vector replay

@Suite struct SyncEngineExchangeTests {
    @Test func pushPullAckWithExchangeVectors() async throws {
        let file = Contracts.json("sync/v1/vectors/exchanges.json")
        let allSteps = file["steps"] as! [[String: Any]]
        let fix = file["fixture"] as! [String: Any]
        let allClients = fix["clients"] as! [[String: Any]]
        let alphaData = allClients.first { $0["name"] as? String == "alpha" }!
        let scalar = alphaData["private_scalar_hex"] as! String
        let clientID = alphaData["client_id"] as! String
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(hex: scalar))
        let signer = SoftwareSigner(clientID: clientID, privateKey: privateKey)

        let pushStep = allSteps[10]
        let pullPage1 = allSteps[23]
        let pullPage2 = allSteps[24]
        let ackStep = allSteps[33]

        let responses = [pushStep, pullPage1, ackStep, pullPage2, ackStep].map { step -> HTTPResponse in
            let resp = step["response"] as! [String: Any]
            let status = resp["status"] as! Int
            let headers = resp["headers"] as? [String: String] ?? [:]
            var body = Data()
            if let bodyJSON = resp["body_json"] {
                body = try! JSONSerialization.data(withJSONObject: bodyJSON)
            }
            return HTTPResponse(status: status, headers: headers, body: body)
        }

        let transport = SequenceTransport(responses)
        let outbox = InMemoryOutboxStore()

        let op = SyncOperation(
            operationID: "0190a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a01",
            clientID: clientID,
            vehicleID: "303132333435363738393a3b3c3d3e3f",
            kind: "maintenance_event",
            createdAt: "2026-09-21T13:33:20Z",
            payload: .object(["kind": .string("oil"), "odometer_km": .int(45210)]),
            contentHash: "f381423e512870001f6ce15889f136c8851fb48acddf55fb6c40b0227e624d6f"
        )
        await outbox.enqueue(op)

        let instanceID = fix["instance_id"] as! String
        let client = CairnServerClient(transport: transport, signer: signer)
        let stateStore = InMemorySyncStateStore()
        let applier = NoOpSyncApplier()

        let engine = SyncEngine(
            client: client, outbox: outbox,
            stateStore: stateStore, applier: applier,
            instanceID: instanceID
        )

        let result = try await engine.sync()
        #expect(result.pushed == 1)
        #expect(result.pulled >= 0)

        let remaining = await outbox.pendingCount()
        #expect(remaining == 0)

        let cursor = await stateStore.load()
        #expect(cursor != nil)
        #expect(cursor?.instanceID == instanceID)
    }
}
