import XCTest
import Foundation
import ProjectDomain
@testable import RunnerCore

private let contextText = "Prompt\nOptional reminder\nNot Now\nEnable"
private func alertElement(_ id: String, _ label: String, context: String = contextText, buttonRole: String? = nil) -> UIElement {
    UIElement(identifier: id, role: "button", label: label, value: nil, frame: .init(x: 0, y: 0, width: 20, height: 20), isEnabled: true, isHittable: true,
        containingAlertIdentifier: "alert:Prompt", containingAlertContext: context, buttonRole: buttonRole)
}
private func reviewed(buttons: [ReviewedAlertButton]? = nil) -> ReviewedAlertPolicy {
    .init(id: "optional", bundleIdentifier: "test.app", alertIdentifier: "alert:Prompt", exactContext: contextText,
        buttons: buttons ?? [.init(identifier: "later", label: "Not Now", risk: .nonDestructiveDismissal), .init(identifier: "enable", label: "Enable", risk: .unknown)], automaticButtonIdentifier: "later", automaticButtonLabel: "Not Now")
}
private actor RecoveryDriver: RunnerDriving {
    var elements: [UIElement]
    let noProgress: Bool
    let reintroduceAfterTarget: Bool
    let originalElements: [UIElement]
    var actions: [DrivenAction] = []
    var warmups = 0
    var ocrCalls = 0
    init(_ elements: [UIElement], noProgress: Bool = false, reintroduceAfterTarget: Bool = false) { self.elements = elements; self.originalElements = elements; self.noProgress = noProgress; self.reintroduceAfterTarget = reintroduceAfterTarget }
    func prepare(project: TestProject, deadline: Date) {}
    func capture(deadline: Date) -> UISnapshot { .init(captureID: .init(), elements: elements) }
    func perform(_ action: DrivenAction, deadline: Date) {
        actions.append(action)
        if reintroduceAfterTarget, case .tap(identifier: "target") = action { elements = originalElements }
        if case .recoveryTap = action, !noProgress { elements = [UIElement(identifier: "target", role: "button", label: "Target", value: nil, frame: nil, isEnabled: true, isHittable: true)] }
    }
    func stop() {}
}
final class RecoveryTests: XCTestCase {
    private func run(_ driver: RecoveryDriver, policy: RecoveryPolicy, reviewedPolicies: [ReviewedAlertPolicy] = [reviewed()], blocks: [TestBlock]? = nil, assertions: [AssertionDefinition] = [], chooser: (any CandidateChoosing)? = nil) async -> (ExecutionReport, [ExecutionEvent]) {
        let project = TestProject(name: "Recovery", app: .init(projectPath: "Test.xcodeproj", scheme: "Test", bundleIdentifier: "test.app"), simulator: .init(deviceID: "device"),
            categories: [.init(name: "c", suites: [.init(name: "s", tests: [.init(name: "t", blocks: blocks ?? [.init(title: "Target", action: .tap(targets: [.identifier("target")]))], assertions: assertions, recoveryPolicy: policy)])])], reviewedAlertPolicies: reviewedPolicies)
        let handle = ExecutionEngine(driver: driver, candidateChooser: chooser).start(project: project)
        var events: [ExecutionEvent] = []
        for await event in handle.events { events.append(event) }
        return (await handle.task.value, events)
    }
    private var automatic: RecoveryPolicy { .init(maximumActions: 2, knownInterruptionPolicies: ["optional"], mode: .knownAutomatic, candidateProvider: .local) }
    func testSystemPermissionCannotUseAppPolicyOrExpectedOverride() async {
        let system = UIElement(identifier: "later", role: "button", label: "Allow", value: nil, frame: nil, isEnabled: true, isHittable: nil,
            containingAlertIdentifier: "alert:Prompt", containingAlertContext: contextText, originBundleIdentifier: "com.apple.springboard")
        let observation = InterruptionLibrary.recognize(.init(captureID: .init(), elements: [system]))
        XCTAssertEqual(observation.kind, .permissionPrompt)
        XCTAssertNil(InterruptionLibrary.exactPolicy(observation, policies: [reviewed()], bundleIdentifier: "test.app"))
        let target = UIElement(identifier: "target", role: "button", label: "Target", value: nil, frame: nil)
        let driver = RecoveryDriver([system, target])
        let (report, events) = await run(driver, policy: automatic, assertions: [.textVisible("Allow")])
        XCTAssertEqual(report.outcome, .needsReview)
        let actions = await driver.actions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(events.contains { if case .actionStarted = $0 { return true }; return false })
    }
    private func systemAuthElements(closeHittable: Bool? = true, duplicateClose: Bool = false) -> [UIElement] {
        let context = "Sign in to your Apple Account\nYou need to sign in to your Apple Account in Settings.\nClose\nSettings"
        let alert = UIElement(identifier: nil, role: "alert", label: "Sign in to your Apple Account", value: nil, frame: nil,
            isEnabled: true, isHittable: nil, containingAlertIdentifier: "alert:Sign in to your Apple Account",
            containingAlertContext: context, originBundleIdentifier: "com.apple.springboard")
        let close = UIElement(identifier: nil, role: "button", label: "Close", value: nil, frame: nil,
            isEnabled: true, isHittable: closeHittable, containingAlertIdentifier: "alert:Sign in to your Apple Account",
            containingAlertContext: context, originBundleIdentifier: "com.apple.springboard")
        let settings = UIElement(identifier: nil, role: "button", label: "Settings", value: nil, frame: nil,
            isEnabled: true, isHittable: true, containingAlertIdentifier: "alert:Sign in to your Apple Account",
            containingAlertContext: context, originBundleIdentifier: "com.apple.springboard")
        var elements = [alert, close, settings]
        if duplicateClose { elements.append(close) }
        return elements
    }
    func testSystemAuthRecognizedAsDismissOnly() {
        let observation = InterruptionLibrary.recognize(.init(captureID: .init(), elements: systemAuthElements()))
        XCTAssertEqual(observation.kind, .authenticationRequired)
        XCTAssertEqual(InterruptionLibrary.uniqueSystemDismiss(observation)?.label, "Close")
        // Settings never qualifies, even though it is enabled and hittable.
        let settings = systemAuthElements().first { $0.label == "Settings" }!
        XCTAssertFalse(InterruptionLibrary.isSystemDismissButton(settings))
    }
    func testAppleAccountVerificationOffersOnlyNotNow() {
        let context = "Apple\u{00a0}Account Verification\nEnter the password for a test account in Settings.\nNot Now\nSettings"
        let elements = ["Apple\u{00a0}Account Verification", "Not Now", "Settings"].enumerated().map { index, label in
            UIElement(identifier: nil, role: index == 0 ? "alert" : "button", label: label, value: nil, frame: nil,
                isEnabled: true, isHittable: index > 0, containingAlertIdentifier: "alert:Apple Account Verification",
                containingAlertContext: context, originBundleIdentifier: "com.apple.springboard")
        }
        let observation = InterruptionLibrary.recognize(.init(captureID: .init(), elements: elements))
        XCTAssertEqual(observation.kind, .authenticationRequired)
        XCTAssertEqual(InterruptionLibrary.uniqueSystemDismiss(observation)?.label, "Not Now")
    }
    func testOptionalNotificationPromptAcceptsAllowByDefault() async {
        let context = "“Example App” Would Like to Send You Notifications\nNotifications may include alerts, sounds and icon badges. These can be configured in Settings.\nDon’t Allow\nAllow"
        let elements = ["“Example App” Would Like to Send You Notifications", "Don’t Allow", "Allow"].enumerated().map { index, label in
            UIElement(identifier: nil, role: index == 0 ? "alert" : "button", label: label, value: nil, frame: nil,
                isEnabled: true, isHittable: index > 0, containingAlertIdentifier: "alert:Notifications",
                containingAlertContext: context, originBundleIdentifier: "com.apple.springboard")
        }
        let observation = InterruptionLibrary.recognize(.init(captureID: .init(), elements: elements))
        XCTAssertEqual(observation.kind, .optionalNotificationPrompt)
        XCTAssertEqual(InterruptionLibrary.systemPromptChoice(observation)?.label, "Allow")
        let driver = RecoveryDriver(elements)
        let (report, _) = await run(driver, policy: RecoveryPolicy())
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        guard let first = actions.first, case .recoveryTap(_, let button) = first else { return XCTFail("Expected notification acceptance") }
        XCTAssertEqual(button.label, "Allow")
    }
    func testSystemAuthDismissesCloseWhenExplicitlyEnabled() async {
        let driver = RecoveryDriver(systemAuthElements())
        let policy = automatic.replacing(allowSystemDismiss: true)
        let (report, events) = await run(driver, policy: policy)
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions.count, 2)
        guard case .recoveryTap(_, let element) = actions[0] else { return XCTFail("First action must be system dismiss") }
        XCTAssertEqual(element.label, "Close")
        XCTAssertEqual(element.originBundleIdentifier, "com.apple.springboard")
        XCTAssertTrue(events.contains { if case .recovery(let e) = $0 { return e.status == .verified && e.interruption.kind == .authenticationRequired }; return false })
    }
    func testSystemPromptCanBeDisabled() async {
        let driver = RecoveryDriver(systemAuthElements())
        let (report, _) = await run(driver, policy: automatic.replacing(allowSystemDismiss: false))
        XCTAssertEqual(report.outcome, .needsReview)
        let actions = await driver.actions
        XCTAssertTrue(actions.isEmpty)
    }
    func testSystemPromptDefaultOverridesAppAlertAskFailMode() async {
        let driver = RecoveryDriver(systemAuthElements())
        let policy = automatic.replacing(mode: .askFail, allowSystemDismiss: true)
        let (report, _) = await run(driver, policy: policy)
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions.count, 2)
    }
    func testSystemAuthAmbiguousOrUnhittableCloseRefuses() async {
        for elements in [systemAuthElements(closeHittable: false), systemAuthElements(closeHittable: nil), systemAuthElements(duplicateClose: true)] {
            let driver = RecoveryDriver(elements)
            let (report, _) = await run(driver, policy: automatic.replacing(allowSystemDismiss: true))
            XCTAssertEqual(report.outcome, .needsReview)
            let actions = await driver.actions
            XCTAssertTrue(actions.isEmpty)
        }
    }
    func testGenericSpringBoardPermissionAcceptsHighestAccessByDefault() async {
        let context = "App Would Like to Access Your Location\nAllow Once\nAllow While Using App\nDon't Allow"
        let elements = ["App Would Like to Access Your Location", "Allow Once", "Allow While Using App", "Don't Allow"].enumerated().map { index, label in
            UIElement(identifier: nil, role: index == 0 ? "alert" : "button", label: label, value: nil, frame: nil,
                isEnabled: true, isHittable: index > 0, containingAlertIdentifier: "alert:Location",
                containingAlertContext: context, originBundleIdentifier: "com.apple.springboard")
        }
        let observation = InterruptionLibrary.recognize(.init(captureID: .init(), elements: elements))
        XCTAssertEqual(InterruptionLibrary.systemPromptChoice(observation)?.label, "Allow While Using App")
        let driver = RecoveryDriver(elements)
        let (report, _) = await run(driver, policy: RecoveryPolicy())
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        guard let first = actions.first, case .recoveryTap(_, let button) = first else { return XCTFail("Expected system permission acceptance") }
        XCTAssertEqual(button.label, "Allow While Using App")
    }
    func testAmbiguousSystemAffirmativesRequireReview() async {
        let context = "Choose access\nAllow\nAllow"
        let elements = ["Choose access", "Allow", "Allow"].enumerated().map { index, label in
            UIElement(identifier: nil, role: index == 0 ? "alert" : "button", label: label, value: nil, frame: nil,
                isEnabled: true, isHittable: index > 0, containingAlertIdentifier: "alert:Access",
                containingAlertContext: context, originBundleIdentifier: "com.apple.springboard")
        }
        let driver = RecoveryDriver(elements)
        let (report, _) = await run(driver, policy: RecoveryPolicy())
        XCTAssertEqual(report.outcome, .needsReview)
        let actions = await driver.actions
        XCTAssertTrue(actions.isEmpty)
    }
    func testUnfamiliarSystemPromptUsesUniqueNonDenialButton() {
        let context = "Trust this computer?\nCancel\nTrust"
        let elements = ["Trust this computer?", "Cancel", "Trust"].enumerated().map { index, label in
            UIElement(identifier: nil, role: index == 0 ? "alert" : "button", label: label, value: nil, frame: nil,
                isEnabled: true, isHittable: index > 0, containingAlertIdentifier: "alert:Trust",
                containingAlertContext: context, originBundleIdentifier: "com.apple.springboard")
        }
        let observation = InterruptionLibrary.recognize(.init(captureID: .init(), elements: elements))
        XCTAssertEqual(InterruptionLibrary.systemPromptChoice(observation)?.label, "Trust")
    }
    func testGenericExactPolicyAndFreshVerification() async {
        let driver = RecoveryDriver([alertElement("later", "Not Now"), alertElement("enable", "Enable")])
        let (report, events) = await run(driver, policy: automatic)
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions; XCTAssertEqual(actions.count, 2)
        let verified = events.compactMap { if case .recovery(let evidence) = $0, evidence.status == .verified { return evidence }; return nil }
        XCTAssertEqual(verified.count, 1)
        XCTAssertNotEqual(verified.first?.captureID, verified.first?.verificationCaptureID)
        XCTAssertEqual(verified.first?.choice?.confidence, 1)
    }
    func testAlteredContextCannotBorrowLegitimatePolicyPhrases() async {
        let modified = contextText + "\nThis action deletes everything"
        let driver = RecoveryDriver([alertElement("later", "Not Now", context: modified), alertElement("enable", "Enable", context: modified)])
        let (report, _) = await run(driver, policy: automatic)
        XCTAssertEqual(report.outcome, .needsReview)
        let actions = await driver.actions; XCTAssertTrue(actions.isEmpty)
    }
    func testSafeInferredRejectsTwoReviewedNonDestructiveChoices() async {
        let policy = reviewed(buttons: [.init(identifier: "later", label: "Not Now", risk: .nonDestructiveDismissal), .init(identifier: "enable", label: "Enable", risk: .nonDestructiveDismissal)])
        let driver = RecoveryDriver([alertElement("later", "Not Now"), alertElement("enable", "Enable")])
        let (report, _) = await run(driver, policy: .init(maximumActions: 2, knownInterruptionPolicies: ["optional"], mode: .safeInferred), reviewedPolicies: [policy])
        XCTAssertEqual(report.outcome, .needsReview)
        let actions = await driver.actions; XCTAssertTrue(actions.isEmpty)
    }
    func testExpectedPromptAllowsExplicitAuthoredDismissal() async {
        let driver = RecoveryDriver([alertElement("later", "Not Now"), alertElement("enable", "Enable")])
        let blocks: [TestBlock] = [.init(title: "Expected", action: .assertion(.exists(.identifier("later")))), .init(title: "Authored dismissal", action: .tap(targets: [.identifier("later")]))]
        let (report, events) = await run(driver, policy: automatic, blocks: blocks)
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions; XCTAssertEqual(actions, [.tap(identifier: "later")])
        XCTAssertFalse(events.contains { if case .recovery(let evidence) = $0 { return evidence.status == .dispatched }; return false })
    }
    func testNoProgressCannotRetryMutation() async {
        let driver = RecoveryDriver([alertElement("later", "Not Now"), alertElement("enable", "Enable")], noProgress: true)
        let blocks: [TestBlock] = [.init(title: "Target", action: .tap(targets: [.identifier("target")]), retryPolicy: .init(maximumAttempts: 3))]
        let (report, events) = await run(driver, policy: automatic, blocks: blocks)
        XCTAssertEqual(report.outcome, .needsReview)
        let actions = await driver.actions; XCTAssertEqual(actions.count, 1)
        for case .recovery(let evidence) in events { XCTAssertTrue(evidence.candidates.allSatisfy { $0.captureID == evidence.captureID }) }
    }
    func testVerifiedPromptStartsFreshRecoveryWindowWithoutResettingActionCount() async {
        let budget = RecoveryBudget()
        let firstPrompt = Date(timeIntervalSince1970: 1_000)
        let firstStart = await budget.begin(now: firstPrompt)
        XCTAssertEqual(firstStart, firstPrompt)
        await budget.consumeAction()

        await budget.finishInterruption()
        let secondPrompt = firstPrompt.addingTimeInterval(40)
        let secondStart = await budget.begin(now: secondPrompt)
        let actionCount = await budget.actionCount
        XCTAssertEqual(secondStart, secondPrompt)
        XCTAssertEqual(actionCount, 1)
    }
    func testRecoveryBudgetSurvivesBlocksAndRetryStructure() async {
        let driver = RecoveryDriver([alertElement("later", "Not Now"), alertElement("enable", "Enable")], reintroduceAfterTarget: true)
        let blocks = [TestBlock(title: "First target", action: .tap(targets: [.identifier("target")])),
                      TestBlock(title: "Second target", action: .tap(targets: [.identifier("target")]), retryPolicy: .init(maximumAttempts: 3))]
        let (report, events) = await run(driver, policy: automatic.replacing(maximumActions: 1), blocks: blocks)
        XCTAssertEqual(report.outcome, .needsReview)
        let actions = await driver.actions
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions.filter { if case .recoveryTap = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(events.contains { if case .recovery(let evidence) = $0 { return evidence.status == .refused && evidence.reason.contains("budget exhausted") && evidence.actionCount == 1 }; return false })
        XCTAssertEqual(events.filter { if case .attempt = $0 { return true }; return false }.count, 2)
    }
    func testDisabledExpectedAssertionDoesNotSuppressRecovery() async {
        let driver = RecoveryDriver([alertElement("later", "Not Now"), alertElement("enable", "Enable")])
        let blocks: [TestBlock] = [.init(title: "Disabled expected prompt", action: .assertion(.exists(.identifier("later"))), enabled: false), .init(title: "Target", action: .tap(targets: [.identifier("target")]))]
        let (report, events) = await run(driver, policy: automatic, blocks: blocks)
        XCTAssertEqual(report.outcome, .passed)
        XCTAssertTrue(events.contains { if case .recovery(let evidence) = $0 { return evidence.status == .verified }; return false })
    }
    func testExpectedOfflineAllowsAuthoredTargetAndUnresolvedStillReviews() async {
        let elements: [UIElement] = [.init(identifier: nil, role: "staticText", label: "No internet connection", value: nil, frame: nil), .init(identifier: "target", role: "button", label: "Target", value: nil, frame: nil, isEnabled: true, isHittable: true)]
        for target in ["target", "missing"] {
            let driver = RecoveryDriver(elements)
            let blocks: [TestBlock] = [.init(title: "Expected offline", action: .assertion(.textVisible("No internet connection"))), .init(title: "Authored target", action: .tap(targets: [.identifier(target)]))]
            let (report, _) = await run(driver, policy: automatic, blocks: blocks)
            XCTAssertEqual(report.outcome, target == "target" ? .passed : .needsReview)
            let actions = await driver.actions; XCTAssertEqual(actions.count, target == "target" ? 1 : 0)
        }
    }
    func testRecoverySettingsEditsPreserveSafetyAndExplicitOverride() {
        let configured = RecoveryPolicy(maximumActions: 2, allowTextFallback: true, knownInterruptionPolicies: ["optional"], mode: .safeInferred)
        let edited = configured.replacing(maximumActions: 3)
        XCTAssertEqual(edited.mode, .safeInferred); XCTAssertTrue(edited.allowTextFallback); XCTAssertEqual(edited.knownInterruptionPolicies, ["optional"])
        let test = ProjectDomain.TestCase(name: "Inherited", blocks: [], useProjectRecoveryPolicy: true)
        XCTAssertEqual(test.replacing(recoveryPolicy: configured).useProjectRecoveryPolicy, false)
    }
    func testMissingApplicationNodeIsNotCrashEvidence() {
        XCTAssertEqual(InterruptionLibrary.recognize(.init(captureID: .init(), elements: [])).kind, .none)
    }
    func testLibrarySignalsAndNoUnsafeInference() {
        let cases: [(UIElement, InterruptionKind)] = [
            (.init(identifier: nil, role: "keyboard", label: nil, value: nil, frame: nil), .keyboard),
            (.init(identifier: nil, role: "sheet", label: nil, value: nil, frame: nil), .firstRunSheet),
            (.init(identifier: nil, role: "activityIndicator", label: nil, value: nil, frame: nil), .transient),
            (.init(identifier: nil, role: "staticText", label: "No internet connection", value: nil, frame: nil), .offline),
            (.init(identifier: nil, role: "staticText", label: "Session expired", value: nil, frame: nil), .authenticationExpired),
            (.init(identifier: "com.apple.springboard", role: "application", label: "SpringBoard", value: nil, frame: nil), .applicationUnavailable)
        ]
        for (element, kind) in cases { XCTAssertEqual(InterruptionLibrary.recognize(.init(captureID: .init(), elements: [element])).kind, kind) }
    }
}

private actor ProbeChooser: CandidateChoosing {
    var calls = 0
    let confidence: Double
    let wrong: Bool
    let metadata: String
    init(confidence: Double = 1, wrong: Bool = false, metadata: String = "valid") { self.confidence = confidence; self.wrong = wrong; self.metadata = metadata }
    func choose(from candidates: [ActionCandidate], context: String) async throws -> CandidateChoice {
        calls += 1
        let selected = candidates.first(where: \.isSafeForAutomaticExecution)!
        let evidence = CandidateDecisionEvidence(requestID: UUID(), captureID: selected.captureID, optionIDs: [selected.id.uuidString, "abstain"], selectedID: selected.id.uuidString, probabilities: metadata == "malformed" ? [selected.id.uuidString: 0.4] : metadata == "tied" ? [selected.id.uuidString: 0.5, "abstain": 0.5] : [selected.id.uuidString: 1, "abstain": 0], confidence: confidence, reason: "Mock structurally valid selection", accepted: true, responseCaptureID: metadata == "contradictory" ? CaptureID() : nil)
        return .init(candidateID: wrong ? UUID() : selected.id, captureID: selected.captureID, confidence: confidence, providerEvidence: metadata == "missing" ? nil : evidence)
    }
}
extension RecoveryTests {
    func testEscapePolicyDefaultsOnAndPreservesExplicitOff() throws {
        let policy = RecoveryPolicy()
        XCTAssertTrue(policy.allowSafeEscapes); XCTAssertTrue(policy.allowProgressControls)
        XCTAssertEqual(policy.maximumEscapes, 2); XCTAssertEqual(policy.maximumUnresolvedSteps, 2)
        let legacy = Data("{\"maximumActions\":0,\"timeoutSeconds\":10,\"minimumConfidence\":0.9,\"mode\":\"askFail\"}".utf8)
        let decoded = try JSONDecoder().decode(RecoveryPolicy.self, from: legacy)
        XCTAssertTrue(decoded.allowSafeEscapes); XCTAssertTrue(decoded.allowProgressControls)
        XCTAssertEqual(decoded.maximumEscapes, 2); XCTAssertEqual(decoded.maximumUnresolvedSteps, 2)
        let explicit = try JSONDecoder().decode(RecoveryPolicy.self, from: JSONEncoder().encode(RecoveryPolicy(allowSafeEscapes: false, allowProgressControls: false, maximumEscapes: 0, maximumUnresolvedSteps: 0)))
        XCTAssertFalse(explicit.allowSafeEscapes); XCTAssertFalse(explicit.allowProgressControls)
        XCTAssertEqual(explicit.maximumEscapes, 0); XCTAssertEqual(explicit.maximumUnresolvedSteps, 0)
    }
    func testCandidateProviderDefaultsToJevIncludingLegacyDecode() throws {
        XCTAssertEqual(RecoveryPolicy().candidateProvider, .jev)
        let legacy = Data("{\"maximumActions\":2,\"timeoutSeconds\":10,\"minimumConfidence\":0.9,\"mode\":\"knownAutomatic\"}".utf8)
        let decoded = try JSONDecoder().decode(RecoveryPolicy.self, from: legacy)
        XCTAssertEqual(decoded.candidateProvider, .jev)
        let explicit = try JSONDecoder().decode(RecoveryPolicy.self, from: JSONEncoder().encode(RecoveryPolicy(candidateProvider: .local)))
        XCTAssertEqual(explicit.candidateProvider, .local)
    }
    func testSystemPromptAcceptanceDefaultsOnIncludingLegacyDecode() throws {
        XCTAssertTrue(RecoveryPolicy().allowSystemDismiss)
        let legacy = Data("{\"maximumActions\":0,\"timeoutSeconds\":10,\"minimumConfidence\":0.9,\"mode\":\"askFail\"}".utf8)
        XCTAssertTrue(try JSONDecoder().decode(RecoveryPolicy.self, from: legacy).allowSystemDismiss)
    }
    func testLocalPolicyNeverConsultsHostedChooser() async {
        for mode in [RecoveryMode.askFail, .knownAutomatic] {
            let chooser = ProbeChooser()
            let driver = RecoveryDriver([alertElement("later", "Not Now"), alertElement("enable", "Enable")])
            let (_, _) = await run(driver, policy: automatic.replacing(mode: mode), chooser: chooser)
            let calls = await chooser.calls; XCTAssertEqual(calls, 0)
        }
    }
    func testUnavailableOrInvalidChooserFallsBackToLocalReviewedChoice() async {
        for chooser in [ProbeChooser(confidence: 0.1), ProbeChooser(confidence: -0.1), ProbeChooser(confidence: 2), ProbeChooser(wrong: true), ProbeChooser(metadata: "missing"), ProbeChooser(metadata: "malformed"), ProbeChooser(metadata: "tied"), ProbeChooser(metadata: "contradictory")] {
            let driver = RecoveryDriver([alertElement("later", "Not Now"), alertElement("enable", "Enable")])
            let (report, evidenceEvents) = await run(driver, policy: automatic.replacing(candidateProvider: .jev), chooser: chooser)
            let decisions = evidenceEvents.compactMap { if case .candidateDecision(let d) = $0 { return d }; return nil }
            XCTAssertEqual(decisions.count, 1)
            if !(0...1).contains(chooser.confidence) || ["missing", "malformed", "tied", "contradictory"].contains(chooser.metadata) { XCTAssertEqual(decisions.first?.accepted, false) }
            XCTAssertTrue(evidenceEvents.contains { if case .providerFallback(let value) = $0 { return value.fallback == "local.reviewed-policy" && !value.reason.isEmpty }; return false })
            XCTAssertEqual(report.outcome, .passed)
            let actions = await driver.actions
            XCTAssertEqual(actions.count, 2)
            if case .recoveryTap(_, let element) = actions[0] { XCTAssertEqual(element.label, "Not Now") } else { XCTFail("Expected local reviewed dismissal") }
        }
        let driver = RecoveryDriver([alertElement("later", "Not Now"), alertElement("enable", "Enable")])
        let (report, events) = await run(driver, policy: automatic.replacing(candidateProvider: .jev))
        XCTAssertTrue(events.contains { if case .providerFallback(let value) = $0 { return value.reason.contains("chooser is not configured") }; return false })
        XCTAssertEqual(report.outcome, .passed)
    }
    func testValidChooserStillGovernsSelection() async {
        let driver = RecoveryDriver([alertElement("later", "Not Now"), alertElement("enable", "Enable")])
        let (report, events) = await run(driver, policy: automatic.replacing(candidateProvider: .jev), chooser: ProbeChooser())
        XCTAssertEqual(report.outcome, .passed)
        XCTAssertTrue(events.contains { if case .recovery(let e) = $0 { return e.status == .verified }; return false })
        XCTAssertFalse(events.contains { if case .providerFallback = $0 { return true }; return false })
    }
}
