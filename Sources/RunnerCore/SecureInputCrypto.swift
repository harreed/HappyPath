import Foundation
import CryptoKit

/// Encrypts a Keychain secret for one capture in one companion session.
/// Only the companion's in-memory private key can open the mailbox payload.
public enum SecureInputCrypto {
    private static let salt = Data("TestWorkbench-SecureInput-v1".utf8)

    public static func seal(_ secret: Data, for captureID: CaptureID,
                            recipientPublicKey: Data) throws -> EncryptedSecret {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data(), outputByteCount: 32)
        let box = try AES.GCM.seal(secret, using: key,
            authenticating: Data(captureID.description.utf8))
        guard let combined = box.combined else { throw CompanionFailure.invalidRequest }
        return EncryptedSecret(senderPublicKey: ephemeral.publicKey.rawRepresentation,
            sealedBox: combined)
    }

    public static func open(_ envelope: EncryptedSecret, for captureID: CaptureID,
                            recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        let sender = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.senderPublicKey)
        let shared = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: sender)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data(), outputByteCount: 32)
        let box = try AES.GCM.SealedBox(combined: envelope.sealedBox)
        return try AES.GCM.open(box, using: key,
            authenticating: Data(captureID.description.utf8))
    }
}
