import Foundation
import Security

public enum ClefCredentialStore {
    private static let service = "dev.agentic.TestWorkbench.clef"

    private static func stored(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func resolved(_ environment: String, account: String) -> String? {
        let value = (ProcessInfo.processInfo.environment[environment] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? stored(account) : value
    }

    public static var accountID: String? { resolved("CLOUDFLARE_ACCOUNT_ID", account: "account-id") }
    public static var apiToken: String? { resolved("CLOUDFLARE_API_TOKEN", account: "api-token") }
    public static var hasCredentials: Bool { accountID != nil && apiToken != nil }

    public static func save(accountID: String, apiToken: String) throws {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty, !apiToken.isEmpty else { throw CredentialError.empty }
        try set(account: "account-id", value: accountID)
        try set(account: "api-token", value: apiToken)
    }

    private static func set(account: String, value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialError.keychain(status) }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw CredentialError.keychain(added) }
    }

    public static func remove() throws {
        for account in ["account-id", "api-token"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecAttrAccount as String: account]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
        }
    }

    public enum CredentialError: LocalizedError {
        case empty, keychain(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .empty: "Enter a Cloudflare account ID and Workers AI token."
            case .keychain(let status): "Keychain could not update Clef credentials (status \(status))."
            }
        }
    }
}
