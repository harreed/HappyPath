import Foundation
import CryptoKit
import ProjectDomain

public enum DrivenAction: Codable, Sendable, Equatable {
    case tap(identifier: String)
    case typeText(String, identifier: String)
    case swipe(SwipeDirection, identifier: String?)
    case tapElement(UIElement)
    case typeTextElement(String, UIElement)
    case swipeElement(SwipeDirection, UIElement)
    case relaunch
    case device(DeviceAction)
    case recoveryTap(captureID: CaptureID, element: UIElement)
    case textTap(capture: ScreenCapture, perception: TextPerception, text: String, minimumConfidence: Double, maximumAge: Double)
    case visualTextTap(capture: ScreenCapture, perception: TextPerception, text: String, control: UIElement, minimumConfidence: Double, maximumAge: Double)
    /// Contains a Keychain reference, never a password. The companion receives only encrypted input.
    case secureTextTap(capture: ScreenCapture, perception: TextPerception, text: String, secret: SecretReference)
}

public enum SecretReference: Codable, Sendable, Equatable {
    case appleAccountPassword(account: String)
}

public enum ExecutionBlocker: Codable, Sendable, Equatable {
    case missingSecret(SecretReference)
    case credentialAccessRequired(SecretReference)
    case secureInputUnavailable(SecretReference)
    case secureInputUnverified(SecretReference)
    case authenticationChallenge(String)
    case legalConsentRequired(String)
    case humanAttestationRequired(String)
}

public enum DriverFailure: LocalizedError, Sendable {
    /// The adapter has positively established that no input was dispatched.
    case notDispatched(String)
    case uncertain(String)
    case unavailable(String)
    case missingSecret(SecretReference)
    case credentialAccessRequired(SecretReference)
    case secureInputUnavailable(SecretReference)
    case secureInputUnverified(SecretReference)
    public var errorDescription: String? {
        switch self {
        case .notDispatched(let message), .uncertain(let message), .unavailable(let message): return message
        case .missingSecret(.appleAccountPassword(let account)): return "Missing stored Apple Account password for \(account)"
        case .credentialAccessRequired(.appleAccountPassword(let account)): return "macOS Keychain authorization is required to read the stored Apple Account password for \(account)"
        case .secureInputUnavailable(.appleAccountPassword): return "iOS did not expose the Apple Account password field to automation; complete the Apple Account verification on the Simulator"
        case .secureInputUnverified(.appleAccountPassword): return "Apple Account password input could not be verified; complete Apple Account verification on the Simulator before rerunning"
        }
    }
}

/// An authored step that could not be performed and positively dispatched no
/// input. Safe to retry, safe to escape, and safe to carry forward: no
/// mutation is known to have occurred.
enum StepUnresolved: LocalizedError, Sendable, Equatable {
    case targetMissing(String)
    case ambiguous(String)
    case notActionable(String)
    /// The current screen already satisfies a later authored step. The runner
    /// skips ahead instead of waiting, escaping backwards or mutating blindly.
    case advanced(String)
    var errorDescription: String? { switch self { case .targetMissing(let message), .ambiguous(let message), .notActionable(let message), .advanced(let message): return message } }
}

/// Adapters must enforce each absolute deadline, including subprocess shutdown.
/// Unknown action completion must never be reported as notDispatched.
public protocol RunnerDriving: Sendable {
    func prepare(project: TestProject, deadline: Date) async throws
    func prepare(project: TestProject, deadline: Date, progress: @escaping @Sendable (ExecutionPhase) -> Void) async throws
    func applyStartingState(_ state: TestStartingState, deadline: Date) async throws
    func capture(deadline: Date) async throws -> UISnapshot
    func perform(_ action: DrivenAction, deadline: Date) async throws
    func provenance(for id: CaptureID) async -> CompanionCapture?
    func imageFingerprint(for id: CaptureID) async -> String?
    func visualImageData(for id: CaptureID) async throws -> Data
    func referenceImageData(for id: UUID) async throws -> Data
    func recognizeText(for id: CaptureID, deadline: Date) async throws -> TextPerception
    func recognizeTextFast(for id: CaptureID, deadline: Date) async throws -> TextPerception
    func warmupPerception(deadline: Date) async throws -> PerceptionWarmup
    func warmupPerceptionFast(deadline: Date) async throws -> PerceptionWarmup
    func stop() async
    func finish() async throws
}
public extension RunnerDriving {
    func applyStartingState(_ state: TestStartingState, deadline: Date) async throws {
        guard state.isDefault else { throw DriverFailure.unavailable("This runner cannot apply the requested test starting state") }
    }
    func provenance(for id: CaptureID) async -> CompanionCapture? { nil }
    func imageFingerprint(for id: CaptureID) async -> String? { nil }
    func visualImageData(for id: CaptureID) async throws -> Data { throw DriverFailure.unavailable("Capture image data is unavailable") }
    func referenceImageData(for id: UUID) async throws -> Data { throw DriverFailure.unavailable("Visual reference is unavailable") }
    func recognizeText(for id: CaptureID, deadline: Date) async throws -> TextPerception { throw DriverFailure.unavailable("Text perception is unavailable") }
    func recognizeTextFast(for id: CaptureID, deadline: Date) async throws -> TextPerception {
        try await recognizeText(for: id, deadline: deadline)
    }
    func warmupPerception(deadline: Date) async throws -> PerceptionWarmup { throw DriverFailure.unavailable("Text perception is unavailable") }
    func warmupPerceptionFast(deadline: Date) async throws -> PerceptionWarmup {
        try await warmupPerception(deadline: deadline)
    }
    func prepare(project: TestProject, deadline: Date, progress: @escaping @Sendable (ExecutionPhase) -> Void) async throws { try await prepare(project: project, deadline: deadline) }
    func finish() async throws { await stop() }
}

public enum ExecutionState: String, Codable, Sendable { case preparing, running, paused, stopping, finished }
public enum ExecutionPhase: String, Codable, Sendable { case preparingSimulator, building, installing, startingCompanion, launching, recording, resolving, performing, verifying, finalizing }
public enum ExecutionEvent: Codable, Sendable {
    case phase(ExecutionPhase)
    case state(ExecutionState)
    case suiteStarted(UUID)
    case testStarted(UUID)
    case blockStarted(UUID)
    case blockSkipped(UUID)
    case attempt(UUID, Int)
    case blockFinished(UUID, RunOutcome, duration: Double, reason: String?)
    case capture(UISnapshot)
    case captureProvenance(CompanionCapture)
    case perception(TextPerception)
    case visualComparison(VisualComparisonEvidence)
    case perceptionWarmup(PerceptionWarmup)
    case recovery(RecoveryEvidence)
    case locatorSuggestion(LocatorSuggestion)
    case candidateDecision(CandidateDecisionEvidence)
    case providerFallback(ProviderFallbackEvidence)
    case goalAssessment(GoalAssessmentEvidence)
    case failureSummary(FailureSummaryEvidence)
    case actionStarted(UUID, DrivenAction)
    case action(UUID, DrivenAction)
    case assertion(AssertionDefinition, Bool)
    case diagnostic(String)
    case blocker(ExecutionBlocker)
    case testFinished(UUID, RunOutcome)
    case suiteFinished(UUID, RunOutcome)
    case finished(ExecutionReport)
}
public struct TestExecutionResult: Codable, Sendable {
    public let testID: UUID
    public let outcome: RunOutcome
}
public struct ExecutionReport: Codable, Sendable {
    public let outcome: RunOutcome
    public let tests: [TestExecutionResult]
}
public struct ExecutionHandle: Sendable {
    public let events: AsyncStream<ExecutionEvent>
    public let task: Task<ExecutionReport, Never>
    public let control: ExecutionControl
    public func cancel() { task.cancel() }
}

public struct ExecutionEngine: Sendable {
    private let driver: any RunnerDriving
    private let candidateChooser: (any CandidateChoosing)?
    private let assertionEvaluator: any AssertionEvaluating
    private let failureSummariser: any FailureSummarising
    private let goalNavigator: any GoalNavigating
    private let goalReplayStore: any GoalReplayStoring
    private let visualComparator: (any VisualComparing)?
    private let imageAssessor: (any ImageAssessing)?
    private let fallbackImageAssessor: (any ImageAssessing)?
    private let primaryImageMinimumConfidence: Double?
    private let imageDisclosureChoice: ImageDisclosureChoice
    private let savedInputs: [GoalSavedInput]
    private let screenVisionEnabled: Bool
    public init(driver: any RunnerDriving, assertionEvaluator: any AssertionEvaluating = UnavailableAssertionEvaluator(), failureSummariser: any FailureSummarising = RecordedFailureSummariser(), candidateChooser: (any CandidateChoosing)? = nil, goalNavigator: any GoalNavigating = UnavailableGoalNavigator(), goalReplayStore: any GoalReplayStoring = GoalReplayStore(), visualComparator: (any VisualComparing)? = nil, imageAssessor: (any ImageAssessing)? = nil, fallbackImageAssessor: (any ImageAssessing)? = nil, primaryImageMinimumConfidence: Double? = nil, imageDisclosureChoice: ImageDisclosureChoice = .localOnly, savedInputs: [GoalSavedInput] = [], screenVisionEnabled: Bool = false) {
        self.driver = driver; self.candidateChooser = candidateChooser; self.assertionEvaluator = assertionEvaluator; self.failureSummariser = failureSummariser; self.goalNavigator = goalNavigator; self.goalReplayStore = goalReplayStore; self.visualComparator = visualComparator
        self.imageAssessor = imageAssessor; self.fallbackImageAssessor = fallbackImageAssessor
        self.primaryImageMinimumConfidence = primaryImageMinimumConfidence
        self.imageDisclosureChoice = imageDisclosureChoice
        self.savedInputs = savedInputs
        self.screenVisionEnabled = screenVisionEnabled
    }
    public func start(project: TestProject, selection: RunSelection = .all) -> ExecutionHandle {
        let (events, continuation) = AsyncStream<ExecutionEvent>.makeStream()
        let clock = ExecutionClock()
        let control = ExecutionControl(clock: clock, events: continuation)
        let task = Task { await execute(project: project, selection: selection, goalNavigation: false, events: continuation, clock: clock, control: control) }
        return ExecutionHandle(events: events, task: task, control: control)
    }
    public func startGoal(project: TestProject) -> ExecutionHandle {
        let (events, continuation) = AsyncStream<ExecutionEvent>.makeStream()
        let clock = ExecutionClock()
        let control = ExecutionControl(clock: clock, events: continuation)
        let task = Task { await execute(project: project, selection: .all, goalNavigation: true, events: continuation, clock: clock, control: control) }
        return ExecutionHandle(events: events, task: task, control: control)
    }
    private func execute(project: TestProject, selection: RunSelection, goalNavigation: Bool, events: AsyncStream<ExecutionEvent>.Continuation, clock: ExecutionClock, control: ExecutionControl) async -> ExecutionReport {
        let context = ExecutionContext(driver: driver, events: events, clock: clock, control: control,
            visualComparator: visualComparator, bundleIdentifier: project.app.bundleIdentifier,
            imageAssessor: imageAssessor, fallbackImageAssessor: fallbackImageAssessor,
            primaryImageMinimumConfidence: primaryImageMinimumConfidence, imageDisclosureChoice: imageDisclosureChoice)
        let wallDeadline = Date().addingTimeInterval(600)
        var results: [TestExecutionResult] = []
        var outcome: RunOutcome = .passed
        do {
            let selected = try project.selectedTests(selection)
            try Task.checkCancellation()
            events.yield(.state(.preparing))
            try await driver.prepare(project: project, deadline: min(wallDeadline, Date().addingTimeInterval(300))) { events.yield(.phase($0)) }
            if selected.contains(where: {
                project.recoveryPolicy(for: $0.test).allowTextFallback ||
                $0.test.goalAssessmentPolicy?.requirement == .ocr
            }) {
                events.yield(.diagnostic("Prewarming OCR before action-bearing capture"))
                do { events.yield(.perceptionWarmup(try await driver.warmupPerception(deadline: min(wallDeadline, Date().addingTimeInterval(120))))) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    if selected.contains(where: { project.recoveryPolicy(for: $0.test).allowTextFallback }) { throw error }
                    events.yield(.diagnostic("Screen-text recognition is unavailable; goal navigation will continue from accessibility evidence"))
                }
            }
            events.yield(.state(.running))
            if goalNavigation {
                guard selected.count == 1, let test = selected.first?.test,
                      !test.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DriverFailure.unavailable("A goal run requires exactly one nonempty goal")
                }
                let goalContext = ExecutionContext(driver: driver, events: events, clock: clock, control: control,
                    recoveryPolicy: project.defaultRecoveryPolicy ?? .init(maximumActions: 3, timeoutSeconds: 15, allowSystemDismiss: true, mode: .safeInferred), reviewedPolicies: project.reviewedAlertPolicies ?? [],
                    bundleIdentifier: project.app.bundleIdentifier, imageAssessor: imageAssessor,
                    fallbackImageAssessor: fallbackImageAssessor, primaryImageMinimumConfidence: primaryImageMinimumConfidence,
                    imageDisclosureChoice: imageDisclosureChoice, screenVisionEnabled: screenVisionEnabled)
                events.yield(.suiteStarted(selected[0].suite.id))
                events.yield(.testStarted(test.id))
                if !test.startingState.isDefault {
                    events.yield(.diagnostic("Applying configured starting state for \(test.name)"))
                    try await driver.applyStartingState(test.startingState, deadline: wallDeadline)
                }
                outcome = await goalContext.navigateGoal(test, navigator: goalNavigator, evaluator: assertionEvaluator, wallDeadline: wallDeadline,
                    replayStore: goalReplayStore, replayIdentity: try? GoalReplayRoute.Identity(project: project, test: test),
                    savedInputs: savedInputs)
                results.append(.init(testID: test.id, outcome: outcome))
                events.yield(.testFinished(test.id, outcome))
                events.yield(.suiteFinished(selected[0].suite.id, outcome))
            } else {
            var offset = 0
            while offset < selected.count {
                try Task.checkCancellation()
                let suite = selected[offset].suite
                let suiteTests = selected.dropFirst(offset).prefix { $0.suite.id == suite.id }
                events.yield(.suiteStarted(suite.id))
                let setupOutcome = await context.blocks(suite.setup, deadline: clock.virtualNow().addingTimeInterval(suite.setup.reduce(0) { $0 + $1.retryPolicy.timeoutSeconds }))
                var suiteOutcome = setupOutcome
                for selectedTest in suiteTests {
                    let test = selectedTest.test
                    events.yield(.testStarted(test.id))
                    var testOutcome = setupOutcome
                    var recoveredGoal = false
                    let deadline = clock.virtualNow().addingTimeInterval(test.timeoutSeconds)
                    var goalEvidence: GoalAssessmentEvidence?
                    var goalNavigationReason: String?
                    if setupOutcome == .passed {
                        if !test.startingState.isDefault {
                            events.yield(.diagnostic("Applying configured starting state for \(test.name)"))
                            try await driver.applyStartingState(test.startingState, deadline: clock.actual(deadline))
                        }
                        if test.effectiveExecutionMode == .goal {
                            if test.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                goalNavigationReason = "This goal test needs a goal before it can run"
                                events.yield(.diagnostic("This goal test needs a goal before it can run"))
                                testOutcome = .needsReview
                            } else {
                                let goalContext = ExecutionContext(driver: driver, events: events, clock: clock, control: control,
                                    visualComparator: visualComparator,
                                    recoveryPolicy: project.defaultRecoveryPolicy ?? .init(maximumActions: 3, timeoutSeconds: 15, allowSystemDismiss: true, mode: .safeInferred),
                                    reviewedPolicies: project.reviewedAlertPolicies ?? [], bundleIdentifier: project.app.bundleIdentifier,
                                    imageAssessor: imageAssessor, fallbackImageAssessor: fallbackImageAssessor,
                                    primaryImageMinimumConfidence: primaryImageMinimumConfidence, imageDisclosureChoice: imageDisclosureChoice,
                                    screenVisionEnabled: screenVisionEnabled)
                                let navigation = await goalContext.navigateGoalWithReason(test, navigator: goalNavigator,
                                    evaluator: assertionEvaluator, wallDeadline: clock.actual(deadline), replayStore: goalReplayStore,
                                    replayIdentity: try? GoalReplayRoute.Identity(project: project, test: test), savedInputs: savedInputs)
                                testOutcome = navigation.outcome
                                goalNavigationReason = navigation.reason
                                if testOutcome == .passed {
                                    let visualAssertions = test.assertions.filter {
                                        if case .imageMatches = $0 { return true }
                                        return false
                                    }
                                    if !visualAssertions.isEmpty {
                                        testOutcome = combine(testOutcome,
                                            await goalContext.assertions(visualAssertions, deadline: deadline))
                                    }
                                }
                            }
                        } else {
                        let context = ExecutionContext(driver: driver, events: events, clock: clock, control: control,
                            visualComparator: visualComparator,
                            candidateChooser: candidateChooser, recoveryPolicy: project.recoveryPolicy(for: test), reviewedPolicies: project.reviewedAlertPolicies ?? [], bundleIdentifier: project.app.bundleIdentifier, expectedAssertions: test.preconditions + test.assertions + test.blocks.filter(\.enabled).compactMap {
                                switch $0.action { case .assertion(let a), .wait(let a): return a; default: return nil }
                            }, imageAssessor: imageAssessor, fallbackImageAssessor: fallbackImageAssessor,
                            primaryImageMinimumConfidence: primaryImageMinimumConfidence, imageDisclosureChoice: imageDisclosureChoice)
                        testOutcome = await context.assertions(test.preconditions, deadline: deadline)
                        if testOutcome == .passed { testOutcome = await context.blocks(test.blocks, deadline: deadline, continueForward: true,
                            goalFallbackAvailable: !test.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                        // A missing scripted waypoint need not end a goal run.
                        // Continue from the live screen, then require independent
                        // goal evidence before replacing the tentative review.
                        if testOutcome == .needsReview, !test.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           clock.virtualNow() < deadline {
                            events.yield(.diagnostic("Scripted navigation needs review; trying the goal from the current screen"))
                            let recovered = await context.navigateGoal(test, navigator: goalNavigator, evaluator: assertionEvaluator, wallDeadline: clock.actual(deadline), savedInputs: savedInputs)
                            if recovered == .passed { testOutcome = .passed; recoveredGoal = true }
                            if recovered == .cancelled { testOutcome = .cancelled }
                        }
                        // Once live navigation independently verifies the goal,
                        // stale waypoint assertions do not override that proof.
                        if !recoveredGoal && (testOutcome == .passed || testOutcome == .needsReview) {
                            testOutcome = combine(testOutcome, await context.assertions(test.assertions, deadline: deadline))
                        }
                        }
                    }
                    if test.effectiveExecutionMode == .scripted && !recoveredGoal && !test.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        goalEvidence = await context.assessGoal(test, established: testOutcome, evaluator: assertionEvaluator, deadline: deadline)
                        if let goalEvidence {
                            events.yield(.goalAssessment(goalEvidence))
                            if testOutcome == .passed || testOutcome == .needsReview { testOutcome = combine(testOutcome, goalEvidence.outcome) }
                        }
                    }
                    if Task.isCancelled { testOutcome = .cancelled }
                    if testOutcome != .passed {
                        let summaryRequest = FailureSummaryRequest(testID: test.id, outcome: testOutcome, reason: goalEvidence?.reason ?? goalNavigationReason ?? "Execution ended with \(testOutcome.rawValue); see recorded block and assertion events", assessmentRequestID: goalEvidence?.request?.requestID)
                        let summary: FailureSummaryEvidence
                        do {
                            guard !Task.isCancelled, clock.virtualNow() < deadline, goalEvidence?.request?.mode != .imageUnavailable else { throw ProviderFailure.deadline }
                            summary = try await boundedProviderCall(deadline: min(clock.actual(deadline), Date().addingTimeInterval(10))) { try await failureSummariser.summarise(summaryRequest) }
                            guard summary.source.testID == test.id, summary.source.outcome == testOutcome, summary.source.reason == summaryRequest.reason, summary.source.assessmentRequestID == summaryRequest.assessmentRequestID, !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, summary.text.count <= 2000 else { throw ProviderFailure.invalidResponse }
                            events.yield(.failureSummary(summary))
                        } catch { events.yield(.failureSummary(try! await RecordedFailureSummariser().summarise(summaryRequest))) }
                    }
                    results.append(.init(testID: test.id, outcome: testOutcome))
                    events.yield(.testFinished(test.id, testOutcome))
                    suiteOutcome = combine(suiteOutcome, testOutcome)
                    if Task.isCancelled { break }
                }
                if !Task.isCancelled {
                    let teardown = await context.blocks(suite.teardown, deadline: clock.virtualNow().addingTimeInterval(suite.teardown.reduce(0) { $0 + $1.retryPolicy.timeoutSeconds }))
                    suiteOutcome = combine(suiteOutcome, teardown)
                }
                events.yield(.suiteFinished(suite.id, suiteOutcome))
                outcome = combine(outcome, suiteOutcome)
                offset += suiteTests.count
            }
            }
        } catch {
            events.yield(.diagnostic(error.localizedDescription))
            outcome = combine(outcome, classify(error))

        }
        events.yield(.state(.stopping))
        events.yield(.phase(.finalizing))
        events.yield(.diagnostic("Finalizing video and stopping companion"))
        do { try await driver.finish() }
        catch {
            events.yield(.diagnostic("Finalization failed: \(error)"))
            outcome = combine(outcome, .blocked)
            await driver.stop()
        }
        if Task.isCancelled { outcome = .cancelled }
        let report = ExecutionReport(outcome: outcome, tests: results)
        events.yield(.state(.finished)); events.yield(.finished(report)); events.finish()
        return report
    }
}

/// Last-resort dismissal inference: a query like `close button` (or `Back`)
/// may resolve a button the app names `Back`/`BackButton`/`xmark`. Only
/// controls whose whole phrase is a dismissal affordance qualify, and the
/// caller still requires a unique enabled/hittable match.
private func dismissals(_ query: String, role: String? = "button", in snapshot: UISnapshot) -> [UIElement] {
    guard TargetTextMatching.dismissalAffordance(query) else { return [] }
    let wantedRole = role ?? "button"
    return snapshot.elements.filter { element in
        TargetTextMatching.equals(element.role, wantedRole)
            && (TargetTextMatching.dismissalAffordance(element.label)
                || TargetTextMatching.dismissalAffordance(element.identifier))
    }
}
private func combine(_ a: RunOutcome, _ b: RunOutcome) -> RunOutcome {
    let priority: [RunOutcome] = [.passed, .needsReview, .blocked, .failed, .cancelled]
    return priority.firstIndex(of: a)! >= priority.firstIndex(of: b)! ? a : b
}
private func classify(_ error: Error) -> RunOutcome {
    if error is CancellationError { return .cancelled }
    if error is AssertionFailed { return .failed }
    if let unresolved = error as? StepUnresolved {
        switch unresolved { case .targetMissing: return .failed; case .ambiguous, .notActionable: return .blocked; case .advanced: return .needsReview }
    }
    if case DriverFailure.notDispatched = error { return .failed }
    if case DriverFailure.uncertain = error { return .needsReview }
    return .blocked
}
/// Steps that produced no mutation can be carried forward; everything else
/// (uncertain, environment failure, cancellation) stops the test.
private func isForwardContinuable(_ error: Error) -> Bool {
    if error is StepUnresolved || error is AssertionFailed { return true }
    if case DriverFailure.notDispatched = error { return true }
    return false
}
private struct AssertionFailed: LocalizedError { var errorDescription: String? { "The required assertion was not satisfied." } }
private func expiredUnavailable(_ error: Error, deadline: Date) -> Bool {
    guard Date() >= deadline else { return false }
    if case DriverFailure.unavailable = error { return true }
    return false
}
struct ExecutionContext: Sendable {
    let driver: any RunnerDriving
    let events: AsyncStream<ExecutionEvent>.Continuation
    let clock: ExecutionClock
    let control: ExecutionControl
    var visualComparator: (any VisualComparing)? = nil
    var candidateChooser: (any CandidateChoosing)? = nil
    var recoveryPolicy: RecoveryPolicy = .init()
    var reviewedPolicies: [ReviewedAlertPolicy] = []
    var bundleIdentifier: String = ""
    var expectedAssertions: [AssertionDefinition] = []
    var imageAssessor: (any ImageAssessing)? = nil
    var fallbackImageAssessor: (any ImageAssessing)? = nil
    var primaryImageMinimumConfidence: Double? = nil
    var imageDisclosureChoice: ImageDisclosureChoice = .localOnly
    var screenVisionEnabled = false
    let recoveryBudget = RecoveryBudget()
    let recoveryGate = CaptureActionGate()
    func check(_ deadline: Date) throws {
        try Task.checkCancellation()
        guard clock.virtualNow() < deadline else { throw DriverFailure.unavailable("Execution deadline exceeded") }
    }
    func capture(_ deadline: Date) async throws -> UISnapshot {
        try check(deadline)
        let snapshot = try await driver.capture(deadline: clock.actual(deadline))
        try check(deadline)
        try await recoveryGate.activate(snapshot.captureID)
        if let provenance = await driver.provenance(for: snapshot.captureID) { events.yield(.captureProvenance(provenance)) }
        events.yield(.capture(snapshot)); return snapshot
    }
    func matching(_ target: TargetStrategy, in snapshot: UISnapshot) -> [UIElement] {
        switch target {
        case .identifier(let id):
            // Identifiers are code: exact (tolerant) first, never substring
            // on the identifier field itself — `login` must not match `loginButton`.
            let exact = snapshot.elements.filter { element in
                element.identifier.map { TargetTextMatching.equals($0, id) } ?? false
            }
            if !exact.isEmpty { return exact }
            // Forgiving fallback: the user may have guessed an identifier
            // from the visible label (`Sign In With Apple Button` for label
            // `Sign in with Apple`). Match the guess against label/value.
            // Uniqueness is still enforced by the caller.
            let forgiving = snapshot.elements.filter { element in
                TargetTextMatching.containsEither(element.label, id)
                    || TargetTextMatching.containsEither(element.value, id)
            }
            return forgiving.isEmpty ? dismissals(id, in: snapshot) : forgiving
        case .text(let text):
            let exact = snapshot.elements.filter { element in
                TargetTextMatching.equals(element.label, text) || TargetTextMatching.equals(element.value, text)
            }
            if !exact.isEmpty { return exact }
            let forgiving = snapshot.elements.filter { element in
                TargetTextMatching.containsEither(element.label, text) || TargetTextMatching.containsEither(element.value, text)
            }
            return forgiving.isEmpty ? dismissals(text, in: snapshot) : forgiving
        case .semantic(let role, let label, let value):
            let roleMatches: (UIElement) -> Bool = { element in
                guard let role else { return true }
                return TargetTextMatching.equals(element.role, role)
            }
            let exact = snapshot.elements.filter { element in
                roleMatches(element)
                    && TargetTextMatching.fieldEquals(element.label, label)
                    && TargetTextMatching.fieldEquals(element.value, value)
            }
            if !exact.isEmpty { return exact }
            // Vague fallback: role must still match exactly (tolerant),
            // label/value may be substrings in either direction.
            // Uniqueness is still enforced by the caller.
            let vague = snapshot.elements.filter { element in
                roleMatches(element)
                    && TargetTextMatching.fieldContains(element.label, label)
                    && TargetTextMatching.fieldContains(element.value, value)
            }
            if !vague.isEmpty { return vague }
            guard value == nil, let label else { return [] }
            return dismissals(label, role: role, in: snapshot)
        }
    }
    /// The first upcoming enabled step whose authored expectation already
    /// holds on this screen. A match means the app has moved ahead: skip the
    /// unresolved step instead of waiting, escaping backwards or mutating.
    func advancedWaypoint(_ upcoming: ArraySlice<TestBlock>?, snapshot: UISnapshot) -> TestBlock? {
        guard let upcoming else { return nil }
        for block in upcoming.prefix(3) where block.enabled {
            switch block.action {
            case .tap(let targets), .typeText(_, let targets), .swipe(_, let targets):
                guard !targets.isEmpty else { continue }
                if targets.contains(where: { target in
                    matching(target, in: snapshot).contains { $0.isEnabled == true && $0.isHittable == true }
                }) { return block }
            case .wait(let assertion), .assertion(let assertion):
                if case .doesNotExist = assertion { continue }
                if case .imageMatches = assertion { continue }
                if evaluate(assertion, snapshot: snapshot) { return block }
            case .relaunch:
                continue
            case .device:
                continue
            }
        }
        return nil
    }
    func evaluate(_ assertion: AssertionDefinition, snapshot: UISnapshot) -> Bool {
        switch assertion {
        case .exists(let t): return !matching(t, in: snapshot).isEmpty
        case .doesNotExist(let t): return matching(t, in: snapshot).isEmpty
        case .valueEquals(let t, let value):
            let matches = matching(t, in: snapshot)
            guard matches.count == 1, let actual = matches[0].value else { return false }
            return TargetTextMatching.equals(actual, value)
        case .valueContains(let t, let value):
            let matches = matching(t, in: snapshot); return matches.count == 1 && TargetTextMatching.containsEither(matches[0].value, value)
        case .textVisible(let text): return snapshot.elements.contains { TargetTextMatching.containsEither($0.label, text) || TargetTextMatching.containsEither($0.value, text) }
        case .imageMatches: return false // Evaluated separately from screenshot pixels.
        }
    }
    func evaluateAssertion(_ definition: AssertionDefinition, snapshot: UISnapshot,
                           deadline: Date) async throws -> Bool {
        guard case .imageMatches(let referenceID, let referenceSHA256, let mean, let fraction) = definition else {
            return evaluate(definition, snapshot: snapshot)
        }
        guard let visualComparator else { throw DriverFailure.unavailable("Local visual comparison is unavailable") }
        guard let provenance = await driver.provenance(for: snapshot.captureID),
              try provenance.validatedTiming(),
              provenance.snapshot.capturedAt == snapshot.capturedAt,
              provenance.pixelWidth > 0, provenance.pixelHeight > 0,
              (0..<8).contains(Date().timeIntervalSince(snapshot.capturedAt)) else {
            throw DriverFailure.uncertain("Visual assertion needs a fresh capture with verified image provenance")
        }
        try check(deadline)
        let capture = ScreenCapture(id: snapshot.captureID, createdAt: snapshot.capturedAt,
            pixelSize: .init(width: provenance.pixelWidth, height: provenance.pixelHeight),
            screenshotRelativePath: "captures/" + provenance.screenshotName)
        let actual = try await driver.visualImageData(for: snapshot.captureID)
        let reference = try await driver.referenceImageData(for: referenceID)
        let digest = SHA256.hash(data: reference).map { String(format: "%02x", $0) }.joined()
        guard digest == referenceSHA256 else { throw DriverFailure.uncertain("Approved visual reference has changed") }
        let policy = VisualComparisonPolicy(maximumMeanChannelDifference: mean,
            maximumChangedPixelFraction: fraction)
        let evidence = try visualComparator.compare(actualImageData: actual,
            referenceImageData: reference, capture: capture, policy: policy)
        let actualDigest = SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined()
        try evidence.validate(capture: capture, actualImageSHA256: actualDigest)
        try check(deadline)
        events.yield(.visualComparison(evidence))
        return evidence.matchesReference
    }
    func assertions(_ definitions: [AssertionDefinition], deadline: Date) async -> RunOutcome {
        do { try await control.boundary(startsBlock: false) } catch { return classify(error) }
        var outcome: RunOutcome = .passed
        if !definitions.isEmpty { events.yield(.phase(.verifying)) }
        for definition in definitions {
            do {
                let value = try await evaluateAssertion(definition, snapshot: try await capture(deadline), deadline: deadline)
                events.yield(.assertion(definition, value))
                if !value { outcome = .failed }
            } catch {
                events.yield(.diagnostic("Assertion evidence failed: \(error)"))
                return combine(outcome, classify(error))
            }
        }
        return outcome
    }
    func resolve(_ targets: [TargetStrategy], deadline: Date, blockID: UUID, upcoming: ArraySlice<TestBlock>? = nil) async throws -> (UIElement, PendingLocatorSuggestion?) {
        events.yield(.phase(.resolving))
        var snapshot = try await recoverInterruptions(try await capture(deadline), blockID: blockID, deadline: deadline)
        var escaped = false
        while true {
            for (index, target) in targets.enumerated() {
                let matches = matching(target, in: snapshot)
                if matches.isEmpty { continue }
                guard matches.count == 1 else { throw StepUnresolved.ambiguous("Ambiguous target") }
                guard matches[0].isEnabled == true, matches[0].isHittable == true else {
                    throw StepUnresolved.notActionable("Target lacks enabled/hittable evidence")
                }
                return (matches[0], locatorSuggestion(for: matches[0], targets: targets, matchedIndex: index, snapshot: snapshot, blockID: blockID))
            }
            let observation = InterruptionLibrary.recognize(snapshot)
            if expected(observation) { try await refuse("Expected state retained; authored target unresolved", snapshot: snapshot, blockID: blockID, observation: observation, deadline: deadline) }
            if let advanced = advancedWaypoint(upcoming, snapshot: snapshot) {
                throw StepUnresolved.advanced("Screen already matches later step \"\(advanced.title)\"; continuing forward")
            }
            guard !escaped, recoveryPolicy.allowSafeEscapes else { throw StepUnresolved.targetMissing("Target not found") }
            guard let after = try await attemptEscape(snapshot, blockID: blockID, deadline: deadline, allowProgress: observation.kind != .none) else {
                throw StepUnresolved.targetMissing("Target not found")
            }
            snapshot = after
            escaped = true
        }
    }
    /// Runs enabled blocks in order. With `continueForward`, a step that
    /// positively dispatched no input and cannot escape is carried forward as
    /// needs review (or failed for explicit assertions) so later steps can
    /// re-establish the expected state. A run that keeps missing its targets
    /// is off course: after `maximumUnresolvedSteps` consecutive unresolved
    /// steps it stops with the honest outcome. Uncertain mutations never
    /// continue.
    func blocks(_ definitions: [TestBlock], deadline: Date, continueForward: Bool = false, goalFallbackAvailable: Bool = false) async -> RunOutcome {
        var outcome: RunOutcome = .passed
        var consecutiveUnresolved = 0
        let lastEnabled = definitions.lastIndex(where: \.enabled)
        for (index, block) in definitions.enumerated() {
            if !block.enabled { events.yield(.blockSkipped(block.id)); continue }
            do { try await control.boundary(breakpoint: block.breakpoint) }
            catch { return combine(outcome, classify(error)) }
            events.yield(.blockStarted(block.id))
            let started = Date()
            let blockDeadline = min(deadline, clock.virtualNow().addingTimeInterval(block.retryPolicy.timeoutSeconds))
            var provenNotDispatched = false
            var succeeded = false
            var failure: Error?
            let upcoming = continueForward ? definitions[(index + 1)...] : nil
            do {
                for attempt in 1...block.retryPolicy.maximumAttempts {
                    events.yield(.attempt(block.id, attempt))
                    do { try await execute(block, upcoming: upcoming, deadline: blockDeadline); succeeded = true; break }
                    catch StepUnresolved.targetMissing(let message) where attempt < block.retryPolicy.maximumAttempts {
                        provenNotDispatched = true
                        events.yield(.diagnostic("Retry before dispatch: \(message)"))
                        try await delay(block.retryPolicy.delaySeconds, deadline: blockDeadline)
                    }
                    catch DriverFailure.notDispatched(let message) where attempt < block.retryPolicy.maximumAttempts {
                        provenNotDispatched = true
                        events.yield(.diagnostic("Retry before dispatch: \(message)"))
                        try await delay(block.retryPolicy.delaySeconds, deadline: blockDeadline)
                    }
                    catch { failure = error; break }
                }
            } catch { failure = error }
            if succeeded {
                consecutiveUnresolved = 0
                events.yield(.blockFinished(block.id, .passed, duration: Date().timeIntervalSince(started), reason: nil))
                continue
            }
            let error = failure ?? StepUnresolved.targetMissing("Unresolved step")
            var hard = provenNotDispatched && expiredUnavailable(error, deadline: clock.actual(blockDeadline)) ? RunOutcome.failed : classify(error)
            // An advance that cannot be carried (continuation disabled or no
            // later steps) is an unresolved step, not a review-only outcome.
            if case StepUnresolved.advanced = error { hard = .failed }
            let laterStepsRemain = index < (lastEnabled ?? index)
            guard continueForward, isForwardContinuable(error), laterStepsRemain || goalFallbackAvailable,
                  recoveryPolicy.maximumUnresolvedSteps > 0 else {
                events.yield(.diagnostic(error.localizedDescription))
                events.yield(.blockFinished(block.id, hard, duration: Date().timeIntervalSince(started), reason: error.localizedDescription))
                return combine(outcome, hard)
            }
            // Too many consecutive misses means the app is no longer the
            // state this test describes: stop honestly instead of wandering.
            if consecutiveUnresolved >= recoveryPolicy.maximumUnresolvedSteps {
                let reason = "Off course after \(consecutiveUnresolved) consecutive unresolved steps; later steps were not attempted"
                events.yield(.diagnostic(reason))
                events.yield(.blockFinished(block.id, .needsReview, duration: Date().timeIntervalSince(started), reason: reason))
                return combine(outcome, .needsReview)
            }
            consecutiveUnresolved += 1
            let carried: RunOutcome = {
                if case .assertion = block.action { return .failed }
                return .needsReview
            }()
            outcome = combine(outcome, carried)
            events.yield(.diagnostic("\(error.localizedDescription); continuing forward to later steps"))
            events.yield(.blockFinished(block.id, carried, duration: Date().timeIntervalSince(started), reason: "Continued forward after an unresolved step: \(error.localizedDescription)"))
        }
        do { try await control.boundary(startsBlock: false) } catch { return combine(outcome, classify(error)) }
        return outcome
    }
    func delay(_ seconds: Double, deadline: Date) async throws {
        try check(deadline)
        let remaining = clock.actual(deadline).timeIntervalSinceNow
        try await Task.sleep(for: .seconds(min(seconds, remaining)))
        try check(deadline)
    }
    func execute(_ block: TestBlock, upcoming: ArraySlice<TestBlock>? = nil, deadline: Date) async throws {
        try check(deadline)
        let action: DrivenAction
        var pendingSuggestion: PendingLocatorSuggestion?
        switch block.action {
        case .assertion(let assertion):
            events.yield(.phase(.verifying))
            let passed = try await evaluateAssertion(assertion, snapshot: try await capture(deadline), deadline: deadline)
            events.yield(.assertion(assertion, passed))
            if !passed { throw AssertionFailed() }; return
        case .wait(let assertion):
            events.yield(.phase(.verifying))
            var observedFalse = false
            var falseSince: Date?
            var lastEscape = Date.distantPast
            do { while true {
                let snapshot = try await capture(deadline)
                let passed = try await evaluateAssertion(assertion, snapshot: snapshot, deadline: deadline)
                events.yield(.assertion(assertion, passed))
                if passed { return }
                let now = clock.virtualNow()
                if falseSince == nil { falseSince = now }
                observedFalse = true
                // A later authored step already visible means the app moved
                // ahead: skip forward now instead of waiting out the timeout.
                if let advanced = advancedWaypoint(upcoming, snapshot: snapshot) {
                    throw StepUnresolved.advanced("Screen already matches later step \"\(advanced.title)\"; continuing forward")
                }
                // A wait that stays false is a stuck step: after a full second
                // of no progress, one bounded safe escape may clear an
                // obstruction or advance an unambiguous progress control.
                if recoveryPolicy.allowSafeEscapes, let since = falseSince, now.timeIntervalSince(since) >= 1, now.timeIntervalSince(lastEscape) >= 1 {
                    lastEscape = now
                    if try await attemptEscape(snapshot, blockID: block.id, deadline: deadline, allowProgress: true) != nil { continue }
                }
                try await delay(0.1, deadline: deadline)
            } } catch {
                if observedFalse && expiredUnavailable(error, deadline: clock.actual(deadline)) { throw AssertionFailed() }
                throw error
            }
        case .tap(let targets):
            let resolved = try await resolveTap(targets, blockID: block.id, upcoming: upcoming, deadline: deadline)
            guard let tapAction = resolved.0 else { return }
            action = tapAction; pendingSuggestion = resolved.1
        case .typeText(let text, let targets):
            let (element, suggestion) = try await resolve(targets, deadline: deadline, blockID: block.id, upcoming: upcoming)
            pendingSuggestion = suggestion
            if let id = element.identifier, !id.isEmpty { action = .typeText(text, identifier: id) }
            else { action = .typeTextElement(text, element) }
        case .swipe(let direction, let targets):
            if targets.isEmpty { _ = try await capture(deadline); action = .swipe(direction, identifier: nil) }
            else {
                let (element, suggestion) = try await resolve(targets, deadline: deadline, blockID: block.id, upcoming: upcoming)
                pendingSuggestion = suggestion
                if let id = element.identifier, !id.isEmpty { action = .swipe(direction, identifier: id) }
                else { action = .swipeElement(direction, element) }
            }
        case .relaunch:
            _ = try await capture(deadline)
            action = .relaunch
        case .device(let deviceAction):
            _ = try await capture(deadline)
            action = .device(deviceAction)
        }
        try check(deadline)
        events.yield(.actionStarted(block.id, action))
        events.yield(.phase(.performing))
        events.yield(.diagnostic("Performing \(block.title)"))
        try await driver.perform(action, deadline: clock.actual(deadline))
        // A late successful response is uncertain, never eligible for another mutation.
        guard clock.virtualNow() < deadline else { throw DriverFailure.uncertain("Action completed after deadline") }
        try Task.checkCancellation()
        events.yield(.action(block.id, action))
        events.yield(.phase(.verifying))
        events.yield(.diagnostic("Capturing post-action evidence"))
        // Never let evidence collection failures re-enter the mutation retry path.
        do {
            let after = try await capture(deadline)
            if let pendingSuggestion { events.yield(.locatorSuggestion(pendingSuggestion.completed(after: after.captureID))) }
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw DriverFailure.uncertain("Action succeeded but follow-up capture failed: \(error)") }
    }
}
