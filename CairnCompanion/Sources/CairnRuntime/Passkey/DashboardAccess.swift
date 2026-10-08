import CairnCore
import Foundation
import Observation

/// The phone's way into the dashboard: its address, whether it is signed in, and the passkey sign-in
/// and creation that gets it there. The address lives in UserDefaults only, never in the repository.
@MainActor @Observable
public final class DashboardAccess {
    public enum Status: Equatable {
        case unset
        case checking
        case signedOut(passkeys: Int)
        case signedIn(viaTailnet: Bool, passkeys: Int, fresh: Bool)
        case unreachable
    }

    public static let urlKey = "cairn.dashboardURL"

    public var urlText: String {
        didSet { UserDefaults.standard.set(urlText, forKey: Self.urlKey) }
    }
    public private(set) var status: Status = .unset
    public private(set) var busy = false
    public private(set) var message: String?
    public private(set) var failed = false

    /// Its cookies are the dashboard session; signing out ends it on the server and forgets them here.
    let urlSession: URLSession
    private let cookies: HTTPCookieStorage
    #if os(iOS)
    private let authenticator = PasskeyAuthenticator()
    #endif

    public init() {
        urlText = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        // The shared store keeps the 30-day session cookie across launches; only this host's are read or removed.
        let storage = HTTPCookieStorage.shared
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = storage
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 15
        cookies = storage
        urlSession = URLSession(configuration: configuration)
    }

    /// The address as a URL, only if it is one a passkey could work for: https, with a host.
    public var url: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
              url.scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private var client: DashboardAuthClient? {
        url.map { DashboardAuthClient(transport: URLSessionTransport(baseURL: $0, session: urlSession)) }
    }

    /// Cookies the dashboard has set, for the in-app web view.
    var sessionCookies: [HTTPCookie] {
        url.flatMap { cookies.cookies(for: $0) } ?? []
    }

    public func refresh() async {
        guard let client else { status = .unset; return }
        status = .checking
        do {
            let s = try await client.session()
            status = s.authenticated
                ? .signedIn(viaTailnet: s.viaTailnet, passkeys: s.passkeys, fresh: s.fresh)
                : .signedOut(passkeys: s.passkeys)
        } catch {
            status = .unreachable
            say(error, failed: true)
        }
    }

    public func signIn() async {
        #if os(iOS)
        guard let client else { return }
        await run("Signed in with your passkey.") {
            let request = try await client.signInChallenge()
            let body = try await self.authenticator.signIn(request)
            try await client.finishSignIn(body)
        }
        #endif
    }

    /// Makes a passkey on this phone. `code` is the server's one-time code, needed only for the very first.
    public func createPasskey(code: String? = nil) async {
        #if os(iOS)
        guard let client else { return }
        let name = "iPhone"
        await run("Passkey created. It is in iCloud Keychain, so it works in Safari too.") {
            let request = try await client.createChallenge(bootstrapCode: code)
            let body = try await self.authenticator.create(request, name: name)
            try await client.finishCreate(body)
        }
        #endif
    }

    public func signOut() async {
        try? await client?.signOut()
        for cookie in sessionCookies { cookies.deleteCookie(cookie) }
        await refresh()
    }

    private func run(_ success: String, _ work: @escaping () async throws -> Void) async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await work()
            say(success)
        } catch let failure as PasskeyFailure where failure == .cancelled {
            message = nil
        } catch {
            say(error, failed: true)
        }
        await refreshQuietly()
    }

    /// Re-reads who the dashboard thinks we are without wiping the message just set.
    private func refreshQuietly() async {
        guard let client, let s = try? await client.session() else { return }
        status = s.authenticated
            ? .signedIn(viaTailnet: s.viaTailnet, passkeys: s.passkeys, fresh: s.fresh)
            : .signedOut(passkeys: s.passkeys)
    }

    private func say(_ text: String) { message = text; failed = false }
    private func say(_ error: Error, failed: Bool) {
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        self.failed = failed
    }
}
