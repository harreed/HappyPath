import Foundation
import FoundationModels
import ClaudeForFoundationModels
import RunnerCore
import Security

/// Shared model choice for planning, navigation, goal assessment, and summaries.
/// Claude is the default; on-device remains an explicit offline option.
enum AppleModelRuntime {
    static var usesOnDevice: Bool {
        ProcessInfo.processInfo.environment["AGENTIC_APPLE_MODEL"]?.lowercased() == "on-device"
    }

    static var providerID: String {
        usesOnDevice ? "apple.foundationmodels.on-device.semantic-text" : "anthropic.claude-haiku-5-5.semantic-text"
    }

    static var availability: PlanningAvailability {
        if usesOnDevice { return ApplePlanGenerator.onDeviceAvailability }
        guard #available(macOS 27.0, *) else { return .unavailable("Claude through Foundation Models requires macOS 27.") }
        guard ClaudeCredentialStore.apiKey != nil else {
            return .unavailable("Add a Claude API key in Provider Settings or set ANTHROPIC_API_KEY.")
        }
        return .available
    }

    @available(macOS 26.0, *)
    static func session(instructions: String) throws -> LanguageModelSession {
        if usesOnDevice { return LanguageModelSession(instructions: instructions) }
        guard #available(macOS 27.0, *), let key = ClaudeCredentialStore.apiKey else { throw ProviderFailure.unavailable }
        let model = ClaudeLanguageModel(name: .haiku5_5, auth: .apiKey(key))
        return LanguageModelSession(model: model, instructions: instructions)
    }
}

/// Local key for the ad-hoc macOS app. Never persists in a project or run artifact.
public enum ClaudeCredentialStore {
    private static let service = "dev.agentic.TestWorkbench.claude"
    private static let account = "anthropic-api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static var hasCredential: Bool { apiKey != nil }

    static var apiKey: String? {
        let environment = (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
            case .empty: "Enter a Claude API key."
            case .keychain(let status): "Keychain could not update the Claude API key (status \(status))."
            }
        }
    }
}
