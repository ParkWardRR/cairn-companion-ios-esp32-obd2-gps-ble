import Foundation

/// Who the dashboard thinks you are. `method` is how: a passkey, or this phone being a Tailnet
/// device the dashboard allows (then no sign-in is needed at all).
public struct DashboardSessionInfo: Sendable, Equatable {
    public var authenticated: Bool
    public var method: String?
    public var fresh: Bool
    public var passkeys: Int
    public var canEnrol: Bool
    public var onTailnet: Bool

    public var viaTailnet: Bool { method == "tailnet" }
    public var viaPasskey: Bool { method == "passkey" }
}

/// Why talking to the dashboard did not work, in words a person can act on.
public enum DashboardAuthError: Error, Equatable, LocalizedError {
    case unreachable
    case noPasskeyYet
    case needsCodeOrTailnet
    case needsRecentPasskey
    case rejected(String)
    case unexpected(Int)

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            "The dashboard could not be reached. Check the address, and that this phone is on home Wi-Fi or your tailnet."
        case .noPasskeyYet:
            "The dashboard has no passkey yet. Create the first one from the dashboard's sign-in page."
        case .needsCodeOrTailnet:
            "The first passkey can only be created from a tailnet device the dashboard allows, or with the one-time code on the server."
        case .needsRecentPasskey:
            "Sign in with a passkey first (within the last five minutes), then create another."
        case .rejected(let why):
            "The dashboard did not accept that: \(why)."
        case .unexpected(let status):
            "The dashboard answered with an unexpected error (\(status))."
        }
    }
}

/// The dashboard's passkey endpoints (`/api/auth/*`), the same ones its web page uses. The
/// passkey ceremony itself (Face ID, the system sheet) is the runtime's; this only moves the
/// challenge out and the answer back. Cookies are the transport's business: the session the
/// dashboard starts arrives as a `Set-Cookie` that a cookie-keeping URLSession stores.
public struct DashboardAuthClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public func session() async throws -> DashboardSessionInfo {
        let response = try await call("GET", "/api/auth/session")
        guard response.status == 200, let o = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw DashboardAuthError.unexpected(response.status)
        }
        return DashboardSessionInfo(
            authenticated: o["authenticated"] as? Bool ?? false,
            method: o["method"] as? String,
            fresh: o["fresh"] as? Bool ?? false,
            passkeys: o["passkeys"] as? Int ?? 0,
            canEnrol: o["can_enrol"] as? Bool ?? false,
            onTailnet: o["on_tailnet"] as? Bool ?? false
        )
    }

    /// A sign-in challenge that names no passkey, so the phone offers whichever it holds for the site.
    public func signInChallenge() async throws -> PasskeyRequest {
        let response = try await call("POST", "/api/auth/login-options", json: ["discoverable": true])
        if response.status == 409 { throw DashboardAuthError.noPasskeyYet }
        try check(response)
        return try PasskeyCodec.signInRequest(from: response.body)
    }

    public func finishSignIn(_ body: Data) async throws {
        try check(try await send("POST", "/api/auth/login-verify", body))
    }

    /// A challenge to make a passkey. The first needs a Tailnet identity or the server's one-time
    /// code; later ones need a passkey sign-in within the last five minutes.
    public func createChallenge(bootstrapCode: String? = nil) async throws -> PasskeyRequest {
        let code = bootstrapCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = try await call("POST", "/api/auth/register-options", json: code.flatMap { $0.isEmpty ? nil : ["bootstrapCode": $0] } ?? [:])
        if response.status == 401 {
            // first passkey (no code, no tailnet) or a later one (no fresh passkey): the message says which
            let message = Self.message(response.body)
            throw message.contains("Tailnet") ? DashboardAuthError.needsCodeOrTailnet : DashboardAuthError.needsRecentPasskey
        }
        try check(response)
        return try PasskeyCodec.createRequest(from: response.body)
    }

    public func finishCreate(_ body: Data) async throws {
        try check(try await send("POST", "/api/auth/register-verify", body))
    }

    /// Ends the session on the dashboard's side too, so a copied cookie stops working.
    public func signOut() async throws {
        try check(try await send("POST", "/api/auth/logout", nil))
    }

    // MARK: Plumbing

    private func call(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> HTTPResponse {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        return try await send(method, path, body)
    }

    private func send(_ method: String, _ path: String, _ body: Data?) async throws -> HTTPResponse {
        var headers = ["Accept": "application/json"]
        if let body, !body.isEmpty { headers["Content-Type"] = "application/json" }
        do {
            return try await transport.send(HTTPRequest(method: method, target: path, headers: headers, body: body ?? Data()))
        } catch {
            throw DashboardAuthError.unreachable
        }
    }

    private func check(_ response: HTTPResponse) throws {
        switch response.status {
        case 200..<300: return
        case 400..<500: throw DashboardAuthError.rejected(Self.message(response.body))
        default: throw DashboardAuthError.unexpected(response.status)
        }
    }

    /// The dashboard's own words for what was wrong (`statusMessage` in a Nuxt error body).
    static func message(_ body: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "no reason given" }
        return (o["statusMessage"] as? String) ?? (o["message"] as? String) ?? "no reason given"
    }
}
