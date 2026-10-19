import Foundation
import Security

/// A machine-local credential, never stored with a project or run.
public enum JevCredentialStore {
    private static let service = "dev.agentic.TestWorkbench.jev"
    private static let account = "typesafe-api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static var apiKey: String? {
        let environment = (ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !environment.isEmpty { return environment }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    public static var hasCredential: Bool { apiKey != nil }

    public static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CredentialError.empty }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialError.keychain(status) }
        var item = query
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
    }

    public static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }

    public enum CredentialError: LocalizedError {
        case empty, keychain(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .empty: "Enter a Jev API key."
            case .keychain(let status): "Keychain could not update the Jev API key (status \(status))."
            }
        }
    }
}
