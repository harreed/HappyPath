import Foundation
import RunnerCore

public struct ReviewExplanation: Identifiable, Sendable {
    public let id: UUID
    public let testName: String
    public let stepName: String?
    public let reason: String
    public let suggestedFix: String?
}

public struct ReviewExplanationGroup: Identifiable, Sendable {
    public let id: UUID
    public let explanations: [ReviewExplanation]
    public var reason: String { explanations[0].reason }
    public var suggestedFix: String? { explanations[0].suggestedFix }
}

public extension ExecutionReview {
    var needsReviewExplanationGroups: [ReviewExplanationGroup] {
        var groups: [ReviewExplanationGroup] = []
        for explanation in needsReviewExplanations {
            if let index = groups.firstIndex(where: {
                $0.reason == explanation.reason && $0.suggestedFix == explanation.suggestedFix
            }) {
                let previous = groups[index]
                groups[index] = ReviewExplanationGroup(id: previous.id,
                    explanations: previous.explanations + [explanation])
            } else {
                groups.append(ReviewExplanationGroup(id: explanation.id, explanations: [explanation]))
            }
        }
        return groups
    }

    var needsReviewExplanations: [ReviewExplanation] {
        tests.filter { $0.outcome == .needsReview }.map { test in
            let step = test.blocks.last { $0.outcome == .needsReview || $0.outcome == .blocked || $0.outcome == .failed }
            let summary = events.reversed().compactMap { envelope -> FailureSummaryEvidence? in
                guard case .failureSummary(let value) = envelope.event,
                      value.source.testID == test.id, value.source.outcome == .needsReview else { return nil }
                return value
            }.first
            let assessment = events.reversed().compactMap { envelope -> GoalAssessmentEvidence? in
                guard case .goalAssessment(let value) = envelope.event,
                      value.testID == test.id, value.outcome == .needsReview else { return nil }
                return value
            }.first
            let recordedReason = [step?.reason, assessment?.reason, summary?.text, summary?.source.reason]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.contains("see recorded block and assertion events") }
                ?? "The run could not confirm this test's result. Review the last screen and recorded actions in Full evidence."
            let lowercased = recordedReason.lowercased()
            let nameFieldStopped = lowercased.contains("candidate list is empty") && lowercased.contains("name")
            let explanation = nameFieldStopped
                ? "The test stopped at the name field because no name was entered, so it could not continue."
                : recordedReason
            let fix: String?
            if nameFieldStopped {
                fix = "Use a saved Name input in Resources, then rerun the test."
            } else if lowercased.contains("candidate list is empty") || lowercased.contains("no supplied action") {
                fix = "Check the screen shown below and add the missing input or a valid next step to the test, then rerun."
            } else if lowercased.contains("confidence below local threshold") || lowercased.contains("insufficient cited evidence") {
                fix = "Make the success criteria more specific or expose clearer evidence on screen, then rerun."
            } else {
                fix = nil
            }
            return ReviewExplanation(id: test.id, testName: test.name, stepName: step?.title,
                                     reason: explanation, suggestedFix: fix)
        }
    }
}
