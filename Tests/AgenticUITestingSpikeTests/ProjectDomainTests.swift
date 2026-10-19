import Foundation
import XCTest
import ProjectDomain

final class ProjectDomainTests: XCTestCase {
    func testStartingStateDefaultsForOlderProjectsAndSurvivesEdits() throws {
        let original = ProjectDomain.TestCase(name: "Goal", blocks: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "startingState")
        let old = try JSONDecoder().decode(ProjectDomain.TestCase.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.startingState.isDefault)
        let requested = TestStartingState(appData: .reinstall, permissions: .reset, appearance: .dark, keychain: .resetSimulator)
        let edited = old.replacing(startingState: requested).replacing(name: "Renamed")
        XCTAssertEqual(edited.startingState, requested)
        XCTAssertEqual(edited.duplicated().startingState, requested)
        XCTAssertEqual(try JSONDecoder().decode(ProjectDomain.TestCase.self, from: JSONEncoder().encode(edited)).startingState, requested)
    }
    func testInvalidRetryExplainsBoundsAndPreservesSavedDefinition() throws {
        let block = TestBlock(title: "Tap", action: .tap(targets: [.identifier("continue")]))
        let valid = project(tests: [.init(name: "Flow", blocks: [block])])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectBundleStore()
        try store.save(valid, to: directory)
        let before = try Data(contentsOf: directory.appendingPathComponent("project.json"))
        let testID = valid.categories[0].suites[0].tests[0].id
        let invalid = valid.updatingTest(testID) { $0.updatingBlock(block.id) { $0.replacing(retryPolicy: .init(maximumAttempts: 0)) } }
        XCTAssertThrowsError(try store.save(invalid, to: directory)) { error in
            XCTAssertEqual(error.localizedDescription, "Maximum attempts must be between 1 and 100.")
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("project.json")), before)
        XCTAssertEqual(try store.load(from: directory), valid)
    }
    private func project(tests: [ProjectDomain.TestCase], version: Int = TestProject.currentSchemaVersion) -> TestProject {
        TestProject(schemaVersion: version, name: "Example", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.example.app"), simulator: .init(deviceID: "device"), categories: [.init(name: "Category", suites: [.init(name: "Suite", tests: tests)])])
    }
    func testAllBlockKindsRoundTripAndStableBytes() throws {
        let target = TargetStrategy.identifier("button")
        let actions: [BlockAction] = [.tap(targets: [target]), .typeText("hello", targets: [.semantic(role: "TextField", label: "Name", value: nil)]), .swipe(.up, targets: []), .wait(.exists(target)), .relaunch, .assertion(.textVisible("Done"))]
        let p = project(tests: [.init(name: "Flow", blocks: actions.map { .init(title: "Step", action: $0) })])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectBundleStore()
        try store.save(p, to: directory)
        let before = try Data(contentsOf: directory.appendingPathComponent("project.json"))
        XCTAssertEqual(try store.load(from: directory), p)
        try store.save(p, to: directory)
        XCTAssertEqual(before, try Data(contentsOf: directory.appendingPathComponent("project.json")))
    }
    func testSelectionPreservesHierarchyOrderAndRejectsMissingIDs() throws {
        let a = ProjectDomain.TestCase(name: "A", blocks: [])
        let b = ProjectDomain.TestCase(name: "B", blocks: [])
        let p = project(tests: [a, b])
        XCTAssertEqual(try p.selectedTests(.selection([b.id, a.id])).map(\.test.id), [a.id, b.id])
        XCTAssertEqual(try p.selectedTests(.test(b.id)).map(\.test.id), [b.id])
        XCTAssertEqual(try p.selectedTests(.suite(p.categories[0].suites[0].id)).count, 2)
        XCTAssertEqual(try p.selectedTests(.category(p.categories[0].id)).count, 2)
        XCTAssertEqual(try p.selectedTests(.all).count, 2)
        XCTAssertThrowsError(try p.selectedTests(.selection([UUID()])))
    }
    func testRejectsDuplicateIdentityAndInvalidTimeout() throws {
        let a = ProjectDomain.TestCase(name: "A", blocks: [])
        XCTAssertThrowsError(try project(tests: [a, a]).validate())
        let invalid = TestBlock(title: "Bad", action: .relaunch, retryPolicy: .init(timeoutSeconds: -.infinity))
        XCTAssertThrowsError(try project(tests: [.init(name: "Bad", blocks: [invalid])]).validate())
        let empty = TestBlock(title: "Bad", action: .tap(targets: []))
        XCTAssertThrowsError(try project(tests: [.init(name: "Bad", blocks: [empty])]).validate())
    }
    func testFutureSchemaFailsBeforeBodyDecoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"schemaVersion\":999}".utf8).write(to: directory.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try ProjectBundleStore().load(from: directory)) { XCTAssertEqual($0 as? ProjectValidationError, .unsupportedVersion(999)) }
    }
    func testRejectsProductAndMailboxPathEscapes() throws {
        for name in ["../Other.app", "folder/App.app", "folder\\App.app", ".."] {
            let p = TestProject(name: "Bad path", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.app", productName: name), simulator: .init(deviceID: "device"), categories: [])
            XCTAssertThrowsError(try p.validate())
        }
        let companion = CompanionConfiguration(projectPath: "App.xcodeproj", scheme: "Companion", testIdentifier: "Tests/serve", runnerBundleIdentifier: "org.runner", mailboxRelativePath: "../outside")
        let p = TestProject(name: "Bad mailbox", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.app", companion: companion), simulator: .init(deviceID: "device"), categories: [])
        XCTAssertThrowsError(try p.validate())
    }
}
