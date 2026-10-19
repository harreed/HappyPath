import XCTest
import CryptoKit
import RunnerCore

final class SecureInputCryptoTests: XCTestCase {
    func testSecretIsEncryptedForBoundCaptureOnly() throws {
        let companionKey = Curve25519.KeyAgreement.PrivateKey()
        let capture = CaptureID()
        let password = Data("fixture-secret-never-in-events".utf8)
        let envelope = try SecureInputCrypto.seal(password, for: capture,
            recipientPublicKey: companionKey.publicKey.rawRepresentation)
        let encoded = try JSONEncoder().encode(envelope)
        XCTAssertFalse(String(data: encoded, encoding: .utf8)!.contains("fixture-secret"))
        XCTAssertEqual(try SecureInputCrypto.open(envelope, for: capture,
            recipientPrivateKey: companionKey), password)
        XCTAssertThrowsError(try SecureInputCrypto.open(envelope, for: CaptureID(),
            recipientPrivateKey: companionKey))
    }
}
