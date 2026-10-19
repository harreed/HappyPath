import Foundation
import ProjectDomain

extension ExecutionContext {
    /// One bounded safe-escape attempt for an authored step that cannot
    /// proceed. A unique dismissal affordance (Close/Back/Not Now) always
    /// qualifies; a unique unambiguous progress control (Next/Continue/Get
    /// Started) qualifies only when the caller allows progress and the screen
    /// has no irreversible or monetary vocabulary.
    ///
    /// Returns a fresh, progress-verified snapshot after exactly one action.
    /// Refusals are recorded once per block and return nil so the caller can
    /// carry the step forward. A dispatched action whose effect cannot be
    /// verified throws `DriverFailure.uncertain` — never a second mutation.
    func attemptEscape(_ snapshot: UISnapshot, blockID: UUID, deadline: Date, allowProgress: Bool) async throws -> UISnapshot? {
        guard recoveryPolicy.allowSafeEscapes, recoveryPolicy.maximumEscapes > 0 else { return nil }
        guard await recoveryBudget.escapeCount < recoveryPolicy.maximumEscapes else { return nil }
        let observation = InterruptionLibrary.recognize(snapshot)
        if expected(observation) { return nil }
        switch observation.kind {
        case .knownReminder, .alert, .permissionPrompt, .authenticationRequired, .applicationUnavailable, .offline, .authenticationExpired:
            return nil
        default:
            break
        }
        if observation.elements.contains(where: { $0.originBundleIdentifier == "com.apple.springboard" }) { return nil }
        let controls = snapshot.elements.filter { element in
            (element.role == "button" || element.role == "link" || element.role == "cell")
                && element.isEnabled == true && element.isHittable == true
                && (element.originBundleIdentifier == nil || element.originBundleIdentifier == bundleIdentifier)
        }
        let dismissals = controls.filter { TargetTextMatching.dismissalAffordance($0.label) || TargetTextMatching.dismissalAffordance($0.identifier) }
        let progress = controls.filter { TargetTextMatching.progressAffordance($0.label) || TargetTextMatching.progressAffordance($0.identifier) }
        let progressAllowed = allowProgress && recoveryPolicy.allowProgressControls && !TargetTextMatching.irreversibleIntent(snapshot.elements)
        let selected: UIElement
        let origin: RecoveryEvidence.Origin
        if dismissals.count == 1 {
            selected = dismissals[0]; origin = .escape
        } else if dismissals.isEmpty, progressAllowed, progress.count == 1 {
            selected = progress[0]; origin = .progress
        } else {
            if dismissals.count > 1 || (progressAllowed && progress.count > 1), await recoveryBudget.shouldRecordRefusal(blockID: blockID) {
                let candidates = (dismissals + progress).map { element in
                    ActionCandidate(captureID: snapshot.captureID, title: escapeTitle(element, origin: dismissals.contains(element) ? .escape : .progress), action: .tapElement(element), isSafeForAutomaticExecution: false)
                }
                let reason = dismissals.count > 1 ? "Ambiguous dismissal affordances; automatic escape refused" : "Ambiguous progress controls; automatic escape refused"
                await recoveryEvidence(snapshot, blockID: blockID, observation: evidenceObservation(observation, selected: nil), status: .refused, reason: reason, deadline: deadline, candidates: candidates, origin: dismissals.count > 1 ? .escape : .progress)
            }
            return nil
        }
        let candidates = (dismissals + progress).map { element in
            ActionCandidate(captureID: snapshot.captureID, title: escapeTitle(element, origin: origin), action: .tapElement(element), isSafeForAutomaticExecution: element == selected)
        }
        guard let chosen = candidates.first(where: { $0.isSafeForAutomaticExecution }) else { return nil }
        let until = await recoveryDeadline(deadline, origin: origin)
        guard clock.virtualNow() < until else { return nil }
        let localChoice = CandidateChoice(candidateID: chosen.id, captureID: snapshot.captureID, confidence: 1,
            rationale: origin == .escape
                ? "Unique enabled/hittable dismissal affordance; the screen has no irreversible vocabulary"
                : "Unique enabled/hittable progress control; the screen has no irreversible or monetary vocabulary")
        let choice = try await chooseRecovery(localChoice, candidates: candidates, snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline)
        do {
            return try await recoveryDispatch(.tapElement(selected), snapshot: snapshot, blockID: blockID,
                observation: evidenceObservation(observation, selected: selected), candidates: candidates, choice: choice, deadline: deadline, origin: origin)
        } catch PerceptionFailure.staleCapture {
            return nil
        }
    }

    private func escapeTitle(_ element: UIElement, origin: RecoveryEvidence.Origin) -> String {
        (origin == .escape ? "Safe dismissal: " : "Progress control: ") + (element.label ?? element.identifier ?? element.role)
    }

    /// Evidence keeps the true recognized state, but a bare screen is labelled
    /// `unresolvedStep` so reports never claim a supported interruption signal.
    private func evidenceObservation(_ observation: InterruptionObservation, selected: UIElement?) -> InterruptionObservation {
        guard observation.kind == .none else { return observation }
        return InterruptionObservation(kind: .unresolvedStep, reason: "Authored step unresolved; safe escape evaluated", policyID: nil, elements: selected.map { [$0] } ?? [])
    }
}
