import Foundation

public protocol ChunkProvider: Sendable {
    func readChunk(offset: Int64, length: Int64) async throws -> Data
}

public actor BundleRelayService {
    private let client: CairnServerClient

    public init(client: CairnServerClient) {
        self.client = client
    }

    public struct RelayResult: Sendable {
        public var bundleID: String
        public var receipt: RelayReceipt?
        public var chunksUploaded: Int
        public var alreadyCommitted: Bool
    }

    public func relay(
        manifest: Data,
        signature: String,
        chunkProvider: any ChunkProvider,
        useBearer: Bool = false
    ) async throws -> RelayResult {
        let offer = try await client.relayOffer(manifest: manifest, signature: signature)

        if offer.receiptAvailable && offer.missingChunks.isEmpty {
            let receipt = try await client.relayReceipt(bundleID: offer.bundleID)
            return RelayResult(
                bundleID: offer.bundleID,
                receipt: receipt,
                chunksUploaded: 0,
                alreadyCommitted: true
            )
        }

        var uploaded = 0
        for chunk in offer.missingChunks {
            let data = try await chunkProvider.readChunk(offset: chunk.offset, length: chunk.length)
            _ = try await client.relayChunk(
                bundleID: offer.bundleID,
                sha256: chunk.sha256,
                data: data,
                useBearer: useBearer
            )
            uploaded += 1
        }

        let receipt = try await client.relayCommit(bundleID: offer.bundleID)
        return RelayResult(
            bundleID: offer.bundleID,
            receipt: receipt,
            chunksUploaded: uploaded,
            alreadyCommitted: receipt.alreadyCommitted
        )
    }

    public func fetchReceipt(bundleID: String) async throws -> RelayReceipt {
        try await client.relayReceipt(bundleID: bundleID)
    }
}
