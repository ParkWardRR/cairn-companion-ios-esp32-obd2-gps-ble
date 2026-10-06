import CairnCore
import CryptoKit
import Foundation

public final class SecureEnclaveKeyProvider: KeyProvider, @unchecked Sendable {
    private static let tag = "app.cairn.companion.identity"
    private let privateKey: SecureEnclave.P256.Signing.PrivateKey

    public var publicKeyX963: Data {
        Data(privateKey.publicKey.x963Representation)
    }

    public var publicKeyHex: String {
        publicKeyX963.map { String(format: "%02x", $0) }.joined()
    }

    public init() throws {
        if let existing = try Self.loadFromKeychain(tag: Self.tag) {
            self.privateKey = existing
        } else {
            self.privateKey = try SecureEnclave.P256.Signing.PrivateKey(
                accessControl: SecAccessControlCreateWithFlags(
                    nil,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    [],
                    nil
                )!
            )
            try Self.saveToKeychain(privateKey, tag: Self.tag)
        }
    }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data).derRepresentation
    }

    public func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.tag,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func loadFromKeychain(tag: String) throws -> SecureEnclave.P256.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecReturnRef as String: true,
        ]
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        guard status == errSecSuccess else { return nil }
        guard let secKey = ref else { return nil }
        return try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: SecKeyCopyExternalRepresentation(secKey as! SecKey, nil)! as Data
        )
    }

    private static func saveToKeychain(_ key: SecureEnclave.P256.Signing.PrivateKey, tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecValueRef as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
    }
}
