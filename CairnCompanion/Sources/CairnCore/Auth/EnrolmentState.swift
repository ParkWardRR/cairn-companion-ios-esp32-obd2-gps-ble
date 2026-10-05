import Foundation

public enum EnrolmentState: String, Codable, Sendable {
    case notEnrolled
    case enrolling
    case enrolled
    case revoked
}

public struct EnrolledIdentity: Codable, Sendable {
    public var clientID: String
    public var role: String
    public var scope: [String]
    public var instanceID: String
    public var spkiSHA256: String
    public var localBaseURL: String
    public var tailnetBaseURL: String

    public init(
        clientID: String, role: String, scope: [String],
        instanceID: String, spkiSHA256: String,
        localBaseURL: String, tailnetBaseURL: String
    ) {
        self.clientID = clientID
        self.role = role
        self.scope = scope
        self.instanceID = instanceID
        self.spkiSHA256 = spkiSHA256
        self.localBaseURL = localBaseURL
        self.tailnetBaseURL = tailnetBaseURL
    }

    public var isAdmin: Bool { role == "admin" }
}
