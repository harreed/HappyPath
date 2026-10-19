import Foundation
import Security
import CryptoKit

/// Apple Account passwords live in the current user's local login Keychain.
/// Test projects and run artifacts contain only the account identifier.
public struct AppleAccountSecretStore: Sendable {
    private let service = "dev.agentic.TestWorkbench.apple-account-password"
    public init() {}

    private func accountKey(_ account: String) throws -> String {
        let value = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.contains("@"), value.count < 256 else { throw SecretStoreError.invalidAccount }
        return value
    }

    private func query(_ account: String) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: try accountKey(account),
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    public func save(_ password: String, for account: String) throws {
        guard !password.isEmpty else { throw SecretStoreError.emptySecret }
        var item = try query(account)
        item[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: Data(password.utf8)]
            let updated = SecItemUpdate(try query(account) as CFDictionary, update as CFDictionary)
            guard updated == errSecSuccess else { throw SecretStoreError.keychain(updated) }
        } else if status != errSecSuccess {
            throw SecretStoreError.keychain(status)
        }
    }

    public func password(for account: String) throws -> String? {
        var item = try query(account)
        item[kSecReturnData as String] = kCFBooleanTrue
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.keychain(status)
        }
        return password
    }

    /// Resolve the account saved in a project's Resources screen. Its metadata
    /// is in resources.json, while both username and password stay in Keychain.
    public func password(for account: String, projectID: UUID, projectDirectory: URL) throws -> String? {
        let resourceFile = projectDirectory.appendingPathComponent("resources.json")
        guard FileManager.default.fileExists(atPath: resourceFile.path) else {
            return try password(for: account)
        }
        struct Resources: Decodable {
            struct Credential: Decodable { let id: UUID; let name: String; let kind: String }
            let credentials: [Credential]
        }
        let resources = try JSONDecoder().decode(Resources.self, from: Data(contentsOf: resourceFile))
        let scope = SHA256.hash(data: Data(projectDirectory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let normalizedAccount = try accountKey(account)
        func read(_ id: UUID, _ field: String) throws -> String? {
            let key = "\(projectID.uuidString).\(scope).\(id.uuidString).\(field)"
            let item: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.agentic.TestWorkbench.resources",
                kSecAttrAccount as String: key,
                kSecReturnData as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(item as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.keychain(status)
            }
            return value
        }
        var matches: [String?] = []
        for credential in resources.credentials where credential.kind == "Account" &&
            credential.name.localizedCaseInsensitiveCompare("Apple Account") == .orderedSame {
            guard let username = try read(credential.id, "username"),
                  username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedAccount else { continue }
            let value = try read(credential.id, "value")
            matches.append(value?.isEmpty == false ? value : nil)
        }
        guard matches.count <= 1 else { throw SecretStoreError.ambiguousAccount }
        if let match = matches.first { return match }
        return try password(for: account)
    }

    public func remove(for account: String) throws {
        let status = SecItemDelete(try query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
    }
}

public enum SecretStoreError: LocalizedError {
    case invalidAccount, emptySecret, ambiguousAccount, keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .invalidAccount: "Enter a valid Apple Account email address."
        case .emptySecret: "Enter a password before saving."
        case .ambiguousAccount: "More than one Apple Account credential matches this email in project Resources."
        case .keychain(let status): "Keychain operation failed (\(status))."
        }
    }
}
