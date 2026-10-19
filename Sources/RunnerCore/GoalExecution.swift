import Foundation
import ProjectDomain

extension ExecutionContext {
    func assessGoal(_ test: TestCase, established: RunOutcome, evaluator: any AssertionEvaluating, deadline: Date,
                    verifiedActions: [String] = [], observedEvidence: [GoalEvidenceItem] = []) async -> GoalAssessmentEvidence {
        let policy = test.goalAssessmentPolicy ?? .init()
        var request: GoalAssessmentRequest?
        func result(_ outcome: RunOutcome, _ reason: String, response: AssertionAssessment? = nil,
                    provider: String? = nil) -> GoalAssessmentEvidence {
            // Nonfinite typed values cannot be written as JSON. Preserve the raw response and refusal reason.
            let safeResponse = response.map { value in
                AssertionAssessment(requestID: value.requestID, captureID: value.captureID, verdict: value.verdict, requiresImage: value.requiresImage, confidence: value.confidence.isFinite ? value.confidence : 0, evidenceIDs: value.evidenceIDs, reason: value.reason, rawResponse: value.rawResponse)
            }
            return .init(testID: test.id, goal: test.goal, request: request, provider: provider ?? evaluator.providerID, assessment: safeResponse, minimumConfidence: policy.minimumConfidence, outcome: outcome, reason: reason, invalidNumericValues: response.flatMap { $0.confidence.isFinite ? nil : ["assessment.confidence": String($0.confidence)] })
        }
        guard established == .passed || established == .needsReview else { return result(.needsReview, "Final goal unavailable after established \(established.rawValue) execution; established outcome retained") }
        do {
            try Task.checkCancellation()
            try await control.boundary(startsBlock: false)
            let until = min(deadline, clock.virtualNow().addingTimeInterval(policy.timeoutSeconds))
            let snapshot = try await capture(until)
            var mode: GoalEvidenceMode = .semanticText
            var items: [GoalEvidenceItem]?
            switch policy.requirement {
            case .semantic: break
            case .image: mode = .imageUnavailable
            case .ocr:
                guard let provenance = await driver.provenance(for: snapshot.captureID), try provenance.validatedTiming() else { throw ProviderFailure.invalidResponse }
                let capture = ScreenCapture(id: snapshot.captureID, createdAt: snapshot.capturedAt, pixelSize: .init(width: provenance.pixelWidth, height: provenance.pixelHeight), screenshotRelativePath: "captures/" + provenance.screenshotName)
                let text = try await driver.recognizeText(for: snapshot.captureID, deadline: clock.actual(until))
                events.yield(.perception(text))
                try text.validate(capture: capture, now: Date(), maximumAge: 8)
                mode = .ocrText
                items = text.regions.enumerated().filter { $0.element.confidence >= policy.minimumConfidence }.map { .init(id: "ocr-\($0.offset)", text: $0.element.text) }
            }
            var finalItems = items ?? snapshot.elements.enumerated().map { index, element in
                GoalEvidenceItem(id: "semantic-\(index)", text: "role=\(element.role); identifier=\(element.identifier ?? ""); label=\(element.label ?? ""); value=\(element.value ?? "")")
            }
            if mode == .semanticText {
                finalItems += verifiedActions.suffix(12).enumerated().map { index, label in
                    GoalEvidenceItem(id: "verified-action-\(index)", text: "Action dispatched during this run: \(label)")
                }
                if let timer = GoalNavigationSafety.visibleTimer(in: snapshot) {
                    finalItems.append(.init(id: "assembled-timer", text: "Visible timer characters ordered by screen position: \(timer.text)"))
                }
                finalItems += observedEvidence
            }
            let value = GoalAssessmentRequest(goal: test.goal, successCriteria: test.successCriteria,
                snapshot: snapshot, deadline: clock.actual(until), mode: mode, evidence: finalItems)
            request = value
            if mode == .imageUnavailable {
                guard let imageAssessor,
                      imageAssessor.processingLocation != .remote || imageDisclosureChoice == .allowRemoteForThisRun else {
                    return result(.needsReview, "A screenshot was captured, but remote image assessment was not enabled for this run")
                }
                do { return try await assessScreenshotGoal(test, policy: policy, deadline: until, provider: imageAssessor) }
                catch { return result(.needsReview, screenshotAssessmentFailure(error)) }
            }
            guard !value.evidence.isEmpty, Date().timeIntervalSince(snapshot.capturedAt) < 8 else { return result(.needsReview, "Fresh final evidence is unavailable or empty") }
            if mode == .semanticText,
               let visible = GoalNavigationSafety.literalVisibleSuccess(test.successCriteria,
                   snapshot: snapshot, appBundleID: bundleIdentifier),
               let index = snapshot.elements.firstIndex(where: {
                   $0.role == "staticText" && $0.originBundleIdentifier == bundleIdentifier && $0.label == visible
               }) {
                let reason = "Fresh app text shows the exact visible success criterion: \(visible)"
                let response = AssertionAssessment(requestID: value.requestID, captureID: value.captureID,
                    verdict: .satisfied, confidence: 1, evidenceIDs: ["semantic-\(index)"], reason: reason)
                let validated = GoalAssessmentEvidence.validate(response, request: value,
                    minimumConfidence: policy.minimumConfidence)
                return result(validated.0, validated.1, response: response, provider: "local.literal-visible")
            }
            let response = try await boundedProviderCall(deadline: value.deadline) { try await evaluator.assess(value) }
            let needsMoreEvidence = response.requiresImage || response.verdict == .insufficient ||
                response.confidence < policy.minimumConfidence
            if needsMoreEvidence && mode == .semanticText {
                do {
                    guard let provenance = await driver.provenance(for: snapshot.captureID),
                          try provenance.validatedTiming() else { throw ProviderFailure.invalidResponse }
                    let capture = ScreenCapture(id: snapshot.captureID, createdAt: snapshot.capturedAt,
                        pixelSize: .init(width: provenance.pixelWidth, height: provenance.pixelHeight),
                        screenshotRelativePath: "captures/" + provenance.screenshotName)
                    let text = try await driver.recognizeText(for: snapshot.captureID, deadline: value.deadline)
                    events.yield(.perception(text))
                    try text.validate(capture: capture, now: Date(), maximumAge: 8)
                    let ocrItems = text.regions.enumerated()
                        .filter { $0.element.confidence >= policy.minimumConfidence }
                        .map { GoalEvidenceItem(id: "ocr-\($0.offset)", text: $0.element.text) }
                    if !ocrItems.isEmpty {
                        let ocrRequest = GoalAssessmentRequest(goal: test.goal,
                            successCriteria: test.successCriteria, snapshot: snapshot,
                            deadline: value.deadline, mode: .ocrText, evidence: ocrItems)
                        let ocrResponse = try await boundedProviderCall(deadline: ocrRequest.deadline) {
                            try await evaluator.assess(ocrRequest)
                        }
                        let validated = GoalAssessmentEvidence.validate(ocrResponse, request: ocrRequest,
                            minimumConfidence: policy.minimumConfidence)
                        if validated.0 == .passed {
                            request = ocrRequest
                            return result(validated.0, validated.1, response: ocrResponse)
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { events.yield(.diagnostic("OCR could not verify the final goal; checking screenshot evidence if approved")) }
            }
            if needsMoreEvidence {
                guard let imageAssessor,
                      imageAssessor.processingLocation != .remote || imageDisclosureChoice == .allowRemoteForThisRun else {
                    return result(.needsReview, "Text and OCR could not verify success. A screenshot was captured, but remote image assessment was not enabled for this run", response: response)
                }
                events.yield(.diagnostic("Text evidence cannot verify the visual finish state; checking a fresh screenshot"))
                do { return try await assessScreenshotGoal(test, policy: policy, deadline: until, provider: imageAssessor) }
                catch { return result(.needsReview, screenshotAssessmentFailure(error), response: response) }
            }
            let validated = GoalAssessmentEvidence.validate(response, request: value, minimumConfidence: policy.minimumConfidence)
            return result(validated.0, validated.1, response: response)
        } catch is CancellationError { return result(.needsReview, "Goal assessment cancelled; cancellation retains precedence") }
        catch {
            // Never persist arbitrary provider/HTTP error strings that could contain headers or credentials.
            let reason: String
            switch error {
            case ProviderFailure.busy: reason = "Local model worker busy"
            case ProviderFailure.deadline: reason = "Goal assessment deadline exceeded"
            case ProviderFailure.invalidResponse: reason = "Goal evidence or provider response invalid"
            default: reason = "Goal assessment provider or final evidence unavailable"
            }
            return result(.needsReview, reason)
        }
    }

    private func assessScreenshotGoal(_ test: TestCase, policy: GoalAssessmentPolicy,
                                      deadline: Date, provider: any ImageAssessing) async throws -> GoalAssessmentEvidence {
        let snapshot = try await capture(deadline)
        guard let provenance = await driver.provenance(for: snapshot.captureID),
              try provenance.validatedTiming() else { throw ImageAssessmentFailure.invalidRequest }
        let capture = ScreenCapture(id: snapshot.captureID, createdAt: snapshot.capturedAt,
            pixelSize: .init(width: provenance.pixelWidth, height: provenance.pixelHeight),
            screenshotRelativePath: "captures/" + provenance.screenshotName)
        let imageData = try await driver.visualImageData(for: snapshot.captureID)
        let request = GoalAssessmentRequest(goal: test.goal, successCriteria: test.successCriteria,
            snapshot: snapshot, deadline: clock.actual(deadline), mode: .imageObserved)
        let criterion = test.successCriteria.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = criterion.isEmpty ? test.goal : criterion
        let imageRequest = ImageAssessmentRequest(capture: capture, imageData: imageData,
            question: question, deadline: clock.actual(deadline))
        let assessment = try await ImageAssessmentRouter(primary: provider,
            fallback: fallbackImageAssessor,
            primaryMinimumConfidence: primaryImageMinimumConfidence ?? policy.minimumConfidence,
            fallbackMinimumConfidence: policy.minimumConfidence)
            .assess(imageRequest, choice: imageDisclosureChoice)
        let outcome: RunOutcome
        switch assessment.verdict {
        case .satisfied: outcome = .passed
        case .notSatisfied: outcome = .failed
        case .insufficient: outcome = .needsReview
        }
        return .init(testID: test.id, goal: test.goal, request: request, provider: assessment.providerID,
            assessment: nil,
            minimumConfidence: assessment.providerID == provider.providerID
                ? (primaryImageMinimumConfidence ?? policy.minimumConfidence) : policy.minimumConfidence,
            outcome: outcome,
            reason: assessment.reason, imageAssessment: assessment)
    }

    private func screenshotAssessmentFailure(_ error: Error) -> String {
        if error is CancellationError { return "Screenshot assessment cancelled" }
        switch error {
        case ImageAssessmentFailure.remoteConsentRequired: return "Screenshot assessment needs approval for this run"
        case ImageAssessmentFailure.invalidRequest: return "Fresh screenshot evidence is unavailable"
        case ImageAssessmentFailure.invalidResponse: return "Screenshot model response could not be verified"
        case ProviderFailure.deadline: return "Screenshot assessment timed out"
        default: return "Screenshot assessment provider is unavailable"
        }
    }
}
