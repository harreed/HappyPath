import XCTest
@testable import ModelProviders
@testable import RunnerCore

private actor StubJevTransport: JevDecisionTransport {
    let response: CandidateDecisionResponse
    private(set) var lastRequest: CandidateDecisionRequest?

    init(response: CandidateDecisionResponse) {
        self.response = response
    }

    func decide(_ request: CandidateDecisionRequest) async throws -> CandidateDecisionResponse {
        lastRequest = request
        return response
    }
}

final class CandidateChooserTests: XCTestCase {
    func testOnlyExplicitUniqueEnabledAlertDismissalIsAccepted() throws {
        let capture = CaptureID()
        let policy = KnownAlertDismissal(alertIdentifier: "reminder", alertContext: "Try reminders?",
            buttonIdentifier: "continue", buttonLabel: "Continue", buttonRole: "cancel")
        func element(enabled: Bool? = true, hittable: Bool? = true, alert: String? = "reminder",
                     context: String? = "Try reminders?", role: String = "button", buttonRole: String? = "cancel") -> UIElement {
            UIElement(identifier: "continue", role: role, label: "Continue", value: nil, frame: nil,
                isEnabled: enabled, isHittable: hittable, containingAlertIdentifier: alert,
                containingAlertContext: context, buttonRole: buttonRole)
        }
        func candidates(_ elements: [UIElement]) -> [ActionCandidate] {
            InterruptionCandidateFactory.safeDismissCandidates(from: .init(captureID: capture, elements: elements), policies: [policy])
        }
        XCTAssertEqual(candidates([element()]).count, 1)
        for invalid in [element(enabled: false), element(hittable: false), element(enabled: nil),
                        element(alert: nil), element(context: "Delete account?"),
                        element(role: "text"), element(buttonRole: "destructive"), element(buttonRole: nil)] {
            XCTAssertTrue(candidates([invalid]).isEmpty)
        }
        XCTAssertTrue(candidates([element(), element()]).isEmpty)
        XCTAssertTrue(InterruptionCandidateFactory.safeDismissCandidates(from: .init(captureID: capture, elements: [element()])).isEmpty)
        let legacy = try JSONDecoder().decode(UIElement.self, from: Data(#"{"identifier":"continue","role":"button","label":"Continue"}"#.utf8))
        XCTAssertNil(legacy.isEnabled)
        XCTAssertTrue(candidates([legacy]).isEmpty)
    }

    func testBothChoosersRejectDuplicateIDsAndMixedCaptures() async throws {
        let capture = CaptureID()
        let first = ActionCandidate(captureID: capture, title: "Close", action: .dismiss, isSafeForAutomaticExecution: true)
        let duplicate = ActionCandidate(id: first.id, captureID: capture, title: "Delete", action: .dismiss, isSafeForAutomaticExecution: false)
        let mixed = ActionCandidate(captureID: CaptureID(), title: "Wait", action: .dismiss, isSafeForAutomaticExecution: true)
        let transport = StubJevTransport(response: .init(captureID: capture, candidateID: first.id, confidence: 1))
        for list in [[first, duplicate], [first, mixed]] {
            do { _ = try await DeterministicCandidateChooser().choose(from: list, context: ""); XCTFail("Accepted malformed set") } catch { }
            do { _ = try await JevCandidateChooser(transport: transport).choose(from: list, context: ""); XCTFail("Accepted malformed set") } catch { }
        }
        let request = await transport.lastRequest
        XCTAssertNil(request, "Malformed options must never reach transport")
    }

    func testJevRejectsMalformedConfidence() async {
        let capture = CaptureID()
        let candidate = ActionCandidate(captureID: capture, title: "Close", action: .dismiss, isSafeForAutomaticExecution: true)
        for confidence in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            let transport = StubJevTransport(response: .init(captureID: capture, candidateID: candidate.id, confidence: confidence))
            do { _ = try await JevCandidateChooser(transport: transport).choose(from: [candidate], context: ""); XCTFail("Accepted invalid confidence") }
            catch let refusal as CandidateProviderRefusal { XCTAssertTrue(refusal.evidence.reason.contains("confidence")) }
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testJevBoundarySendsOnlySafeOptionsAndAcceptsKnownID() async throws {
        let capture = CaptureID()
        let safe = ActionCandidate(
            captureID: capture,
            title: "Not Now",
            action: .dismiss,
            isSafeForAutomaticExecution: true
        )
        let unsafe = ActionCandidate(
            captureID: capture,
            title: "Erase",
            action: .tapAccessibilityIdentifier("erase"),
            isSafeForAutomaticExecution: false
        )
        let transport = StubJevTransport(response: .init(
            captureID: capture,
            candidateID: safe.id,
            confidence: 0.91, probabilities: [safe.id.uuidString: 0.99, "abstain": 0.01]
        ))
        let chooser = JevCandidateChooser(transport: transport)

        let choice = try await chooser.choose(from: [safe, unsafe], context: "Unexpected alert")

        XCTAssertEqual(choice.candidateID, safe.id)
        let request = await transport.lastRequest
        XCTAssertEqual(request?.options.map(\.id), [safe.id])
    }

    func testJevBoundaryRejectsInventedCandidate() async {
        let capture = CaptureID()
        let safe = ActionCandidate(
            captureID: capture,
            title: "Close",
            action: .dismiss,
            isSafeForAutomaticExecution: true
        )
        let invented = UUID()
        let transport = StubJevTransport(response: .init(
            captureID: capture,
            candidateID: invented,
            confidence: 0.99
        ))

        do {
            _ = try await JevCandidateChooser(transport: transport).choose(from: [safe], context: "Alert")
            XCTFail("Expected invented candidate to fail")
        } catch let error as CandidateProviderRefusal {
            XCTAssertEqual(error.evidence.selectedID, invented.uuidString)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
