import CryptoKit
import Foundation

public enum SigningString {
    public static func build(
        method: String,
        target: String,
        timestamp: Int,
        nonce: String,
        bodyHash: String,
        clientID: String
    ) -> Data {
        let string = """
            CAIRN-SIG-V1
            \(method)
            \(target)
            \(timestamp)
            \(nonce)
            \(bodyHash)
            \(clientID)
            """
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return Data(string.utf8)
    }

    public static func bodyHash(_ body: Data) -> String {
        let digest = SHA256.hash(data: body)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func authorizationHeader(
        clientID: String,
        timestamp: Int,
        nonce: String,
        signatureDER: Data
    ) -> String {
        let sig = signatureDER.base64EncodedString()
        return "Cairn-Sig client=\"\(clientID)\",ts=\"\(timestamp)\",nonce=\"\(nonce)\",sig=\"\(sig)\""
    }

    public static func freshNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
