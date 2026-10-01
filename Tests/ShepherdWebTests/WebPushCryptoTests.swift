import CryptoKit
import Foundation
import Testing
@testable import ShepherdWeb

// Every value below is from RFC 8291 Appendix A.
private let rfcPlaintext = "V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24"
private let rfcAsPrivate = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
private let rfcUaPublic = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
private let rfcAuthSecret = "BTBZMqHH6r4Tts7J_aSIgg"
private let rfcSalt = "DGv6ra1nlYgDCS1FRnbzlw"
private let rfcUaPrivate = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
private let rfcEcdhSecret = "kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs"
private let rfcBody = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

@Test func base64URLRoundTripsWithoutPadding() {
    let data = Data([0xfb, 0xff, 0xfe, 0x01])
    let encoded = Base64URL.encode(data)
    #expect(!encoded.contains("="))
    #expect(!encoded.contains("+") && !encoded.contains("/"))
    #expect(Base64URL.decode(encoded) == data)
}

@Test func encryptionMatchesRFC8291AppendixA() throws {
    let body = try WebPushEncryption.encrypt(
        plaintext: Base64URL.decode(rfcPlaintext)!,
        userPublicKey: Base64URL.decode(rfcUaPublic)!,
        authSecret: Base64URL.decode(rfcAuthSecret)!,
        ephemeralKey: try P256.KeyAgreement.PrivateKey(rawRepresentation: Base64URL.decode(rfcAsPrivate)!),
        salt: Base64URL.decode(rfcSalt)!
    )
    #expect(Base64URL.encode(body) == rfcBody)
}

@Test func encryptionRejectsAMalformedSubscriptionKey() {
    #expect(throws: WebPushError.self) {
        try WebPushEncryption.encrypt(plaintext: Data("x".utf8), userPublicKey: Data([1, 2, 3]), authSecret: Data(count: 16))
    }
}

@Test func vapidAuthorizationHeaderCarriesAVerifiableES256Signature() throws {
    let keys = VAPIDKeys(privateKey: P256.Signing.PrivateKey(), subject: "https://example.test/")
    let header = try keys.authorizationHeader(
        forEndpoint: URL(string: "https://push.example.test/send/abc")!,
        now: Date(timeIntervalSince1970: 1_000_000)
    )
    #expect(header.hasPrefix("vapid t="))
    #expect(header.hasSuffix(", k=\(keys.publicKeyBase64URL)"))

    let jwt = String(header.dropFirst("vapid t=".count).prefix { $0 != "," })
    let parts = jwt.split(separator: ".").map(String.init)
    #expect(parts.count == 3)

    let claims = try JSONSerialization.jsonObject(with: Base64URL.decode(parts[1])!) as! [String: Any]
    #expect(claims["aud"] as? String == "https://push.example.test")
    #expect(claims["sub"] as? String == "https://example.test/")
    #expect(claims["exp"] as? Int == 1_000_000 + 12 * 3600)

    let signature = try P256.Signing.ECDSASignature(rawRepresentation: Base64URL.decode(parts[2])!)
    #expect(keys.privateKey.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
}

@Test func vapidKeyPersistsAcrossLoads() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vapid-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = try VAPIDKeys.loadOrCreate(in: dir, subject: "s")
    let second = try VAPIDKeys.loadOrCreate(in: dir, subject: "s")
    #expect(first.publicKeyBase64URL == second.publicKeyBase64URL)
}

@Test func ecdhSecretMatchesRFC8291AppendixA() throws {
    let asPrivate = try P256.KeyAgreement.PrivateKey(rawRepresentation: Base64URL.decode(rfcAsPrivate)!)
    let uaPublic = try P256.KeyAgreement.PublicKey(x963Representation: Base64URL.decode(rfcUaPublic)!)
    let secret = try asPrivate.sharedSecretFromKeyAgreement(with: uaPublic).withUnsafeBytes { Data($0) }
    #expect(Base64URL.encode(secret) == rfcEcdhSecret)
}

// What the browser does on receipt: derive the same keys from the
// *receiver's* side (ua_private + the sender's public key carried in the
// header), then open the record - an independent check of the framing.
@Test func browserSideDecryptionRecoversThePlaintext() throws {
    let plaintext = Data("tests are blocked on you".utf8)
    let uaPrivate = P256.KeyAgreement.PrivateKey()
    let authSecret = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let uaPublic = uaPrivate.publicKey.x963Representation

    let body = try WebPushEncryption.encrypt(plaintext: plaintext, userPublicKey: uaPublic, authSecret: authSecret)

    let salt = body.prefix(16)
    #expect(body[16..<20] == Data([0, 0, 0x10, 0]))
    let idLength = Int(body[20])
    let asPublic = body[21..<(21 + idLength)]
    let record = body.dropFirst(21 + idLength)

    let shared = try uaPrivate.sharedSecretFromKeyAgreement(
        with: P256.KeyAgreement.PublicKey(x963Representation: asPublic)
    )
    let ikm = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: authSecret,
        sharedInfo: Data("WebPush: info\0".utf8) + uaPublic + asPublic, outputByteCount: 32
    )
    let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Data(salt), info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
    let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Data(salt), info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        .withUnsafeBytes { Data($0) }

    let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce),
        ciphertext: record.dropLast(16),
        tag: record.suffix(16)
    )
    let opened = try AES.GCM.open(box, using: cek)
    #expect(opened.last == 0x02)
    #expect(opened.dropLast() == plaintext)
}
