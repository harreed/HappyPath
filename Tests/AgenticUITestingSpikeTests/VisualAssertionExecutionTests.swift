import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PerceptionCore
import ProjectDomain
@testable import RunnerCore
import UniformTypeIdentifiers
import XCTest

private actor VisualDriver: RunnerDriving {
    var snapshot: UISnapshot
    var capture: CompanionCapture
    let actual: Data
    let reference: Data
    init(actual: Data, reference: Data) {
        self.actual = actual; self.reference = reference
        let id = CaptureID(), now = Date()
        snapshot = .init(captureID: id, capturedAt: now, elements: [
            .init(identifier: "goal", role: "staticText", label: "Goal reached", value: nil,
                  frame: nil, isEnabled: true, isHittable: true)
        ])
        capture = .init(snapshot: snapshot, screenshotName: "\(id).png", pixelWidth: 2,
            pixelHeight: 2, screenFrame: .init(x: 0, y: 0, width: 2, height: 2),
            screenshotCompletedAt: now, semanticStartedAt: now, semanticCompletedAt: now)
    }
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot {
        let id = CaptureID(), now = Date()
        snapshot = .init(captureID: id, capturedAt: now, elements: snapshot.elements)
        capture = .init(snapshot: snapshot, screenshotName: "\(id).png", pixelWidth: 2,
            pixelHeight: 2, screenFrame: .init(x: 0, y: 0, width: 2, height: 2),
            screenshotCompletedAt: now, semanticStartedAt: now, semanticCompletedAt: now)
        return snapshot
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws {}
    func provenance(for id: CaptureID) async -> CompanionCapture? { id == snapshot.captureID ? capture : nil }
    func visualImageData(for id: CaptureID) async throws -> Data {
        guard id == snapshot.captureID else { throw DriverFailure.uncertain("wrong capture") }
        return actual
    }
    func referenceImageData(for id: UUID) async throws -> Data { reference }
    func stop() async {}
}

private struct VisualGoalNavigator: GoalNavigating {
    func decide(_ request: GoalNavigationRequest) async throws -> GoalNavigationDecision {
        .init(captureID: request.captureID, kind: .complete, confidence: 1,
              reason: "Goal reached is visible")
    }
}

private struct VisualGoalEvaluator: AssertionEvaluating {
    var providerID: String { "test.goal-evaluator" }
    func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment {
        .init(requestID: request.requestID, captureID: request.captureID, verdict: .satisfied,
              confidence: 1, evidenceIDs: request.evidence.filter {
                  $0.text.contains("Goal reached")
              }.map(\.id), reason: "Goal reached is visible")
    }
}

final class VisualAssertionExecutionTests: XCTestCase {
    private func png(black: Bool) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: black ? 0 : 1, green: black ? 0 : 1,
                                     blue: black ? 0 : 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    private func project(_ assertion: AssertionDefinition) -> TestProject {
        .init(name: "Visual", app: .init(projectPath: "p", scheme: "s", bundleIdentifier: "b"),
            simulator: .init(deviceID: "d"), categories: [.init(name: "c", suites: [
                .init(name: "s", tests: [.init(name: "t", blocks: [], assertions: [assertion])])
            ])])
    }
    func testVisualAssertionUsesPixelsAndEmitsEvidence() async throws {
        let reference = try png(black: false)
        let digest = SHA256.hash(data: reference).map { String(format: "%02x", $0) }.joined()
        let assertion = AssertionDefinition.imageMatches(referenceID: UUID(), referenceSHA256: digest,
            maximumMeanChannelDifference: 0, maximumChangedPixelFraction: 0)
        let driver = VisualDriver(actual: try png(black: true), reference: reference)
        let handle = ExecutionEngine(driver: driver, visualComparator: LocalPixelComparator())
            .start(project: project(assertion))
        var visualEvidence: VisualComparisonEvidence?
        for await event in handle.events {
            if case .visualComparison(let value) = event { visualEvidence = value }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(visualEvidence?.changedPixelCount, 4)
        XCTAssertEqual(visualEvidence?.matchesReference, false)
    }

    func testGoalSuccessStillFailsWhenApprovedImageDiffers() async throws {
        let reference = try png(black: false)
        let digest = SHA256.hash(data: reference).map { String(format: "%02x", $0) }.joined()
        let assertion = AssertionDefinition.imageMatches(referenceID: UUID(), referenceSHA256: digest,
            maximumMeanChannelDifference: 0, maximumChangedPixelFraction: 0)
        let test = ProjectDomain.TestCase(name: "goal", goal: "Reach goal",
            executionMode: .goal, blocks: [], assertions: [assertion])
        let saved = TestProject(name: "Visual", app: .init(projectPath: "p", scheme: "s", bundleIdentifier: "b"),
            simulator: .init(deviceID: "d"), categories: [.init(name: "c", suites: [
                .init(name: "s", tests: [test])
            ])])
        let driver = VisualDriver(actual: try png(black: true), reference: reference)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: VisualGoalEvaluator(),
            goalNavigator: VisualGoalNavigator(), visualComparator: LocalPixelComparator())
            .start(project: saved)
        var sawVisualFailure = false
        for await event in handle.events {
            if case .visualComparison(let evidence) = event { sawVisualFailure = !evidence.matchesReference }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertTrue(sawVisualFailure)
    }
}
