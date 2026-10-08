import CairnCore
import Foundation

#if os(iOS)
import AuthenticationServices
import UIKit

/// The system passkey sheet (Face ID, iCloud Keychain), through AuthenticationServices: Apple's
/// own passkey API, the one Safari uses, so a passkey made here works in the browser and the
/// other way round. It needs the app to be associated with the dashboard's domain (the
/// `webcredentials` Associated Domain; see the README).
@MainActor
public final class PasskeyAuthenticator: NSObject {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?

    public override init() { super.init() }

    /// Signs in: returns the JSON body for the dashboard's `login-verify`.
    public func signIn(_ request: PasskeyRequest) async throws -> Data {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: request.rpID)
        let assertion = provider.createCredentialAssertionRequest(challenge: request.challenge)
        assertion.userVerificationPreference = .required
        if !request.allowedCredentialIDs.isEmpty {
            assertion.allowedCredentials = request.allowedCredentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }
        let result = try await perform([assertion])
        guard let credential = result.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PasskeyFailure.unexpected
        }
        return try PasskeyCodec.signInBody(
            for: request, credentialID: credential.credentialID, clientDataJSON: credential.rawClientDataJSON,
            authenticatorData: credential.rawAuthenticatorData, signature: credential.signature, userHandle: credential.userID
        )
    }

    /// Makes a passkey: returns the JSON body for the dashboard's `register-verify`.
    public func create(_ request: PasskeyRequest, name: String) async throws -> Data {
        guard let userID = request.userID else { throw PasskeyFailure.unexpected }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: request.rpID)
        let registration = provider.createCredentialRegistrationRequest(
            challenge: request.challenge, name: request.userName ?? "owner", userID: userID
        )
        registration.userVerificationPreference = .required
        let result = try await perform([registration])
        guard let credential = result.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = credential.rawAttestationObject
        else { throw PasskeyFailure.unexpected }
        return try PasskeyCodec.createBody(
            for: request, name: name, credentialID: credential.credentialID,
            clientDataJSON: credential.rawClientDataJSON, attestationObject: attestation
        )
    }

    private func perform(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        let continuation = continuation
        self.continuation = nil
        controller = nil
        continuation?.resume(with: result)
    }
}

extension PasskeyAuthenticator: ASAuthorizationControllerDelegate {
    public func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(.success(authorization))
    }

    public func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(PasskeyFailure(error)))
    }
}

extension PasskeyAuthenticator: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}
#endif

/// Why a passkey prompt did not produce a passkey, in words that say what to do.
public enum PasskeyFailure: Error, LocalizedError, Equatable {
    case cancelled
    case notAssociated
    case noPasskey
    case unsupported
    case unexpected
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "Cancelled."
        case .notAssociated:
            "iOS does not link this app to the dashboard's address yet. The dashboard has to publish its association file (NUXT_AUTH_APPLE_APPS), and the address here has to match the app's Associated Domain."
        case .noPasskey:
            "This phone has no passkey for the dashboard. Create one first."
        case .unsupported:
            "Passkeys need an iPhone."
        case .unexpected:
            "The passkey answer was not what was asked for."
        case .other(let message):
            message
        }
    }

    #if os(iOS)
    init(_ error: Error) {
        if let failure = error as? PasskeyFailure { self = failure; return }
        let nsError = error as NSError
        switch nsError.code {
        case ASAuthorizationError.canceled.rawValue: self = .cancelled
        // 1004: the app is not associated with the relying party (no entitlement, or Apple has not fetched the file)
        case ASAuthorizationError.failed.rawValue where nsError.localizedDescription.localizedCaseInsensitiveContains("associated"): self = .notAssociated
        case ASAuthorizationError.notInteractive.rawValue: self = .noPasskey
        default: self = .other(error.localizedDescription)
        }
    }
    #endif
}
