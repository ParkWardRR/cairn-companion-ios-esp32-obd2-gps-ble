import Foundation

public enum EnrolmentProof {
    public static func message(code: String, publicKeyHex: String) -> Data {
        let normalizedCode = code.lowercased().replacingOccurrences(of: "-", with: "")
        let string = "CAIRN-ENROLL-V1\n\(normalizedCode)\n\(publicKeyHex)"
        return Data(string.utf8)
    }
}
