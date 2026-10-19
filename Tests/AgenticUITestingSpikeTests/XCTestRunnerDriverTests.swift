import XCTest
import RunnerCore
import ProjectDomain
@testable import SimulatorControl

final class XCTestRunnerDriverTests: XCTestCase {
    func testFailedCaptureIsUnavailableButDispatchedMutationRemainsUncertain() {
        for failure in [CompanionFailure.timeout, .lostSession, .appCrashed] {
            guard case .unavailable(let reason) = XCTestRunnerDriver.terminalFailure(failure, operation: .snapshot) else {
                return XCTFail("Read failure must not imply an uncertain input side effect")
            }
            XCTAssertEqual(reason, failure.rawValue)
            for operation in [CompanionOperation.tap, .type, .swipe, .launch] {
                guard case .uncertain(let reason) = XCTestRunnerDriver.terminalFailure(failure, operation: operation) else {
                    return XCTFail("A dispatched mutation must never become retryable after transport failure")
                }
                XCTAssertEqual(reason, failure.rawValue)
            }
        }
        guard case .unavailable(let captureReason) = XCTestRunnerDriver.terminalFailure(
            .timeout, operation: .snapshot, elapsedSeconds: 3.2) else {
            return XCTFail("A timed-out read must remain retryable")
        }
        XCTAssertEqual(captureReason, "timeout during snapshot after 3.2s")
        guard case .uncertain(let tapReason) = XCTestRunnerDriver.terminalFailure(
            .timeout, operation: .tap, elapsedSeconds: 3.2) else {
            return XCTFail("A timed-out mutation must remain uncertain")
        }
        XCTAssertEqual(tapReason, "timeout during tap after 3.2s")
    }
}

private actor ProvenanceForwarder: RunnerDriving {
    let driver: XCTestRunnerDriver
    init(_ driver: XCTestRunnerDriver) { self.driver = driver }
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot { throw DriverFailure.unavailable("Lookup-only test") }
    func perform(_ action: DrivenAction, deadline: Date) async throws {}
    func provenance(for id: CaptureID) async -> CompanionCapture? { await driver.provenance(for: id) }
    func stop() async {}
}
extension XCTestRunnerDriverTests {
    func testConcreteAndDelegatedProvenanceUseProductionImplementation() async {
        let driver = XCTestRunnerDriver(baseDirectory: URL(fileURLWithPath: "/tmp"), artifacts: URL(fileURLWithPath: "/tmp/unused-provenance-test"))
        let id = CaptureID()
        let capture = CompanionCapture(snapshot: .init(captureID: id, elements: []), screenshotName: id.description + ".png", pixelWidth: 10, pixelHeight: 20, screenFrame: .init(x: 0, y: 0, width: 10, height: 20))
        await driver.retainProvenance(capture)
        let direct = await driver.provenance(for: id)
        let forwarded = await ProvenanceForwarder(driver).provenance(for: id)
        let existential: any RunnerDriving = driver
        let witness = await existential.provenance(for: id)
        XCTAssertEqual(direct?.snapshot.captureID, id)
        XCTAssertEqual(forwarded?.snapshot.captureID, id)
        XCTAssertEqual(witness?.snapshot.captureID, id)
    }
}
