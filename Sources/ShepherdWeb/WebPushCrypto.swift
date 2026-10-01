import CryptoKit
import Foundation

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

enum WebPushError: Error {
    case invalidSubscriptionKey
}

/// RFC 8291 (`aes128gcm`) payload encryption for a single-record message.
/// `ephemeralKey` and `salt` are parameters only so the RFC's own Appendix A
/// vector can pin the output byte-for-byte in tests; production callers use
/// the random defaults.
enum WebPushEncryption {
    static let recordSize: UInt32 = 4096

    static func encrypt(
        plaintext: Data,
        userPublicKey: Data,
        authSecret: Data,
        ephemeralKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
        salt: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    ) throws -> Data {
        guard let uaPublic = try? P256.KeyAgreement.PublicKey(x963Representation: userPublicKey) else {
            throw WebPushError.invalidSubscriptionKey
        }
        let asPublic = ephemeralKey.publicKey.x963Representation

        let shared = try ephemeralKey.sharedSecretFromKeyAgreement(with: uaPublic)
        let keyInfo = Data("WebPush: info\0".utf8) + userPublicKey + asPublic
        let ikm = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: authSecret, sharedInfo: keyInfo, outputByteCount: 32
        )

        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt,
            info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16
        )
        let nonceBytes = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt,
            info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12
        ).withUnsafeBytes { Data($0) }

        // 0x02 marks this as the final (and only) record.
        let sealed = try AES.GCM.seal(
            plaintext + Data([0x02]), using: cek, nonce: AES.GCM.Nonce(data: nonceBytes)
        )

        var header = salt
        withUnsafeBytes(of: recordSize.bigEndian) { header.append(contentsOf: $0) }
        header.append(UInt8(asPublic.count))
        header.append(asPublic)
        return header + sealed.ciphertext + sealed.tag
    }
}

/// RFC 8292 VAPID: the server's long-lived identity, proving to the push
/// service (Apple/Google) that pushes to a subscription come from the same
/// app server that subscribed it.
struct VAPIDKeys {
    let privateKey: P256.Signing.PrivateKey
    let subject: String

    var publicKeyBase64URL: String {
        Base64URL.encode(privateKey.publicKey.x963Representation)
    }

    /// `Authorization` header value for a push to `endpoint`.
    func authorizationHeader(forEndpoint endpoint: URL, now: Date = Date()) throws -> String {
        guard let scheme = endpoint.scheme, let host = endpoint.host else {
            throw WebPushError.invalidSubscriptionKey
        }
        let audience = endpoint.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        let header = #"{"typ":"JWT","alg":"ES256"}"#
        let claims = #"{"aud":"\#(audience)","exp":\#(Int(now.timeIntervalSince1970) + 12 * 3600),"sub":"\#(subject)"}"#
        let signingInput = Base64URL.encode(Data(header.utf8)) + "." + Base64URL.encode(Data(claims.utf8))
        // rawRepresentation is r||s, the exact (non-DER) form JWS ES256 wants.
        let signature = try privateKey.signature(for: Data(signingInput.utf8)).rawRepresentation
        return "vapid t=\(signingInput).\(Base64URL.encode(signature)), k=\(publicKeyBase64URL)"
    }

    /// Loads the persisted key, or generates and saves one on first run -
    /// regenerating would orphan every existing phone subscription, so it
    /// must outlive process restarts.
    static func loadOrCreate(in directory: URL, subject: String) throws -> VAPIDKeys {
        let url = directory.appendingPathComponent("vapid.key")
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let raw = Base64URL.decode(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return VAPIDKeys(privateKey: key, subject: subject)
        }
        let key = P256.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Base64URL.encode(key.rawRepresentation).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return VAPIDKeys(privateKey: key, subject: subject)
    }
}
