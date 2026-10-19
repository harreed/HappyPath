import XCTest
@testable import RunnerCore

final class CaptureActionGateTests: XCTestCase {
    func testRejectsMalformedInputWithoutConsumingCapture() async throws {
        let capture = CaptureID()
        let candidate = ActionCandidate(captureID: capture, title: "Close", action: .dismiss, isSafeForAutomaticExecution: true)
        let foreign = ActionCandidate(captureID: CaptureID(), title: "Wait", action: .dismiss, isSafeForAutomaticExecution: true)
        let gate = CaptureActionGate()
        try await gate.activate(capture)
        for value in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            do { _ = try await gate.validateAndConsume(choice: .init(candidateID: candidate.id, captureID: capture, confidence: value), candidates: [candidate], minimumConfidence: 0.8); XCTFail("Accepted confidence") }
            catch CaptureActionGateError.invalidConfidence { }
            do { _ = try await gate.validateAndConsume(choice: .init(candidateID: candidate.id, captureID: capture, confidence: 1), candidates: [candidate], minimumConfidence: value); XCTFail("Accepted threshold") }
            catch CaptureActionGateError.invalidThreshold { }
        }
        let choice = CandidateChoice(candidateID: candidate.id, captureID: capture, confidence: 1)
        do { _ = try await gate.validateAndConsume(choice: choice, candidates: [candidate, candidate], minimumConfidence: 0.8); XCTFail("Accepted duplicate") }
        catch CaptureActionGateError.duplicateCandidateIDs { }
        do { _ = try await gate.validateAndConsume(choice: choice, candidates: [candidate, foreign], minimumConfidence: 0.8); XCTFail("Accepted foreign unselected candidate") }
        catch CaptureActionGateError.candidateCaptureMismatch { }
        _ = try await gate.validateAndConsume(choice: choice, candidates: [candidate], minimumConfidence: 0.8)
    }

    func testSupersededCaptureCannotBeReactivated() async throws {
        let old = CaptureID(), fresh = CaptureID()
        let gate = CaptureActionGate()
        try await gate.activate(old)
        try await gate.activate(fresh)
        do { try await gate.activate(old); XCTFail("Reactivated superseded capture") }
        catch CaptureActionGateError.captureReactivation(let rejected) { XCTAssertEqual(rejected, old) }
        let candidate = ActionCandidate(captureID: fresh, title: "Close", action: .dismiss, isSafeForAutomaticExecution: true)
        _ = try await gate.validateAndConsume(choice: .init(candidateID: candidate.id, captureID: fresh, confidence: 1), candidates: [candidate], minimumConfidence: 0.8)
        do { try await gate.activate(fresh); XCTFail("Reactivated consumed capture") }
        catch CaptureActionGateError.captureReactivation { }
    }

    func testAcceptsOneSafeActionForActiveCapture() async throws {
        let capture = CaptureID()
        let candidate = ActionCandidate(
            captureID: capture,
            title: "Close",
            action: .dismiss,
            isSafeForAutomaticExecution: true
        )
        let choice = CandidateChoice(candidateID: candidate.id, captureID: capture, confidence: 0.95)
        let gate = CaptureActionGate()

        try await gate.activate(capture)
        let selected = try await gate.validateAndConsume(
            choice: choice,
            candidates: [candidate],
            minimumConfidence: 0.8
        )

        XCTAssertEqual(selected, candidate)
    }

    func testRejectsSecondActionFromSameCapture() async throws {
        let capture = CaptureID()
        let candidate = ActionCandidate(
            captureID: capture,
            title: "Close",
            action: .dismiss,
            isSafeForAutomaticExecution: true
        )
        let choice = CandidateChoice(candidateID: candidate.id, captureID: capture, confidence: 1)
        let gate = CaptureActionGate()
        try await gate.activate(capture)
        _ = try await gate.validateAndConsume(choice: choice, candidates: [candidate], minimumConfidence: 0.8)

        do {
            _ = try await gate.validateAndConsume(choice: choice, candidates: [candidate], minimumConfidence: 0.8)
            XCTFail("Expected reuse to fail")
        } catch let error as CaptureActionGateError {
            XCTAssertEqual(error, .captureAlreadyConsumed(capture))
        }
    }

    func testRejectsChoiceFromStaleCapture() async throws {
        let oldCapture = CaptureID()
        let freshCapture = CaptureID()
        let candidate = ActionCandidate(
            captureID: oldCapture,
            title: "Close",
            action: .dismiss,
            isSafeForAutomaticExecution: true
        )
        let choice = CandidateChoice(candidateID: candidate.id, captureID: oldCapture, confidence: 1)
        let gate = CaptureActionGate()
        try await gate.activate(freshCapture)

        do {
            _ = try await gate.validateAndConsume(choice: choice, candidates: [candidate], minimumConfidence: 0.8)
            XCTFail("Expected stale choice to fail")
        } catch let error as CaptureActionGateError {
            XCTAssertEqual(error, .staleCapture(expected: freshCapture, received: oldCapture))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsUnsafeOrLowConfidenceAction() async throws {
        let capture = CaptureID()
        let unsafe = ActionCandidate(
            captureID: capture,
            title: "Delete account",
            action: .tapAccessibilityIdentifier("delete-account"),
            isSafeForAutomaticExecution: false
        )
        let gate = CaptureActionGate()
        try await gate.activate(capture)

        do {
            _ = try await gate.validateAndConsume(
                choice: CandidateChoice(candidateID: unsafe.id, captureID: capture, confidence: 1),
                candidates: [unsafe],
                minimumConfidence: 0.8
            )
            XCTFail("Expected unsafe candidate to fail")
        } catch let error as CaptureActionGateError {
            XCTAssertEqual(error, .unsafeCandidate)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let safe = ActionCandidate(
            captureID: capture,
            title: "Wait",
            action: .wait(milliseconds: 250),
            isSafeForAutomaticExecution: true
        )
        do {
            _ = try await gate.validateAndConsume(
                choice: CandidateChoice(candidateID: safe.id, captureID: capture, confidence: 0.2),
                candidates: [safe],
                minimumConfidence: 0.8
            )
            XCTFail("Expected low confidence to fail")
        } catch let error as CaptureActionGateError {
            XCTAssertEqual(error, .confidenceBelowThreshold(required: 0.8, received: 0.2))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
