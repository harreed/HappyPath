import XCTest
@testable import RunnerCore
import ProjectDomain
@testable import ArtifactStore

final class EvidencePresentationTests: XCTestCase {
    func testNeedsReviewExplanationUsesRecordedSummaryAndSupportedFix() throws {
        let test = TestCase(name: "Start conversation", goal: "Begin chatting", blocks: [])
        let project = TestProject(name: "App", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.test"), simulator: .init(deviceID: "device"), categories: [.init(name: "General", suites: [.init(name: "Suite", tests: [test])])])
        let summary = FailureSummaryEvidence(source: .init(testID: test.id, outcome: .needsReview,
            reason: "No safe next action", assessmentRequestID: nil), provider: "test",
            text: "The name screen is open, but the candidate list is empty and no action could be selected.")
        let events = [ExecutionEvent.testStarted(test.id), .failureSummary(summary), .testFinished(test.id, .needsReview)]
            .enumerated().map { ExecutionEnvelope(sequence: $0.offset, timestamp: Date(), event: $0.element) }
        let explanation = try XCTUnwrap(ExecutionReview(project: project, selection: .all, events: events).needsReviewExplanations.first)
        XCTAssertEqual(explanation.testName, "Start conversation")
        XCTAssertEqual(explanation.reason, "The test stopped at the name field because no name was entered, so it could not continue.")
        XCTAssertEqual(explanation.suggestedFix, "Use a saved Name input in Resources, then rerun the test.")
    }

    func testIdenticalReviewReasonsAppearAsOneGroupWithEveryAffectedTest() throws {
        let tests = [TestCase(name: "First", blocks: []), TestCase(name: "Second", blocks: [])]
        let project = TestProject(name: "App", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.test"), simulator: .init(deviceID: "device"), categories: [.init(name: "General", suites: [.init(name: "Suite", tests: tests)])])
        let events = tests.flatMap { test in
            [ExecutionEvent.testStarted(test.id),
             .failureSummary(.init(source: .init(testID: test.id, outcome: .needsReview,
                 reason: "No safe progress choice", assessmentRequestID: nil), provider: "test",
                 text: "No safe progress choice")),
             .testFinished(test.id, .needsReview)]
        }.enumerated().map { ExecutionEnvelope(sequence: $0.offset, timestamp: Date(), event: $0.element) }

        let groups = try ExecutionReview(project: project, selection: .all, events: events).needsReviewExplanationGroups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].explanations.map(\.testName), ["First", "Second"])
        XCTAssertEqual(groups[0].reason, "No safe progress choice")
    }

    func testOCRTopLeftPixelsLetterboxWithoutYFlipAndRejectInvalidBoxes() throws {
        let pixels = PixelSize(width: 1200, height: 2400)
        let box = try XCTUnwrap(EvidencePresentation.overlayBox(.init(x: 120, y: 240, width: 600, height: 120), pixels: pixels, width: 400, height: 400))
        XCTAssertEqual(box.x, 120, accuracy: 0.0001)
        XCTAssertEqual(box.y, 40, accuracy: 0.0001)
        XCTAssertEqual(box.width, 100, accuracy: 0.0001)
        XCTAssertEqual(box.height, 20, accuracy: 0.0001)
        XCTAssertNil(EvidencePresentation.overlayBox(.init(x: 0, y: 2390, width: 20, height: 20), pixels: pixels, width: 400, height: 400))
        XCTAssertNil(EvidencePresentation.overlayBox(.init(x: .nan, y: 0, width: 20, height: 20), pixels: pixels, width: 400, height: 400))
    }
    func testRejectedProviderClaimCannotSelectAnotherCapture() throws {
        let local = CaptureID(), foreign = CaptureID()
        let snapshot = UISnapshot(captureID: local, capturedAt: Date(), elements: [])
        let refusal = CandidateDecisionEvidence(requestID: UUID(), captureID: foreign, optionIDs: [], selectedID: nil, probabilities: nil, confidence: 2, reason: "mismatch", accepted: false, responseCaptureID: foreign, originalAccepted: true)
        let first = ExecutionEnvelope(sequence: 0, timestamp: Date(), event: .capture(snapshot))
        let second = ExecutionEnvelope(sequence: 1, timestamp: Date(), event: .candidateDecision(refusal))
        XCTAssertNil(second.event.sourceCaptureID)
        XCTAssertEqual(EvidencePresentation.sourceCapture(for: second, events: [first,second]), local)
        XCTAssertTrue(EvidencePresentation.detail(second.event)!.lowercased().contains(foreign.description.lowercased()))
        XCTAssertTrue(EvidencePresentation.detail(second.event)!.contains("not action permission"))
    }
    func testRecoveryVerificationDoesNotReplaceOriginalSourceCapture() {
        let source = CaptureID(), verification = CaptureID()
        let value = RecoveryEvidence(blockID: UUID(), captureID: source, geometry: nil, interruption: .init(kind: .alert, reason: "Observed", policyID: nil, elements: []), candidates: [], choice: nil, provider: "local", status: .verified, reason: "Progress", actionCount: 1, maximumActions: 2, recoveryStartedAt: Date(), deadline: Date().addingTimeInterval(10), minimumConfidence: 0.9, maximumCaptureAge: 8, recaptureCount: 0, verificationCaptureID: verification)
        XCTAssertEqual(ExecutionEvent.recovery(value).sourceCaptureID, source)
        let detail = EvidencePresentation.detail(.recovery(value))!
        XCTAssertTrue(detail.contains("Source: \(source)"))
        XCTAssertTrue(detail.contains("Verification source: \(verification)"))
    }
    func testProjectRecoveryEditsPreserveIdentityTestOverridesAndNilButtons() throws {
        let test = TestCase(name: "Test", goal: "Complete", blocks: [], recoveryPolicy: .init(maximumActions: 1), useProjectRecoveryPolicy: true, goalAssessmentPolicy: .init(requirement: .ocr))
        let project = TestProject(name: "Original", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.test"), simulator: .init(deviceID: "device"), categories: [.init(name: "Category", suites: [.init(name: "Suite", tests: [test])])])
        let definition = ReviewedAlertPolicy(id: "custom", bundleIdentifier: "org.test", alertIdentifier: "alert", exactContext: "Exact context", buttons: [.init(identifier: nil, label: "Later", risk: .unknown)])
        let changed = project.replacing(reviewedAlertPolicies: [definition], defaultRecoveryPolicy: .init(maximumActions: 3))
        let roundtrip = try JSONDecoder().decode(TestProject.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(roundtrip.id, project.id)
        XCTAssertEqual(roundtrip.categories, project.categories)
        XCTAssertEqual(roundtrip.recoveryPolicy(for: test).maximumActions, 3)
        XCTAssertNil(roundtrip.reviewedAlertPolicies?.first?.buttons.first?.identifier)
        XCTAssertEqual(roundtrip.reviewedAlertPolicies?.first?.buttons.first?.risk, .unknown)
        let override = test.replacing(recoveryPolicy: .init(maximumActions: 2))
        XCTAssertEqual(override.useProjectRecoveryPolicy, false)
        XCTAssertEqual(roundtrip.recoveryPolicy(for: override).maximumActions, 2)
        XCTAssertEqual(override.goalAssessmentPolicy?.requirement, .ocr)
        XCTAssertEqual(roundtrip.replacing(name: "Renamed").reviewedAlertPolicies, [definition])
    }
    func testGoalUsesProjectPromptPolicyDespiteLegacyTestOverride() {
        let test = TestCase(name: "Goal", goal: "Finish onboarding", executionMode: .goal, blocks: [],
            recoveryPolicy: .init(allowSystemDismiss: false), useProjectRecoveryPolicy: false)
        let project = TestProject(name: "Project", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.test"),
            simulator: .init(deviceID: "device"), categories: [], defaultRecoveryPolicy: .init(allowSystemDismiss: true))
        XCTAssertTrue(project.recoveryPolicy(for: test).allowSystemDismiss)
    }
}
