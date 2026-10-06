import CairnCore
import CryptoKit
import Foundation
import Testing

/// Replays the pinned contracts' sync/v1 vectors (contracts/sync/v1/vectors/) against this app's
/// request builder: the signing string, the body hash, the Authorization header and the signature.
/// The server generated them; this is the independent consumer the protocol needs to leave draft.
///
/// Not covered here yet: handling the recorded *responses* (status, error code, JSON body, the
/// 410 cursor_reset). That needs the CairnServerClient and SyncEngine (issues #2 and #5).

private func publicKey(_ x963Hex: String) -> P256.Signing.PublicKey {
    try! P256.Signing.PublicKey(x963Representation: Data(hex: x963Hex))
}

private func privateKey(_ scalarHex: String) -> P256.Signing.PrivateKey {
    try! P256.Signing.PrivateKey(rawRepresentation: Data(hex: scalarHex))
}

private func verifies(_ derBase64: String, over message: Data, key: P256.Signing.PublicKey) -> Bool {
    guard let der = Data(base64Encoded: derBase64),
          let signature = try? P256.Signing.ECDSASignature(derRepresentation: der) else { return false }
    return key.isValidSignature(signature, for: message)
}

/// `Cairn-Sig client="..",ts="..",nonce="..",sig=".."` -> its four fields.
private func parseAuthorization(_ header: String) -> [String: String]? {
    let prefix = "Cairn-Sig "
    guard header.hasPrefix(prefix) else { return nil }
    var fields: [String: String] = [:]
    for part in header.dropFirst(prefix.count).split(separator: ",") {
        guard let eq = part.firstIndex(of: "=") else { return nil }
        let key = String(part[..<eq])
        var value = String(part[part.index(after: eq)...])
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
        value = String(value.dropFirst().dropLast())
        fields[key] = value
    }
    return fields
}

@Suite struct SyncSigningVectorTests {
    private let vectors = Contracts.json("sync/v1/vectors/vectors.json")

    @Test func signingStringsAndHeaders() throws {
        let key = vectors["test_key"] as! [String: String]
        let pub = publicKey(key["public_key_x963_hex"]!)
        let signer = SoftwareSigner(clientID: key["client_id"]!, privateKey: privateKey(key["private_scalar_hex"]!))
        #expect(signer.publicKeyX963 == Data(hex: key["public_key_x963_hex"]!))

        let cases = vectors["signing"] as! [[String: Any]]
        #expect(cases.count >= 4)
        for c in cases {
            let name = c["name"] as! String
            let body = Data(hex: c["body_hex"] as! String)
            #expect(SigningString.bodyHash(body) == c["body_sha256"] as? String, "\(name): body hash")

            let string = SigningString.build(
                method: c["method"] as! String, target: c["request_target"] as! String,
                timestamp: Int(c["ts"] as! String)!, nonce: c["nonce"] as! String,
                bodyHash: SigningString.bodyHash(body), clientID: signer.clientID)
            #expect(String(decoding: string, as: UTF8.self) == c["signing_string"] as? String, "\(name): signing string")

            // The server's signature verifies under the test key, and so does ours (randomised, so verify).
            let theirs = c["signature_der_base64"] as! String
            #expect(verifies(theirs, over: string, key: pub), "\(name): recorded signature")
            let ours = try signer.sign(string).base64EncodedString()
            #expect(verifies(ours, over: string, key: pub), "\(name): our signature")

            let header = SigningString.authorizationHeader(
                clientID: signer.clientID, timestamp: Int(c["ts"] as! String)!, nonce: c["nonce"] as! String,
                signatureDER: Data(base64Encoded: theirs)!)
            #expect(header == c["authorization_header"] as? String, "\(name): header")
        }
    }

    @Test func enrolmentProof() throws {
        let key = vectors["test_key"] as! [String: String]
        let pub = publicKey(key["public_key_x963_hex"]!)
        let enrol = vectors["enrolment"] as! [String: String]
        let message = EnrolmentProof.message(code: enrol["code"]!, publicKeyHex: enrol["public_key_hex"]!)
        #expect(String(decoding: message, as: UTF8.self) == enrol["proof_message"])
        #expect(verifies(enrol["proof_der_base64"]!, over: message, key: pub))
    }
}

@Suite struct SyncExchangeVectorTests {
    private let file = Contracts.json("sync/v1/vectors/exchanges.json")

    /// Every signed or bearer step, in file order, against the client it names.
    @Test func requestsAreBuiltTheWayTheServerExpects() throws {
        let fixture = file["fixture"] as! [String: Any]
        let clients = fixture["clients"] as! [[String: Any]]
        let steps = file["steps"] as! [[String: Any]]
        #expect(steps.count >= 83)

        var signedSteps = 0
        for step in steps {
            let name = step["name"] as! String
            let request = step["request"] as! [String: Any]
            let headers = request["headers"] as? [String: String] ?? [:]

            guard let signing = step["signing"] as? [String: Any] else {
                // Unsigned: enrolment, health, bearer. Nothing in the signing path to check, but a
                // bearer step must carry a bearer header and never a Cairn-Sig one.
                if step["auth"] as? String == "bearer" {
                    #expect(headers["Authorization"]?.hasPrefix("Bearer ") == true, "\(name): bearer header")
                }
                continue
            }
            signedSteps += 1

            let body = Data(hex: request["body_hex"] as? String ?? "")
            let clientID = signing["client_id"] as! String
            let ts = signing["ts"] as! String
            let nonce = signing["nonce"] as! String
            let matches = signing["matches_request"] as! Bool

            // The string rebuilt from the request AS SENT. It equals the recorded one exactly when
            // the request is the one that was signed; a tampered target or body must not.
            let rebuilt = String(decoding: SigningString.build(
                method: request["method"] as! String, target: request["request_target"] as! String,
                timestamp: Int(ts)!, nonce: nonce, bodyHash: SigningString.bodyHash(body), clientID: clientID),
                as: UTF8.self)
            if matches {
                #expect(rebuilt == signing["signing_string"] as? String, "\(name): signing string")
                #expect(SigningString.bodyHash(body) == signing["body_sha256"] as? String, "\(name): body hash")
            } else {
                #expect(rebuilt != signing["signing_string"] as? String, "\(name): tamper must change the string")
            }

            // The recorded signature verifies (or not) under the client's registered key.
            let signingString = Data((signing["signing_string"] as! String).utf8)
            let signature = signing["signature_der_base64"] as! String
            if let client = clients.first(where: { $0["client_id"] as? String == clientID }) {
                let pub = publicKey(client["public_key_x963_hex"] as! String)
                #expect(verifies(signature, over: signingString, key: pub) == (signing["signature_valid"] as! Bool),
                        "\(name): recorded signature validity")
                // And our signer, given the same key, produces a signature that verifies over the same string.
                let signer = SoftwareSigner(clientID: clientID, privateKey: privateKey(client["private_scalar_hex"] as! String))
                let ours = try signer.sign(signingString).base64EncodedString()
                #expect(verifies(ours, over: signingString, key: pub), "\(name): our signature")
            }

            // The Authorization header is byte-exact: our builder, given the recorded signature, gives the same line.
            if let header = headers["Authorization"], let fields = parseAuthorization(header) {
                #expect(fields["client"] == clientID && fields["ts"] == ts && fields["nonce"] == nonce, "\(name): header fields")
                #expect(fields["sig"] == signature, "\(name): header signature")
                let built = SigningString.authorizationHeader(
                    clientID: clientID, timestamp: Int(ts)!, nonce: nonce, signatureDER: Data(base64Encoded: signature)!)
                #expect(built == header, "\(name): header bytes")
            }
        }
        #expect(signedSteps >= 60, "expected at least 60 signed steps, found \(signedSteps)")
    }
}
