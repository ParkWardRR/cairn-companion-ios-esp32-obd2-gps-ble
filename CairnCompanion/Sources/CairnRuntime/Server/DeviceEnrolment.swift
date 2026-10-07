import CairnCore
import Foundation
#if os(iOS)
import UIKit
#endif

extension Notification.Name {
    /// Posted when the server address, the pinned certificate or the enrolment changed outside the
    /// Settings screen (the setup sheet), so a Settings screen that is already showing can reload.
    static let cairnSetupChanged = Notification.Name("app.cairn.companion.setupChanged")
}

/// Runs enrolment against the server and words its failures. Shared by the Settings form and the
/// `cairn://configure` sheet, so both behave and read the same.
enum DeviceEnrolment {
    static func enrol(
        code: String, serverURL: String, tailnetURL: String, service: EnrolmentService
    ) async throws -> EnrolledIdentity {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmed), baseURL.scheme != nil, baseURL.host != nil else {
            throw EnrolmentFormError.badServerURL
        }
        let client = CairnServerClient(transport: URLSessionTransport(baseURL: baseURL), signer: PlaceholderSigner())
        #if os(iOS)
        let deviceName = await MainActor.run { UIDevice.current.name }
        #else
        let deviceName = Host.current().localizedName ?? "Mac"
        #endif
        let identity = try await service.enrol(
            code: code, deviceName: deviceName, using: client,
            localBaseURL: serverURL, tailnetBaseURL: tailnetURL
        )
        NotificationCenter.default.post(name: .cairnSetupChanged, object: nil)
        return identity
    }

    static func message(for error: Error) -> String {
        if let error = error as? EnrolmentFormError { return error.message }
        if let error = error as? CairnServerError {
            switch error {
            case .forbidden(.enrolmentRefused):
                return "Invitation code is invalid or has been used"
            case .unauthenticated:
                return "Enrolment proof was rejected by the server"
            case .transport(.tls):
                return "This phone doesn't trust the server's certificate. Scan a Cairn setup QR code, which includes it."
            case .transport(.offline), .transport(.timedOut):
                return "Can't reach the server. Check you are on the home Wi-Fi or Tailscale."
            default:
                return "Server error: \(error.errorCode ?? "unknown")"
            }
        }
        return error.localizedDescription
    }
}

struct PlaceholderSigner: RequestSigner, Sendable {
    let clientID = ""
    let publicKeyX963 = Data()
    func sign(_ data: Data) throws -> Data {
        throw CairnServerError.signingFailed
    }
}

enum EnrolmentFormError: Error {
    case badServerURL

    var message: String {
        "The server URL must look like https://cairn.example.lan:8444"
    }
}
