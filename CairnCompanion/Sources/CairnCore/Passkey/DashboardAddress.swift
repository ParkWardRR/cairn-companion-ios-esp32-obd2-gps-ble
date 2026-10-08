import Foundation

/// Where the dashboard is, worked out from the one server address the phone already has, so there is
/// nothing more to type. The dashboard is served on the same host name as the server (the server on its
/// own port, the dashboard on the ordinary https port), and a passkey belongs to that host name.
public enum DashboardAddress {
    public enum Problem: Equatable, Sendable {
        case noServer
        /// A passkey belongs to a host *name*; the server is set up by an IP address, which cannot carry one.
        case ipAddress
        case notHTTPS
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

    public static func words(for problem: Problem) -> String {
        switch problem {
        case .noServer: "Set the server address above to use the dashboard."
        case .ipAddress: "Passkeys need the server's host name, not an IP address."
        case .notHTTPS: "The dashboard needs an https address."
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
