import Foundation

/// Where the dashboard is. By default it is worked out from the one server address the phone already has, so
/// there is nothing more to type: the dashboard is served on the same host name as the server (the server on
/// its own port, the dashboard on the ordinary https port), and a passkey belongs to that host name. When it
/// is somewhere else, the owner turns that default off and types the address.
public enum DashboardAddress {
    public enum Problem: Equatable, Sendable {
        case noServer
        /// A passkey belongs to a host *name*; the server is set up by an IP address, which cannot carry one.
        case ipAddress
        case notHTTPS
        /// "Same as the server" is off and nothing has been typed.
        case noDashboardAddress
    }

    /// The dashboard's address: the server's host name, or, with `sameHost` off, what was typed.
    public static func url(forServer server: String, sameHost: Bool = true, typed: String = "") -> URL? {
        sameHost ? url(forServer: server) : typedURL(typed)
    }

    public static func problem(forServer server: String, sameHost: Bool, typed: String) -> Problem? {
        sameHost ? problem(forServer: server) : typedProblem(typed)
    }

    public static func url(forServer server: String) -> URL? {
        guard problem(forServer: server) == nil else { return nil }
        guard let host = URL(string: normalised(server))?.host else { return nil }
        return URL(string: "https://\(host)")
    }

    public static func problem(forServer server: String) -> Problem? {
        let text = normalised(server)
        if text.isEmpty { return .noServer }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return .noServer }
        guard url.scheme?.lowercased() == "https" else { return .notHTTPS }
        return isIPAddress(host) ? .ipAddress : nil
    }

    // An address typed by hand keeps its port (a dashboard may sit on one); a bare host name is taken as https.
    private static func typedURL(_ typed: String) -> URL? {
        guard typedProblem(typed) == nil, let url = URL(string: typedText(typed)), let host = url.host else { return nil }
        return URL(string: "https://\(host)" + (url.port.map { ":\($0)" } ?? ""))
    }

    private static func typedProblem(_ typed: String) -> Problem? {
        let text = typedText(typed)
        if normalised(typed).isEmpty { return .noDashboardAddress }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return .noDashboardAddress }
        guard url.scheme?.lowercased() == "https" else { return .notHTTPS }
        return isIPAddress(host) ? .ipAddress : nil
    }

    private static func typedText(_ typed: String) -> String {
        let text = normalised(typed)
        return text.contains("://") ? text : "https://\(text)"
    }

    public static func words(for problem: Problem) -> String {
        switch problem {
        case .noServer: "Set the server address above to use the dashboard."
        case .ipAddress: "Passkeys need a host name, not an IP address."
        case .notHTTPS: "The dashboard needs an https address."
        case .noDashboardAddress: "Type the dashboard's address."
        }
    }

    private static func normalised(_ server: String) -> String {
        server.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6 (URL strips the brackets)
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}
