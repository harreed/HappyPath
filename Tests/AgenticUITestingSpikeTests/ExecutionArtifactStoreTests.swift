import Foundation
import XCTest
import ProjectDomain
import RunnerCore
import ArtifactStore

final class ExecutionArtifactStoreTests: XCTestCase {
    private func project() -> TestProject {
        .init(name: "Evidence", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.example.app"), simulator: .init(deviceID: "device"), categories: [])
    }
    func testDurableOrderingPrecisionSnapshotAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("run")
        let definition = project()
        let store = try ExecutionArtifactStore(directory: directory, project: definition, selection: .all)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000.123)
        let first = try await store.append(.state(.preparing), timestamp: timestamp)
        XCTAssertEqual(first.sequence, 1)
        let readBeforeFinish = try ExecutionArtifactStore.readEvents(in: directory)
        XCTAssertEqual(readBeforeFinish.count, 1)
        XCTAssertEqual(readBeforeFinish[0].timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.00001)
        XCTAssertEqual(try ProjectBundleStore().load(from: directory), definition)
        _ = try await store.append(.diagnostic("Failure | detail\nNext line"))
        let report = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"blocked\",\"tests\":[]}".utf8))
        try await store.finish(report)
        do { _ = try await store.append(.state(.finished)); XCTFail("Closed log accepted event") } catch ExecutionArtifactError.finalized { }
        XCTAssertEqual(try ExecutionArtifactStore.readEvents(in: directory).map(\.sequence), [1, 2])
        let markdown = try String(contentsOf: directory.appendingPathComponent("report.md"))
        XCTAssertTrue(markdown.contains("blocked"))
        XCTAssertTrue(markdown.contains("Failure \\| detail Next line"))
        let export = root.appendingPathComponent("export")
        try ExecutionArtifactStore.export(directory: directory, to: export)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("events.jsonl")), try Data(contentsOf: export.appendingPathComponent("events.jsonl")))
        XCTAssertThrowsError(try ExecutionArtifactStore.export(directory: directory, to: export))
        XCTAssertThrowsError(try ExecutionArtifactStore(directory: directory, project: definition, selection: .all))
    }
    func testTamperedSequenceIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ExecutionArtifactStore(directory: directory, project: project(), selection: .all)
        _ = try await store.append(.state(.preparing))
        let url = directory.appendingPathComponent("events.jsonl")
        let original = try String(contentsOf: url)
        try original.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":2").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ExecutionArtifactStore.readEvents(in: directory))
    }
    func testPreparationFailureReportListsSelectedUnexecutedTestsAsPending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let definition = project().replacing(categories: [.init(name: "Category", suites: [.init(name: "Suite", tests: [.init(name: "Never started", blocks: [])])])])
        let store = try ExecutionArtifactStore(directory: directory, project: definition, selection: .all)
        let terminal = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"blocked\",\"tests\":[]}".utf8))
        try await store.append(.finished(terminal))
        try await store.finish(terminal)
        let text = try String(contentsOf: directory.appendingPathComponent("report.md"))
        XCTAssertTrue(text.contains("Selected tests: 1. Completed results: 0."))
        XCTAssertTrue(text.contains("| Category / Suite / Never started | Pending | — |"))
        XCTAssertTrue(text.contains("Outcome: **blocked**"))
    }
    func testReportUsesTitlesAndBindsCaptureLinksToSuccessfulAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let block = TestBlock(title: "Open dashboard", action: .tap(targets: [.identifier("dashboard")]))
        let definition = project().replacing(categories: [.init(name: "General", suites: [.init(name: "Smoke", tests: [.init(name: "Dashboard", blocks: [block])])])])
        let store = try ExecutionArtifactStore(directory: directory, project: definition, selection: .all)
        let before = CaptureID(), after = CaptureID()
        let testID = definition.categories[0].suites[0].tests[0].id
        _ = try await store.append(.testStarted(testID), timestamp: Date(timeIntervalSince1970: 100))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("captures"), withIntermediateDirectories: true)
        for id in [before, after] { try Data().write(to: directory.appendingPathComponent("captures/\(id.description).png")) }
        _ = try await store.append(.blockStarted(block.id))
        _ = try await store.append(.capture(.init(captureID: before, capturedAt: Date(), elements: [])))
        _ = try await store.append(.action(block.id, .tap(identifier: "dashboard")))
        _ = try await store.append(.capture(.init(captureID: after, capturedAt: Date(), elements: [])))
        _ = try await store.append(.assertion(.textVisible("Dashboard"), true))
        _ = try await store.append(.blockFinished(block.id, .passed, duration: 0.5, reason: nil))
        _ = try await store.append(.testFinished(testID, .passed), timestamp: Date(timeIntervalSince1970: 102))
        let review = try ExecutionReview(project: definition, selection: .all, events: ExecutionArtifactStore.readEvents(in: directory))
        XCTAssertEqual(review.count(.passed), 1)
        XCTAssertEqual(review.tests[0].duration, 2)
        XCTAssertEqual(review.tests[0].blocks[0].before, before)
        XCTAssertEqual(review.tests[0].blocks[0].after, after)
        let report = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"passed\",\"tests\":[]}".utf8))
        try await store.finish(report)
        let markdown = try String(contentsOf: directory.appendingPathComponent("report.md"))
        XCTAssertTrue(markdown.contains("[Open dashboard — before](captures/\(before.description).png)"))
        XCTAssertTrue(markdown.contains("[Open dashboard — after](captures/\(after.description).png)"))
        XCTAssertTrue(markdown.contains("Text is visible: ‘Dashboard’: passed"))
        XCTAssertFalse(markdown.contains(block.id.uuidString))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("artifact-format.json"))
        XCTAssertThrowsError(try ExecutionArtifactStore.readEvents(in: directory))
    }
    func testLaterActionWithoutEvidenceDoesNotReuseEarlierAfterCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let block = TestBlock(title: "Multi-action evidence", action: .relaunch)
        let test = ProjectDomain.TestCase(name: "Flow", blocks: [block])
        let definition = project().replacing(categories: [.init(name: "Category", suites: [.init(name: "Suite", tests: [test])])])
        let store = try ExecutionArtifactStore(directory: directory, project: definition, selection: .all)
        let firstBefore = CaptureID(), firstAfter = CaptureID(), secondBefore = CaptureID()
        let events: [ExecutionEvent] = [
            .testStarted(test.id), .blockStarted(block.id),
            .capture(.init(captureID: firstBefore, elements: [])), .action(block.id, .relaunch),
            .capture(.init(captureID: firstAfter, elements: [])),
            .capture(.init(captureID: secondBefore, elements: [])), .action(block.id, .relaunch),
            .blockFinished(block.id, .needsReview, duration: 1, reason: "Latest action has no after evidence")
        ]
        for event in events { try await store.append(event) }
        let review = try ExecutionReview(project: definition, selection: .all, events: ExecutionArtifactStore.readEvents(in: directory))
        XCTAssertEqual(review.tests[0].blocks[0].before, secondBefore)
        XCTAssertNil(review.tests[0].blocks[0].after)
        XCTAssertEqual(review.tests[0].blocks[0].outcome, .needsReview)
    }
}
