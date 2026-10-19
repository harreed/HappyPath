import Foundation
import XCTest
import RunnerCore
@testable import SimulatorControl

final class CompanionConfigurationTests: XCTestCase {
    func testSemanticRequestsRequireCaptureAndRejectMixedTargets() throws {
        var request = CompanionRequest(sessionID: UUID(), operation: .tap, bundleID: "org.app")
        request.semanticTarget = .init(role: "button", label: "Apply", value: nil)
        XCTAssertThrowsError(try request.validate())
        request.captureID = CaptureID()
        XCTAssertNoThrow(try request.validate())
        request.identifier = "another-target"
        XCTAssertThrowsError(try request.validate())
        request.identifier = nil
        request.semanticTarget = .init(role: "", label: "Apply", value: nil)
        XCTAssertThrowsError(try request.validate())
    }
    func testRunLocalConfigurationChangesTargetWithoutMutatingSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original: [String: Any] = ["TestConfigurations": [["TestTargets": [[
            "TestBundlePath": "__TESTROOT__/Runner.app/PlugIns/Test.xctest",
            "EnvironmentVariables": ["COMPANION_TARGET_BUNDLE_ID": "old", "KEEP": "yes"]
        ]]]]]
        let source = directory.appendingPathComponent("input.xctestrun")
        let bytes = try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
        try bytes.write(to: source)
        let destination = directory.appendingPathComponent("output.xctestrun")
        try CompanionTestConfiguration.write(source: source, destination: destination, targetBundleID: "another.app")
        let result = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: destination), format: nil) as? [String: Any])
        let configurations = try XCTUnwrap(result["TestConfigurations"] as? [[String: Any]])
        let targets = try XCTUnwrap(configurations[0]["TestTargets"] as? [[String: Any]])
        let env = try XCTUnwrap(targets[0]["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(env["COMPANION_TARGET_BUNDLE_ID"], "another.app")
        XCTAssertEqual(env["COMPANION_SERVICE_ENABLED"], "1")
        XCTAssertEqual(env["KEEP"], "yes")
        XCTAssertEqual(targets[0]["TestBundlePath"] as? String, directory.path + "/Runner.app/PlugIns/Test.xctest")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
}
