import XCTest
import ProjectDomain

final class ProjectEditingTests: XCTestCase {
    func fixture() -> TestProject {
        .init(name: "Editing", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "dev.test.App"), simulator: .init(deviceID: "sim"), categories: [.init(name: "Account", suites: [.init(name: "Sign in", setup: [.init(title: "Launch", action: .relaunch)], tests: [.init(name: "First", goal: "Sign in", blocks: [.init(title: "Tap", action: .tap(targets: [.identifier("login")]))]), .init(name: "Second", blocks: [])], teardown: [.init(title: "Reset", action: .relaunch)])])])
    }
    func testEditingAndOrderingPreserveIdentityAndUntouchedDefinitions() throws {
        let original = fixture(), suite = original.categories[0].suites[0]
        let edited = original.updatingTest(suite.tests[0].id) { $0.replacing(name: "Renamed", goal: "New goal") }.updatingSuite(suite.id) { $0.replacing(tests: $0.tests.moving(suite.tests[1].id, by: -1)) }
        XCTAssertEqual(original.categories[0].suites[0].tests[0].name, "First")
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.categories[0].suites[0].tests.map(\.id), suite.tests.reversed().map(\.id))
        XCTAssertEqual(edited.categories[0].suites[0].tests[1].blocks, suite.tests[0].blocks)
        XCTAssertEqual(edited.categories[0].suites[0].setup, suite.setup)
        try edited.validate()
    }
    func testDeepDuplicationAllocatesEveryIdentityAndRoundTrips() throws {
        let original = fixture(), copy = original.categories[0].duplicated()
        let duplicated = original.replacing(categories: original.categories + [copy])
        try duplicated.validate() // catches any shared category/suite/test/block UUID
        XCTAssertEqual(copy.suites[0].tests[0].blocks[0].action, original.categories[0].suites[0].tests[0].blocks[0].action)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".uitestproject")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectBundleStore().save(duplicated, to: url)
        XCTAssertEqual(try ProjectBundleStore().load(from: url), duplicated)
    }
    func testDeletionAndInvalidReorderDoNotDamageSiblings() {
        let original = fixture(), suite = original.categories[0].suites[0]
        XCTAssertEqual(suite.tests.moving(suite.tests[0].id, by: -1), suite.tests)
        XCTAssertEqual(original.deleting(suite.tests[0].id).categories[0].suites[0].tests, [suite.tests[1]])
        XCTAssertEqual(original.deleting(suite.id).categories[0].suites, [])
        XCTAssertEqual(original.deleting(original.categories[0].id).categories, [])
    }
}
