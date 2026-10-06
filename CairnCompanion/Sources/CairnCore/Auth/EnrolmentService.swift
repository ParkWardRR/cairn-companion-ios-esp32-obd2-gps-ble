import Foundation

public actor EnrolmentService {
    private let keyProvider: any KeyProvider
    private let identityStore: any IdentityStore

    public init(keyProvider: any KeyProvider, identityStore: any IdentityStore) {
        self.keyProvider = keyProvider
        self.identityStore = identityStore
    }

    public func enrol(
        code: String,
        deviceName: String,
        using client: CairnServerClient,
        localBaseURL: String,
        tailnetBaseURL: String
    ) async throws -> EnrolledIdentity {
        try await identityStore.save(state: .enrolling, identity: nil)

        let proofMessage = EnrolmentProof.message(
            code: code, publicKeyHex: keyProvider.publicKeyHex
        )
        let proofSignature: Data
        do {
            proofSignature = try keyProvider.sign(proofMessage)
        } catch {
            try await identityStore.save(state: .notEnrolled, identity: nil)
            throw EnrolmentError.proofSigningFailed
        }

        let result: EnrolmentResult
        do {
            result = try await client.enrol(
                code: EnrolmentProof.normalizedCode(code),
                name: deviceName,
                publicKey: keyProvider.publicKeyHex,
                proof: proofSignature
            )
        } catch {
            try await identityStore.save(state: .notEnrolled, identity: nil)
            throw error
        }

        let identity = EnrolledIdentity(
            clientID: result.clientID,
            role: result.role,
            scope: result.vehicles,
            instanceID: result.serverIdentity.instanceID,
            spkiSHA256: result.serverIdentity.spkiSHA256,
            localBaseURL: localBaseURL,
            tailnetBaseURL: tailnetBaseURL
        )
        try await identityStore.save(state: .enrolled, identity: identity)
        return identity
    }

    public func loadIdentity() async -> (EnrolmentState, EnrolledIdentity?) {
        await identityStore.load()
    }

    public func markRevoked() async throws {
        let (_, identity) = await identityStore.load()
        try await identityStore.save(state: .revoked, identity: identity)
    }

    public func reset() async throws {
        try keyProvider.deleteKey()
        try await identityStore.clear()
    }

    public func makeSigner() async -> (any RequestSigner)? {
        let (state, identity) = await identityStore.load()
        guard state == .enrolled, let identity else { return nil }
        return KeyProviderSigner(provider: keyProvider, clientID: identity.clientID)
    }
}

public enum EnrolmentError: Error, Sendable {
    case proofSigningFailed
    case notEnrolled
}
