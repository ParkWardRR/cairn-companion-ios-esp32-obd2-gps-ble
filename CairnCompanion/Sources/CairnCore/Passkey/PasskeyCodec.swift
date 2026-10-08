import Foundation

/// Base64url without padding, the encoding WebAuthn's JSON uses for every binary field.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}

/// What the dashboard asks the phone's passkey system to do: sign in with a passkey, or make one.
/// Parsed from the dashboard's WebAuthn options (the same JSON its web page hands the browser).
public struct PasskeyRequest: Sendable, Equatable {
    public let challengeID: String
    public let challenge: Data
    /// The site the passkey belongs to; the app must be associated with it (Associated Domains).
    public let rpID: String
    /// Sign in only: the passkeys the server will accept. Empty means any the phone holds for the site.
    public let allowedCredentialIDs: [Data]
    /// Create only: passkeys that already exist, so the phone does not make a second one.
    public let excludedCredentialIDs: [Data]
    public let userID: Data?
    public let userName: String?
}

public enum PasskeyCodecError: Error, Equatable {
    case malformed(String)
}

/// Turns the dashboard's WebAuthn JSON into a `PasskeyRequest`, and the phone's answer back into
/// the JSON the dashboard verifies (the shape `@simplewebauthn/browser` would have sent). No
/// AuthenticationServices here, so it is tested without a device.
public enum PasskeyCodec {
    // MARK: Requests

    public static func signInRequest(from body: Data) throws -> PasskeyRequest {
        let (id, options) = try envelope(body)
        guard let rpID = options["rpId"] as? String, !rpID.isEmpty else { throw PasskeyCodecError.malformed("rpId") }
        return PasskeyRequest(
            challengeID: id,
            challenge: try binary(options["challenge"], "challenge"),
            rpID: rpID,
            allowedCredentialIDs: try credentialIDs(options["allowCredentials"]),
            excludedCredentialIDs: [],
            userID: nil, userName: nil
        )
    }

    public static func createRequest(from body: Data) throws -> PasskeyRequest {
        let (id, options) = try envelope(body)
        guard let rp = options["rp"] as? [String: Any], let rpID = rp["id"] as? String, !rpID.isEmpty else {
            throw PasskeyCodecError.malformed("rp.id")
        }
        guard let user = options["user"] as? [String: Any] else { throw PasskeyCodecError.malformed("user") }
        return PasskeyRequest(
            challengeID: id,
            challenge: try binary(options["challenge"], "challenge"),
            rpID: rpID,
            allowedCredentialIDs: [],
            excludedCredentialIDs: try credentialIDs(options["excludeCredentials"]),
            userID: try binary(user["id"], "user.id"),
            userName: user["name"] as? String
        )
    }

    // MARK: Answers

    public static func signInBody(
        for request: PasskeyRequest, credentialID: Data, clientDataJSON: Data,
        authenticatorData: Data, signature: Data, userHandle: Data?
    ) throws -> Data {
        var response: [String: Any] = [
            "clientDataJSON": Base64URL.encode(clientDataJSON),
            "authenticatorData": Base64URL.encode(authenticatorData),
            "signature": Base64URL.encode(signature),
        ]
        if let userHandle, !userHandle.isEmpty { response["userHandle"] = Base64URL.encode(userHandle) }
        return try encode(["challengeId": request.challengeID, "response": credential(credentialID, response)])
    }

    public static func createBody(
        for request: PasskeyRequest, name: String, credentialID: Data,
        clientDataJSON: Data, attestationObject: Data
    ) throws -> Data {
        let response: [String: Any] = [
            "clientDataJSON": Base64URL.encode(clientDataJSON),
            "attestationObject": Base64URL.encode(attestationObject),
            // an iCloud Keychain passkey lives on the device and can be used from a nearby phone
            "transports": ["internal", "hybrid"],
        ]
        return try encode(["challengeId": request.challengeID, "name": name, "response": credential(credentialID, response)])
    }

    // MARK: Helpers

    private static func credential(_ id: Data, _ response: [String: Any]) -> [String: Any] {
        let encoded = Base64URL.encode(id)
        return [
            "id": encoded, "rawId": encoded, "type": "public-key",
            "authenticatorAttachment": "platform",
            "clientExtensionResults": [String: Any](),
            "response": response,
        ]
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func envelope(_ body: Data) throws -> (String, [String: Any]) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = root["challengeId"] as? String, !id.isEmpty,
              let options = root["options"] as? [String: Any]
        else { throw PasskeyCodecError.malformed("options") }
        return (id, options)
    }

    private static func binary(_ value: Any?, _ field: String) throws -> Data {
        guard let s = value as? String, let data = Base64URL.decode(s), !data.isEmpty else {
            throw PasskeyCodecError.malformed(field)
        }
        return data
    }

    private static func credentialIDs(_ value: Any?) throws -> [Data] {
        guard let list = value as? [[String: Any]] else { return [] }
        return try list.map { try binary($0["id"], "credential id") }
    }
}
