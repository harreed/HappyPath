import XCTest
import SimulatorControl
import CryptoKit
import Security

final class AppleAccountSecretStoreTests: XCTestCase {
    func testPasswordRoundTripsThroughKeychainAndCanBeRemoved() throws {
        let store = AppleAccountSecretStore()
        let account = "test-\(UUID().uuidString)@example.invalid"
        let password = UUID().uuidString
        defer { try? store.remove(for: account) }
        XCTAssertNil(try store.password(for: account))
        try store.save(password, for: account)
        XCTAssertEqual(try store.password(for: account), password)
        try store.remove(for: account)
        XCTAssertNil(try store.password(for: account))
    }

    func testProjectResourcesAppleAccountResolvesByEmail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID(), credentialID = UUID()
        let account = "project-\(UUID().uuidString)@example.invalid"
        let password = UUID().uuidString
        let resources = "{\"credentials\":[{\"id\":\"\(credentialID.uuidString)\",\"name\":\"Apple Account\",\"kind\":\"Account\",\"note\":\"\"}]}"
        try Data(resources.utf8).write(to: directory.appendingPathComponent("resources.json"))
        let scope = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        func key(_ field: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: "dev.agentic.TestWorkbench.resources",
             kSecAttrAccount as String: "\(projectID.uuidString).\(scope).\(credentialID.uuidString).\(field)"]
        }
        for (field, value) in [("username", account), ("value", password)] {
            var item = key(field)
            item[kSecValueData as String] = Data(value.utf8)
            XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        }
        defer {
            SecItemDelete(key("username") as CFDictionary)
            SecItemDelete(key("value") as CFDictionary)
        }
        let store = AppleAccountSecretStore()
        XCTAssertEqual(try store.password(for: account, projectID: projectID,
            projectDirectory: directory), password)
        XCTAssertNil(try store.password(for: "other@example.invalid", projectID: projectID,
            projectDirectory: directory))
    }
}
