import XCTest
import ProjectDomain
import RunnerCore
import ArtifactStore

private actor PersistenceProbeDriver: RunnerDriving {
    var performing = false
    var stopped = false
    var began: CheckedContinuation<Void, Never>?
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot { .init(captureID: .init(), elements: []) }
    func perform(_ action: DrivenAction, deadline: Date) async throws {
        performing = true; began?.resume(); began = nil
        try await Task.sleep(for: .seconds(30))
    }
    func waitForAction() async { if !performing { await withCheckedContinuation { began = $0 } } }
    func stop() async { stopped = true }
}

private enum InjectedWriteFailure: Error { case diskUnavailable }
private actor FailingExecutionWriter: ExecutionPersisting {
    let store: ExecutionArtifactStore
    let driver: PersistenceProbeDriver
    var finishCalled = false
    var closed = false
    init(store: ExecutionArtifactStore, driver: PersistenceProbeDriver) { self.store = store; self.driver = driver }
    func persist(_ event: ExecutionEvent) async throws -> ExecutionEnvelope {
        if case .actionStarted = event {
            await driver.waitForAction()
            throw InjectedWriteFailure.diskUnavailable
        }
        return try await store.append(event)
    }
    func finish(_ report: ExecutionReport) async throws { finishCalled = true; try await store.finish(report) }
    func closeAfterFailure() async { closed = true; await store.closeAfterFailure() }
}
private actor PresentedEvents {
    var events: [ExecutionEnvelope] = []
    func append(_ value: ExecutionEnvelope) { events.append(value) }
}

final class DurableExecutionTests: XCTestCase {
    func testCancellingConsumerAwaitsCleanupWithoutCommittingInconsistentReport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let test = ProjectDomain.TestCase(name: "in flight", blocks: [.init(title: "launch", action: .relaunch)])
        let project = TestProject(name: "p", app: .init(projectPath: "p", scheme: "s", bundleIdentifier: "b"), simulator: .init(deviceID: "d"), categories: [.init(name: "c", suites: [.init(name: "s", tests: [test])])])
        let driver = PersistenceProbeDriver()
        let store = try ExecutionArtifactStore(directory: directory, project: project, selection: .all)
        let handle = ExecutionEngine(driver: driver).start(project: project)
        let consumer = Task { try await DurableExecution.consume(handle, persistence: store) { _ in } }
        await driver.waitForAction()
        consumer.cancel()
        do { _ = try await consumer.value; XCTFail("Consumer cancellation must throw") }
        catch is CancellationError { }
        let stopped = await driver.stopped; XCTAssertTrue(stopped)
        let archive = try ExecutionArchive(directory: directory)
        XCTAssertNil(archive.report, "An interrupted consumer must not commit terminal metadata")
        let result = await handle.task.value; XCTAssertEqual(result.outcome, .cancelled)
    }
    func testActiveAppendFailureAwaitsDriverCleanupAndDoesNotPresentFailedEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let test = ProjectDomain.TestCase(name: "in flight", blocks: [.init(title: "launch", action: .relaunch)])
        let project = TestProject(name: "p", app: .init(projectPath: "p", scheme: "s", bundleIdentifier: "b"), simulator: .init(deviceID: "d"), categories: [.init(name: "c", suites: [.init(name: "s", tests: [test])])])
        let driver = PersistenceProbeDriver()
        let store = try ExecutionArtifactStore(directory: directory, project: project, selection: .all)
        let writer = FailingExecutionWriter(store: store, driver: driver)
        let presented = PresentedEvents()
        let handle = ExecutionEngine(driver: driver).start(project: project)
        do {
            _ = try await DurableExecution.consume(handle, persistence: writer) { await presented.append($0) }
            XCTFail("A write failure must not return a successful result")
        } catch InjectedWriteFailure.diskUnavailable { }
        let performing = await driver.performing; let stopped = await driver.stopped
        let closed = await writer.closed; let finishCalled = await writer.finishCalled
        XCTAssertTrue(performing, "The failure must occur while the action is in flight")
        XCTAssertTrue(stopped, "Cleanup must complete before the caller receives failure")
        XCTAssertTrue(closed); XCTAssertFalse(finishCalled)
        let events = await presented.events
        XCTAssertFalse(events.contains { if case .actionStarted = $0.event { return true }; if case .action = $0.event { return true }; if case .finished = $0.event { return true }; return false })
        let retained = try ExecutionArchive(directory: directory)
        XCTAssertEqual(events.map(\.sequence), retained.events.map(\.sequence))
        XCTAssertNil(retained.report)
        let result = await handle.task.value
        XCTAssertEqual(result.outcome, .cancelled)
    }
}
