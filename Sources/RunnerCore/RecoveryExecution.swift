import Foundation
import ProjectDomain

extension ExecutionContext {
    func chooseRecovery(_ local: CandidateChoice, candidates: [ActionCandidate], snapshot: UISnapshot, blockID: UUID, observation: InterruptionObservation, deadline: Date) async throws -> CandidateChoice {
        guard recoveryPolicy.candidateProvider == .jev else { return local }
        // Hosted choice is best-effort: missing, rejected or unusable provider
        // answers use the locally reviewed choice and are recorded, never silent.
        func fallback(_ reason: String, decision: CandidateDecisionEvidence? = nil) -> CandidateChoice {
            if let decision { events.yield(.candidateDecision(decision)) }
            events.yield(.providerFallback(.init(reason: reason, captureID: snapshot.captureID, blockID: blockID)))
            return local
        }
        guard let candidateChooser else {
            return fallback("runtime chooser is not configured")
        }
        do {
            let until = await recoveryDeadline(deadline)
            let choice = try await boundedProviderCall(deadline: clock.actual(until)) {
                try await candidateChooser.choose(from: candidates, context: "Locally reviewed unique safe candidate for observed \(observation.kind.rawValue). \(observation.reason)")
            }
            let evidence = choice.providerEvidence ?? CandidateDecisionEvidence(requestID: UUID(), captureID: snapshot.captureID, provider: "configured.candidate-chooser", optionIDs: candidates.filter(\.isSafeForAutomaticExecution).map { $0.id.uuidString } + ["abstain"], selectedID: choice.candidateID.uuidString, probabilities: nil, confidence: choice.confidence, reason: "Typed chooser response received; local safety gate still required", accepted: false, responseCaptureID: choice.captureID)
            guard choice.providerEvidence != nil, let probabilities = evidence.probabilities,
                  evidence.captureID == snapshot.captureID, evidence.responseCaptureID == nil || evidence.responseCaptureID == snapshot.captureID, evidence.selectedID == choice.candidateID.uuidString,
                  evidence.provider == "jev", Set(evidence.optionIDs).count == evidence.optionIDs.count,
                  Set(evidence.optionIDs) == Set(candidates.filter(\.isSafeForAutomaticExecution).map { $0.id.uuidString } + ["abstain"]),
                  Set(probabilities.keys) == Set(evidence.optionIDs), probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  abs(probabilities.values.reduce(0, +) - 1) <= 0.001, probabilities[choice.candidateID.uuidString] == probabilities.values.max(),
                  probabilities.values.filter({ $0 == probabilities.values.max() }).count == 1,
                  choice.confidence.isFinite, (0...1).contains(choice.confidence), evidence.confidence == choice.confidence, evidence.accepted, evidence.invalidNumericValues == nil else {
                throw CandidateProviderRefusal(.init(requestID: evidence.requestID, captureID: evidence.captureID, provider: evidence.provider, optionIDs: evidence.optionIDs, selectedID: evidence.selectedID, probabilities: evidence.probabilities, confidence: evidence.confidence, reason: "Engine rejected missing, malformed or contradictory provider metadata", accepted: false, responseCaptureID: evidence.responseCaptureID, originalAccepted: evidence.accepted, invalidNumericValues: evidence.invalidNumericValues))
            }
            events.yield(.candidateDecision(evidence))
            guard choice.captureID == snapshot.captureID, choice.candidateID == local.candidateID,
                  choice.confidence.isFinite, choice.confidence >= recoveryPolicy.minimumConfidence, choice.confidence <= 1 else {
                throw ProviderFailure.invalidResponse
            }
            return choice
        } catch is CancellationError { throw CancellationError() }
        catch let failure as CandidateProviderRefusal {
            return fallback(failure.evidence.reason, decision: failure.evidence)
        } catch {
            return fallback("provider response unavailable, late, mismatched or below the local confidence threshold")
        }
    }

    func recoveryEvidence(_ snapshot: UISnapshot, blockID: UUID, observation: InterruptionObservation, status: RecoveryEvidence.Status,
                          reason: String, deadline: Date, candidates: [ActionCandidate] = [], choice: CandidateChoice? = nil,
                          verification: CaptureID? = nil, origin: RecoveryEvidence.Origin = .interruption) async {
        let start = origin == .interruption ? await recoveryBudget.begin(now: clock.virtualNow()) : await recoveryBudget.beginEscape(now: clock.virtualNow())
        let actionCount = origin == .interruption ? await recoveryBudget.actionCount : await recoveryBudget.escapeCount
        let systemPrompt = observation.elements.contains { $0.originBundleIdentifier == "com.apple.springboard" }
        let maximumActions = origin == .interruption ? (systemPrompt ? max(5, recoveryPolicy.maximumActions) : recoveryPolicy.maximumActions) : recoveryPolicy.maximumEscapes
        let provenance = await driver.provenance(for: snapshot.captureID)
        let geometry = provenance.map { PerceptionGeometry(pixels: PixelSize(width: $0.pixelWidth, height: $0.pixelHeight), screenFrame: $0.screenFrame) }
        events.yield(.recovery(.init(origin: origin, blockID: blockID, captureID: snapshot.captureID, geometry: geometry, interruption: observation,
            candidates: candidates, choice: choice, provider: choice?.providerEvidence?.provider ?? (systemPrompt ? "local.system-prompt" : origin == .interruption ? "local.reviewed-policy" : "local.safe-escape"), status: status, reason: reason,
            actionCount: actionCount, maximumActions: maximumActions,
            recoveryStartedAt: clock.actual(start), deadline: clock.actual(min(deadline, start.addingTimeInterval(recoveryPolicy.timeoutSeconds))),
            minimumConfidence: recoveryPolicy.minimumConfidence, maximumCaptureAge: recoveryPolicy.maximumCaptureAge,
            recaptureCount: await recoveryBudget.recaptureCount, verificationCaptureID: verification)))
    }
    func recoveryDeadline(_ deadline: Date, origin: RecoveryEvidence.Origin = .interruption) async -> Date {
        let start = origin == .interruption ? await recoveryBudget.begin(now: clock.virtualNow()) : await recoveryBudget.beginEscape(now: clock.virtualNow())
        return min(deadline, start.addingTimeInterval(recoveryPolicy.timeoutSeconds))
    }
    func refuse(_ reason: String, snapshot: UISnapshot, blockID: UUID, observation: InterruptionObservation, deadline: Date,
                candidates: [ActionCandidate] = [], origin: RecoveryEvidence.Origin = .interruption) async throws -> Never {
        await recoveryEvidence(snapshot, blockID: blockID, observation: observation, status: .refused, reason: reason, deadline: deadline, candidates: candidates, origin: origin)
        throw DriverFailure.uncertain(reason)
    }
    func expected(_ observation: InterruptionObservation) -> Bool {
        guard observation.kind != .none else { return false }
        let snapshot = UISnapshot(captureID: CaptureID(), elements: observation.elements)
        return expectedAssertions.contains { assertion in
            switch assertion {
            case .doesNotExist: return false
            default: return evaluate(assertion, snapshot: snapshot)
            }
        }
    }
    func recoverSystemPrompt(_ snapshot: UISnapshot, blockID: UUID, observation: InterruptionObservation, deadline: Date) async throws -> UISnapshot {
        let buttons = snapshot.elements.filter { $0.role == "button" && $0.originBundleIdentifier == "com.apple.springboard" }
        let selected = InterruptionLibrary.systemPromptChoice(observation)
        let candidates = buttons.map { button in
            ActionCandidate(captureID: snapshot.captureID, title: button.label ?? "Unlabelled system button", action: .tapAlertButton(button),
                isSafeForAutomaticExecution: button == selected)
        }
        guard recoveryPolicy.allowSystemDismiss else {
            try await refuse("Automatic system prompt decisions are disabled", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline, candidates: candidates)
        }
        guard let selected else {
            try await refuse("No unique visible affirmative system button", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline, candidates: candidates)
        }
        let safe = candidates.filter(\.isSafeForAutomaticExecution)
        guard safe.count == 1 else {
            try await refuse("System button identity is ambiguous", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline, candidates: candidates)
        }
        let localChoice = CandidateChoice(candidateID: safe[0].id, captureID: snapshot.captureID, confidence: 1,
            rationale: "Automatic SpringBoard prompt decision: \(selected.label ?? "button")")
        do {
            return try await recoveryDispatch(.recoveryTap(captureID: snapshot.captureID, element: selected), snapshot: snapshot,
                blockID: blockID, observation: observation, candidates: candidates, choice: localChoice, deadline: deadline)
        } catch PerceptionFailure.staleCapture {
            let until = await recoveryDeadline(deadline)
            guard await recoveryBudget.recaptureCount < recoveryPolicy.maximumRecaptures, clock.virtualNow() < until else {
                try await refuse("Stale system prompt recapture budget exhausted", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline)
            }
            await recoveryBudget.consumeRecapture()
            await recoveryEvidence(snapshot, blockID: blockID, observation: observation, status: .recapture, reason: "System prompt capture aged before dispatch; reacquiring", deadline: deadline)
            return try await capture(until)
        }
    }
    func recoverInterruptions(_ initial: UISnapshot, blockID: UUID, deadline: Date) async throws -> UISnapshot {
        var snapshot = initial
        while true {
            let observation = InterruptionLibrary.recognize(snapshot)
            if observation.elements.contains(where: { $0.originBundleIdentifier == "com.apple.springboard" }) {
                snapshot = try await recoverSystemPrompt(snapshot, blockID: blockID, observation: observation, deadline: deadline)
                continue
            }
            if expected(observation) {
                await recoveryEvidence(snapshot, blockID: blockID, observation: observation, status: .refused,
                    reason: "Expected state suppresses automatic intervention; authored target resolution remains available", deadline: deadline)
                return snapshot
            }
            switch observation.kind {
            case .none, .keyboard, .unresolvedStep: return snapshot
            // Sheets are not reviewed interruptions. Authored resolution (or a
            // bounded safe escape) decides whether to clear them.
            case .firstRunSheet: return snapshot
            case .knownReminder, .alert, .permissionPrompt:
                let policy = InterruptionLibrary.exactPolicy(observation, policies: reviewedPolicies, bundleIdentifier: bundleIdentifier)
                let buttons = observation.elements.filter { $0.role == "button" }
                let candidates = buttons.map { button in
                    let risk = policy?.buttons.first { $0.identifier == button.identifier && $0.label == button.label }?.risk
                    let selectedByMode = recoveryPolicy.mode == .safeInferred || (button.identifier == policy?.automaticButtonIdentifier && button.label == policy?.automaticButtonLabel)
                    return ActionCandidate(captureID: snapshot.captureID, title: button.label ?? "Unlabelled button", action: .tapAlertButton(button),
                        isSafeForAutomaticExecution: risk == .nonDestructiveDismissal && selectedByMode && button.isEnabled == true && button.isHittable == true)
                }
                guard let policy, !policy.buttons.contains(where: { $0.risk == .destructive }), recoveryPolicy.mode != .askFail,
                      recoveryPolicy.knownInterruptionPolicies.contains(policy.id), recoveryPolicy.maximumActions > 0 else {
                    try await refuse("No enabled exact reviewed policy, ask/fail mode, or destructive action set", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline, candidates: candidates)
                }
                let safe = candidates.filter(\.isSafeForAutomaticExecution)
                guard safe.count == 1, let index = candidates.firstIndex(where: { $0.id == safe[0].id }) else {
                    try await refuse("Ambiguous or absent non-destructive candidate; automatic choice refused", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline, candidates: candidates)
                }
                let localChoice = CandidateChoice(candidateID: safe[0].id, captureID: snapshot.captureID, confidence: 1,
                    rationale: "Exact project-reviewed policy " + policy.id + "; complete alert context and button identities/labels; unique non-destructive action in " + recoveryPolicy.mode.rawValue)
                let choice = try await chooseRecovery(localChoice, candidates: candidates, snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline)
                do {
                    snapshot = try await recoveryDispatch(.recoveryTap(captureID: snapshot.captureID, element: buttons[index]), snapshot: snapshot,
                        blockID: blockID, observation: observation, candidates: candidates, choice: choice, deadline: deadline)
                } catch PerceptionFailure.staleCapture {
                    let until = await recoveryDeadline(deadline)
                    guard await recoveryBudget.recaptureCount < recoveryPolicy.maximumRecaptures, clock.virtualNow() < until else {
                        try await refuse("Stale interruption recapture budget exhausted", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline)
                    }
                    await recoveryBudget.consumeRecapture()
                    await recoveryEvidence(snapshot, blockID: blockID, observation: observation, status: .recapture, reason: "Capture aged before dispatch; reacquiring", deadline: deadline)
                    snapshot = try await capture(until)
                }
            case .transient:
                let until = await recoveryDeadline(deadline)
                guard clock.virtualNow() < until, await recoveryBudget.recaptureCount < recoveryPolicy.maximumRecaptures else {
                    try await refuse("Transient wait budget exhausted", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline)
                }
                await recoveryEvidence(snapshot, blockID: blockID, observation: observation, status: .waiting, reason: "Bounded wait for observed progress indicator", deadline: deadline)
                try await control.boundary(startsBlock: false)
                try await delay(0.25, deadline: until)
                await recoveryBudget.consumeRecapture()
                snapshot = try await capture(until)
            default:
                try await refuse(observation.reason, snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline)
            }
        }
    }
    func recoveryDispatch(_ action: DrivenAction, snapshot: UISnapshot, blockID: UUID, observation: InterruptionObservation,
                          candidates: [ActionCandidate], choice: CandidateChoice, deadline: Date,
                          origin: RecoveryEvidence.Origin = .interruption) async throws -> UISnapshot {
        let until = await recoveryDeadline(deadline, origin: origin)
        await recoveryEvidence(snapshot, blockID: blockID, observation: observation, status: .proposed, reason: choice.rationale ?? "Locally validated candidate", deadline: deadline, candidates: candidates, choice: choice, origin: origin)
        let systemPrompt = observation.elements.contains { $0.originBundleIdentifier == "com.apple.springboard" }
        let actionLimit = systemPrompt ? max(5, recoveryPolicy.maximumActions) : recoveryPolicy.maximumActions
        let withinBudget = origin == .interruption ? await recoveryBudget.actionCount < actionLimit : await recoveryBudget.escapeCount < recoveryPolicy.maximumEscapes
        guard clock.virtualNow() < until, withinBudget else {
            try await refuse("Recovery action/time budget exhausted", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline, candidates: candidates, origin: origin)
        }
        // A pause here can age the capture. Revalidation occurs after resume, before dispatch.
        try await control.boundary(startsBlock: false)
        try check(until)
        let age = Date().timeIntervalSince(snapshot.capturedAt)
        guard age >= 0, age < recoveryPolicy.maximumCaptureAge else { throw PerceptionFailure.staleCapture }
        let selected = try await recoveryGate.validateAndConsume(choice: choice, candidates: candidates, minimumConfidence: recoveryPolicy.minimumConfidence)
        switch (selected.action, action) {
        case (.tapAlertButton(let target), .recoveryTap(let id, let element)):
            guard id == selected.captureID, element == target else { throw DriverFailure.uncertain("Candidate/action mismatch") }
        case (.tapElement(let target), .tapElement(let element)):
            guard element == target, selected.captureID == snapshot.captureID,
                  snapshot.elements.filter({ $0 == target }).count == 1,
                  target.originBundleIdentifier == nil || target.originBundleIdentifier == bundleIdentifier else {
                throw DriverFailure.uncertain("Candidate/action mismatch")
            }
        case (.tapPoint(let point), .textTap(let capture, let perception, let text, let threshold, let age)):
            guard capture.id == selected.captureID,
                  try perception.uniqueMatch(text: text, minimumConfidence: threshold, capture: capture, maximumAge: age).center == point else { throw DriverFailure.uncertain("Candidate/action mismatch") }
        default: throw DriverFailure.uncertain("Unsupported recovery candidate/action pair")
        }
        if origin == .interruption { await recoveryBudget.consumeAction() } else { await recoveryBudget.consumeEscape() }
        events.yield(.actionStarted(blockID, action))
        do { try await driver.perform(action, deadline: clock.actual(until)) }
        catch is CancellationError { throw CancellationError() }
        catch { throw DriverFailure.uncertain("Recovery dispatch failed; no repeated mutation: \(error)") }
        try Task.checkCancellation()
        guard clock.virtualNow() < until else { throw DriverFailure.uncertain("Recovery completed after deadline") }
        events.yield(.action(blockID, action))
        await recoveryEvidence(snapshot, blockID: blockID, observation: observation, status: .dispatched, reason: "One capture consumed by one action", deadline: deadline, candidates: candidates, choice: choice, origin: origin)
        let after: UISnapshot
        do { after = try await capture(until) }
        catch is CancellationError { throw CancellationError() }
        catch { throw DriverFailure.uncertain("Recovery action completed but verification capture failed: \(error)") }
        let progressed: Bool
        if [.knownReminder, .alert, .permissionPrompt, .authenticationRequired, .optionalNotificationPrompt].contains(observation.kind) { progressed = !after.elements.contains { element in element.containingAlertContext != nil && observation.elements.contains { $0.containingAlertContext == element.containingAlertContext } } }
        else { progressed = after.elements != snapshot.elements }
        guard progressed else {
            try await refuse("No observable progress after one recovery action", snapshot: after, blockID: blockID, observation: observation, deadline: deadline, origin: origin)
        }
        await recoveryEvidence(snapshot, blockID: blockID, observation: observation, status: .verified, reason: "Fresh post-action capture verifies observable progress", deadline: deadline, candidates: candidates, choice: choice, verification: after.captureID, origin: origin)
        if origin == .interruption,
           [.knownReminder, .alert, .permissionPrompt, .authenticationRequired, .optionalNotificationPrompt].contains(observation.kind) {
            await recoveryBudget.finishInterruption()
        }
        return after
    }
    func resolveTap(_ targets: [TargetStrategy], blockID: UUID, upcoming: ArraySlice<TestBlock>? = nil, deadline: Date) async throws -> (DrivenAction?, PendingLocatorSuggestion?) {
        events.yield(.phase(.resolving))
        var snapshot = try await capture(deadline)
        var escaped = false
        while true {
            snapshot = try await recoverInterruptions(snapshot, blockID: blockID, deadline: deadline)
            for (index, target) in targets.enumerated() {
                let matches = matching(target, in: snapshot)
                if matches.isEmpty { continue }
                guard matches.count == 1 else { throw StepUnresolved.ambiguous("Ambiguous target") }
                guard matches[0].isEnabled == true, matches[0].isHittable == true else { throw StepUnresolved.notActionable("Target lacks enabled/hittable evidence") }
                let suggestion = locatorSuggestion(for: matches[0], targets: targets, matchedIndex: index, snapshot: snapshot, blockID: blockID)
                if let id = matches[0].identifier, !id.isEmpty { return (.tap(identifier: id), suggestion) }
                return (.tapElement(matches[0]), suggestion)
            }
            let observation = InterruptionLibrary.recognize(snapshot)
            if observation.elements.contains(where: { $0.originBundleIdentifier == "com.apple.springboard" }) {
                try await refuse("System alert is read-only; authored app input and OCR require review", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline)
            }
            if expected(observation) { try await refuse("Expected prompt retained; unresolved authored target cannot trigger OCR", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline) }
            if let advanced = advancedWaypoint(upcoming, snapshot: snapshot) {
                throw StepUnresolved.advanced("Screen already matches later step \"\(advanced.title)\"; continuing forward")
            }
            if !escaped, recoveryPolicy.allowSafeEscapes, let after = try await attemptEscape(snapshot, blockID: blockID, deadline: deadline, allowProgress: observation.kind != .none) {
                snapshot = after
                escaped = true
                continue
            }
            guard recoveryPolicy.mode != .askFail, recoveryPolicy.allowTextFallback, let text = targets.compactMap({ if case .text(let text) = $0 { return text }; return nil }).first else {
                if observation.kind == .keyboard { try await refuse("Unresolved target with keyboard present; no safe dismissal handler", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline) }
                throw StepUnresolved.targetMissing("Target not found; configured OCR fallback unavailable or disabled")
            }
            let until = await recoveryDeadline(deadline)
            guard clock.virtualNow() < until, await recoveryBudget.actionCount < recoveryPolicy.maximumActions else {
                try await refuse("Recovery action/time budget exhausted before OCR", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline)
            }
            do {
                guard let provenance = await driver.provenance(for: snapshot.captureID), try provenance.validatedTiming() else { throw PerceptionFailure.invalidTiming }
                let capture = ScreenCapture(id: snapshot.captureID, createdAt: snapshot.capturedAt,
                    pixelSize: PixelSize(width: provenance.pixelWidth, height: provenance.pixelHeight), screenshotRelativePath: "captures/" + provenance.screenshotName)
                let perception = try await driver.recognizeText(for: snapshot.captureID, deadline: clock.actual(until))
                events.yield(.perception(perception))
                let region = try perception.uniqueMatch(text: text, minimumConfidence: recoveryPolicy.minimumConfidence, capture: capture, maximumAge: recoveryPolicy.maximumCaptureAge)
                let candidate = ActionCandidate(captureID: snapshot.captureID, title: "Tap configured text: \(text)", action: .tapPoint(region.center), isSafeForAutomaticExecution: true)
                let localChoice = CandidateChoice(candidateID: candidate.id, captureID: snapshot.captureID, confidence: region.confidence, rationale: "Unique OCR match for explicit tap text fallback; transform and capture validated")
                let choice = try await chooseRecovery(localChoice, candidates: [candidate], snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline)
                _ = try await recoveryDispatch(.textTap(capture: capture, perception: perception, text: text, minimumConfidence: recoveryPolicy.minimumConfidence, maximumAge: recoveryPolicy.maximumCaptureAge),
                    snapshot: snapshot, blockID: blockID, observation: observation, candidates: [candidate], choice: choice, deadline: deadline)
                return (nil, nil)
            } catch PerceptionFailure.staleCapture {
                guard await recoveryBudget.recaptureCount < recoveryPolicy.maximumRecaptures, clock.virtualNow() < until else {
                    try await refuse("Stale OCR recapture budget exhausted", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline)
                }
                await recoveryBudget.consumeRecapture()
                await recoveryEvidence(snapshot, blockID: blockID, observation: observation, status: .recapture, reason: "Stale capture discarded; reacquiring pixels and semantics", deadline: deadline)
                try await control.boundary(startsBlock: false)
                snapshot = try await capture(until)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try await refuse("OCR fallback refused: \(error)", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline)
            }
        }
    }
}
