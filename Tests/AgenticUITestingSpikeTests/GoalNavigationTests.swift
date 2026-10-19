import XCTest
import ProjectDomain
@testable import RunnerCore

private actor NavigationDriver: RunnerDriving {
    private var screen = 0
    private let welcomeTitle: String
    private var staleActionsRemaining: Int
    private let mappedStale: Bool
    private(set) var actions: [String] = []
    init(staleActionsRemaining: Int = 0, mappedStale: Bool = false, welcomeTitle: String = "Welcome") {
        self.staleActionsRemaining = staleActionsRemaining
        self.mappedStale = mappedStale
        self.welcomeTitle = welcomeTitle
    }
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot {
        let labels: [[String]] = [
            [welcomeTitle, "Get Started"],
            ["Premium plan", "Start Free Trial", "Not Now"],
            ["Meditations", "Start meditation"],
            ["Meditation playing", "Pause"]
        ]
        let elements = labels[screen].map { label in
            UIElement(identifier: label, role: label == "Welcome" || label == "Premium plan" || label == "Meditations" || label == "Meditation playing" ? "staticText" : "button", label: label, value: nil, frame: nil, isEnabled: true, isHittable: true)
        }
        return .init(captureID: .init(), elements: elements)
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws {
        guard case .tapElement(let element) = action, let label = element.label else { throw DriverFailure.notDispatched("unexpected action") }
        if staleActionsRemaining > 0 {
            staleActionsRemaining -= 1
            if mappedStale { throw DriverFailure.unavailable("staleCapture") }
            throw CompanionFailure.staleCapture
        }
        actions.append(label)
        if ["Get Started", "Not Now", "Start meditation"].contains(label) { screen += 1 }
    }
    func stop() async {}
}

private actor DeclarationDriver: RunnerDriving {
    private var checked = false
    private var accepted = false
    private let transitionsAfterAccept: Bool
    private(set) var actions: [String] = []
    init(transitionsAfterAccept: Bool = true) { self.transitionsAfterAccept = transitionsAfterAccept }
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot {
        if accepted {
            return .init(captureID: .init(), elements: [
                UIElement(identifier: nil, role: "staticText", label: "Meditation playing", value: nil,
                    frame: nil, originBundleIdentifier: "dev.fixture")
            ])
        }
        return .init(captureID: .init(), elements: [
            UIElement(identifier: nil, role: "staticText",
                label: "I confirm I have none of the listed conditions. I accept full responsibility for using this app.",
                value: nil, frame: nil, originBundleIdentifier: "dev.fixture"),
            UIElement(identifier: nil, role: "switch", label: nil, value: checked ? "1" : "0",
                frame: .init(x: 20, y: 400, width: 50, height: 30), isEnabled: true, isHittable: true,
                originBundleIdentifier: "dev.fixture"),
            UIElement(identifier: nil, role: "button", label: "Accept & Continue", value: nil,
                frame: .init(x: 100, y: 500, width: 200, height: 50), isEnabled: checked,
                isHittable: checked, originBundleIdentifier: "dev.fixture")
        ])
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws {
        guard case .tapElement(let element) = action else { throw DriverFailure.notDispatched("unexpected declaration action") }
        if element.role == "switch", !checked { checked = true; actions.append("checkbox"); return }
        if element.label == "Accept & Continue", checked {
            accepted = transitionsAfterAccept
            actions.append("accept")
            return
        }
        throw DriverFailure.notDispatched("unexpected declaration target")
    }
    func stop() async {}
}

private actor ExplorationDriver: RunnerDriving {
    private var screen = 0
    private(set) var actions: [String] = []
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot {
        var elements = [UIElement(identifier: nil, role: "application", label: "Fixture", value: nil,
            frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture")]
        let label = screen == 2 ? "Meditation playing" : "Meditations"
        elements.append(UIElement(identifier: label, role: "staticText", label: label, value: nil,
            frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture"))
        if screen == 1 {
            elements.append(UIElement(identifier: "Start meditation", role: "button", label: "Start meditation",
                value: nil, frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture"))
        }
        return .init(captureID: .init(), elements: elements)
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws {
        switch action {
        case .swipe(.up, identifier: nil): actions.append("up"); screen = 1
        case .tapElement(let element) where element.label == "Start meditation":
            actions.append("Start meditation"); screen = 2
        default: throw DriverFailure.notDispatched("unexpected exploration action")
        }
    }
    func stop() async {}
}

private actor StationarySwipeDriver: RunnerDriving {
    private(set) var directions: [SwipeDirection] = []
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot {
        .init(captureID: .init(), elements: [
            UIElement(identifier: nil, role: "application", label: "Fixture", value: nil,
                frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture"),
            UIElement(identifier: nil, role: "staticText", label: "Meditations", value: nil,
                frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture")
        ])
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws {
        guard case .swipe(let direction, identifier: nil) = action else {
            throw DriverFailure.notDispatched("unexpected action")
        }
        directions.append(direction)
    }
    func stop() async {}
}

private actor OCRPaywallDriver: RunnerDriving {
    private var opened = false
    private var snapshots: [CaptureID: UISnapshot] = [:]
    private(set) var tapCount = 0
    private(set) var accurateCalls = 0
    private let incidentalAccessibilityControl: Bool
    private let fastMisses: Bool
    init(incidentalAccessibilityControl: Bool = false, fastMisses: Bool = false) {
        self.incidentalAccessibilityControl = incidentalAccessibilityControl
        self.fastMisses = fastMisses
    }
    func prepare(project: TestProject, deadline: Date) async throws {}
    func warmupPerception(deadline: Date) async throws -> PerceptionWarmup {
        .init(startedAt: Date(), completedAt: Date(), milliseconds: 0)
    }
    func capture(deadline: Date) async throws -> UISnapshot {
        let elements = [
            UIElement(identifier: nil, role: "application", label: "Fixture", value: nil,
                frame: .init(x: 0, y: 0, width: 400, height: 800), isEnabled: true,
                originBundleIdentifier: "dev.fixture"),
            UIElement(identifier: nil, role: opened ? "staticText" : "other", label: opened ? "Subscription required" : nil,
                value: nil, frame: .init(x: 30, y: 160, width: 300, height: 90), isEnabled: true,
                originBundleIdentifier: "dev.fixture")
        ] + (incidentalAccessibilityControl && !opened ? [
            UIElement(identifier: "profile", role: "button", label: "Profile", value: nil,
                frame: .init(x: 320, y: 740, width: 60, height: 40), isEnabled: true,
                isHittable: true, originBundleIdentifier: "dev.fixture")
        ] : [])
        let snapshot = UISnapshot(captureID: .init(), elements: elements)
        snapshots[snapshot.captureID] = snapshot
        return snapshot
    }
    func provenance(for id: CaptureID) async -> CompanionCapture? {
        guard let snapshot = snapshots[id] else { return nil }
        return CompanionCapture(snapshot: snapshot, screenshotName: "screen.png", pixelWidth: 400,
            pixelHeight: 800, screenFrame: .init(x: 0, y: 0, width: 400, height: 800))
    }
    func recognizeText(for id: CaptureID, deadline: Date) async throws -> TextPerception {
        accurateCalls += 1
        guard let snapshot = snapshots[id] else { throw DriverFailure.unavailable("Missing capture") }
        let started = Date()
        return TextPerception(captureID: id, geometry: .init(pixels: .init(width: 400, height: 800),
            screenFrame: .init(x: 0, y: 0, width: 400, height: 800)), screenshotStartedAt: snapshot.capturedAt,
            recognitionStartedAt: started, recognitionCompletedAt: Date(), recognitionMilliseconds: 1,
            provider: "test.ocr", imageSHA256: String(repeating: "a", count: 64),
            regions: [.init(text: opened ? "Subscription required" : "Create scenario", confidence: 0.96,
                pixelBox: .init(x: 45, y: 180, width: 130, height: 30))])
    }
    func recognizeTextFast(for id: CaptureID, deadline: Date) async throws -> TextPerception {
        guard fastMisses else { return try await recognizeText(for: id, deadline: deadline) }
        guard let snapshot = snapshots[id] else { throw DriverFailure.unavailable("Missing capture") }
        let started = Date()
        return TextPerception(captureID: id, geometry: .init(pixels: .init(width: 400, height: 800),
            screenFrame: .init(x: 0, y: 0, width: 400, height: 800)), screenshotStartedAt: snapshot.capturedAt,
            recognitionStartedAt: started, recognitionCompletedAt: Date(), recognitionMilliseconds: 1,
            provider: "test.fast-miss", imageSHA256: String(repeating: "a", count: 64), regions: [])
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws {
        guard case .visualTextTap(_, _, let text, _, _, _) = action, text == "Create scenario" else {
            throw DriverFailure.notDispatched("Expected OCR tap on Create scenario")
        }
        tapCount += 1
        opened = true
    }
    func stop() async {}
}

private struct OCRPaywallChooser: GoalNavigating {
    func decide(_ request: GoalNavigationRequest) async throws -> GoalNavigationDecision {
        if request.screen.contains(where: { $0.text.contains("Subscription required") }) {
            return .init(captureID: request.captureID, kind: .complete, confidence: 1,
                reason: "Paywall is visible")
        }
        let target = request.candidates.first { $0.isOCR && $0.label == "Create scenario" }
        return .init(captureID: request.captureID, kind: target == nil ? .blocked : .act,
            candidateID: target?.id, confidence: 1, reason: "Tap the visible premium control")
    }
}

private struct BlockedBeforePaywallChooser: GoalNavigating {
    func decide(_ request: GoalNavigationRequest) async throws -> GoalNavigationDecision {
        .init(captureID: request.captureID,
              kind: request.screen.contains(where: { $0.text.contains("Subscription required") }) ? .complete : .blocked,
              confidence: 1, reason: "Assess visible result")
    }
}

private struct OCRPaywallEvaluator: AssertionEvaluating {
    var providerID: String { "test.paywall-evaluator" }
    func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment {
        let proof = request.evidence.filter { $0.text.contains("Subscription required") }
        return .init(requestID: request.requestID, captureID: request.captureID,
            verdict: proof.isEmpty ? .insufficient : .satisfied, confidence: 1,
            evidenceIDs: proof.map(\.id), reason: proof.isEmpty ? "Paywall not visible" : "Paywall visible")
    }
}

private struct NavigationChooser: GoalNavigating {
    func decide(_ request: GoalNavigationRequest) async throws -> GoalNavigationDecision {
        if request.screen.contains(where: { $0.text.contains("Meditation playing") }) {
            return .init(captureID: request.captureID, kind: .complete, confidence: 1, reason: "Playing state is visible")
        }
        let wanted = request.candidates.first { ["Get Started", "Not Now", "Start meditation"].contains($0.label) }
        return .init(captureID: request.captureID, kind: wanted == nil ? .blocked : .act, candidateID: wanted?.id, confidence: 1, reason: "Advance toward meditation")
    }
}

private actor CountingNavigationChooser: GoalNavigating {
    private(set) var calls = 0
    func decide(_ request: GoalNavigationRequest) async throws -> GoalNavigationDecision {
        calls += 1
        return try await NavigationChooser().decide(request)
    }
}

private struct BlockedNavigationChooser: GoalNavigating {
    func decide(_ request: GoalNavigationRequest) async throws -> GoalNavigationDecision {
        if request.screen.contains(where: { $0.text.contains("Meditation playing") }) {
            return .init(captureID: request.captureID, kind: .complete, confidence: 1, reason: "Playing state is visible")
        }
        if let wanted = request.candidates.first(where: { ["Not Now", "Start meditation"].contains($0.label) }) {
            return .init(captureID: request.captureID, kind: .act, candidateID: wanted.id, confidence: 1, reason: "Advance toward meditation")
        }
        return .init(captureID: request.captureID, kind: .blocked, confidence: 1, reason: "No model choice")
    }
}

private actor LoginDriver: RunnerDriving {
    private var signedIn = false
    private let advances: Bool
    private let opensSheet: Bool
    private let requireFreshAction: Bool
    private let sheetDelayCaptures: Int
    private let requiresPassword: Bool
    private let unavailablePasswordField: Bool
    private let unverifiedPasswordInput: Bool
    private var sheetOpen = false
    private var passwordPrompt = false
    private let returningAccount: Bool
    private var passwordTransitionCapturesRemaining: Int
    private var pendingSheetCaptures = 0
    private var hideEmailSelected = false
    private var fingerprints: [CaptureID: String] = [:]
    private var snapshots: [CaptureID: UISnapshot] = [:]
    private var lastCaptureAt = Date.distantPast
    private(set) var captureCount = 0
    private(set) var actions: [String] = []
    init(advances: Bool = true, opensSheet: Bool = false, requireFreshAction: Bool = false, sheetDelayCaptures: Int = 0, requiresPassword: Bool = false, unavailablePasswordField: Bool = false, unverifiedPasswordInput: Bool = false, returningAccount: Bool = false, passwordTransitionCaptures: Int = 0) {
        self.advances = advances; self.opensSheet = opensSheet; self.requireFreshAction = requireFreshAction
        self.sheetDelayCaptures = sheetDelayCaptures; self.requiresPassword = requiresPassword
        self.unavailablePasswordField = unavailablePasswordField
        self.unverifiedPasswordInput = unverifiedPasswordInput
        self.returningAccount = returningAccount
        self.passwordTransitionCapturesRemaining = passwordTransitionCaptures
    }
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot {
        if pendingSheetCaptures > 0 {
            pendingSheetCaptures -= 1
            if pendingSheetCaptures == 0 { sheetOpen = true }
        }
        let labels = signedIn ? ["Meditation playing", "Pause"] :
            ["Example App", "Welcome to the example app", "Sign in with Apple", "By continuing you agree to the following", "Terms & Conditions", "Privacy Policy"]
        let elements = labels.map { label in
            UIElement(identifier: nil, role: ["Sign in with Apple", "Terms & Conditions", "Privacy Policy", "Pause"].contains(label) ? "button" : "staticText",
                label: label, value: nil, frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture")
        }
        let id = CaptureID()
        captureCount += 1
        lastCaptureAt = Date()
        fingerprints[id] = passwordPrompt ? "apple-password" : sheetOpen ? "apple-sheet" : signedIn ? "meditation" : "login"
        let snapshot = UISnapshot(captureID: id, elements: elements)
        snapshots[id] = snapshot
        return snapshot
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws {
        if case .secureTextTap(_, _, _, let secret) = action {
            if unavailablePasswordField { throw DriverFailure.secureInputUnavailable(secret) }
            if unverifiedPasswordInput { throw DriverFailure.secureInputUnverified(secret) }
            throw DriverFailure.missingSecret(secret)
        }
        if case .textTap(_, _, let text, _, _) = action {
            actions.append(text)
            if text == "Sign In with Password" && returningAccount {
                sheetOpen = false
                passwordPrompt = true
            }
            if text == "Hide My Email" { hideEmailSelected = true }
            if text == "Continue with Password" && hideEmailSelected {
                sheetOpen = false
                if requiresPassword { passwordPrompt = true }
                else { signedIn = true }
            }
            return
        }
        if requireFreshAction && Date().timeIntervalSince(lastCaptureAt) > 2 {
            throw DriverFailure.notDispatched("staleCapture")
        }
        guard case .tapElement(let element) = action, let label = element.label else { throw DriverFailure.notDispatched("unexpected action") }
        actions.append(label)
        if label == "Sign in with Apple" && advances { signedIn = true }
        if label == "Sign in with Apple" && opensSheet {
            if sheetDelayCaptures > 0 { pendingSheetCaptures = sheetDelayCaptures }
            else { sheetOpen = true }
        }
    }
    func imageFingerprint(for id: CaptureID) async -> String? { fingerprints[id] }
    func provenance(for id: CaptureID) async -> CompanionCapture? {
        guard let snapshot = snapshots[id] else { return nil }
        return CompanionCapture(snapshot: snapshot, screenshotName: "test.png", pixelWidth: 100,
            pixelHeight: 100, screenFrame: .init(x: 0, y: 0, width: 100, height: 100))
    }
    func recognizeText(for id: CaptureID, deadline: Date) async throws -> TextPerception {
        let unsettledPassword = passwordPrompt && passwordTransitionCapturesRemaining > 0
        if unsettledPassword { passwordTransitionCapturesRemaining -= 1 }
        let lines = passwordPrompt ? ["Apple Account", "Enter the password for Apple Account fixture@example.invalid to continue", "Password", "Sign In"] :
            sheetOpen ? (returningAccount
                ? ["Sign in with Apple", "Sign in to Example App using your Apple Account.", "Your account", "Sign In with Password"]
                : ["Sign in with Apple", "Create an account for Example App", "Share My Email", "Hide My Email", "Continue with Password"]) : []
        let capturedAt = snapshots[id]?.capturedAt ?? Date()
        let startedAt = Date()
        return TextPerception(captureID: id, geometry: .init(pixels: .init(width: 100, height: 100),
            screenFrame: .init(x: 0, y: 0, width: 100, height: 100)), screenshotStartedAt: capturedAt,
            recognitionStartedAt: startedAt, recognitionCompletedAt: Date(), recognitionMilliseconds: 1,
            provider: "test.ocr", imageSHA256: String(repeating: "a", count: 64),
            regions: (unsettledPassword ? [] : lines).enumerated().map { index, text in
                .init(text: text, confidence: 0.95, pixelBox: .init(x: 0, y: Double(index) * 10, width: 90, height: 8))
            })
    }
    func completeSignIn() { sheetOpen = false; signedIn = true }
    func stop() async {}
}

private struct SlowLoginChooser: GoalNavigating {
    func decide(_ request: GoalNavigationRequest) async throws -> GoalNavigationDecision {
        if request.screen.contains(where: { $0.text.contains("Meditation playing") }) {
            return .init(captureID: request.captureID, kind: .complete, confidence: 1, reason: "Playing state is visible")
        }
        try await Task.sleep(for: .seconds(5.2))
        return .init(captureID: request.captureID, kind: .act,
            candidateID: request.candidates.first { $0.label == "Sign in with Apple" }?.id,
            confidence: 1, reason: "Continue onboarding")
    }
}

private struct MismatchedLoginChooser: GoalNavigating {
    func decide(_ request: GoalNavigationRequest) async throws -> GoalNavigationDecision {
        if request.screen.contains(where: { $0.text.contains("Meditation playing") }) {
            return .init(captureID: request.captureID, kind: .complete, confidence: 1, reason: "Playing state is visible")
        }
        return .init(captureID: request.captureID, kind: .act, candidateID: "Sign in with Apple", confidence: 0.7,
            reason: "Sign in with Apple advances onboarding")
    }
}

private struct NavigationEvaluator: AssertionEvaluating {
    var providerID: String { "test.evaluator" }
    func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment {
        .init(requestID: request.requestID, captureID: request.captureID, verdict: .satisfied, confidence: 1,
              evidenceIDs: request.evidence.filter { $0.text.contains("Meditation playing") }.map(\.id), reason: "Playing state is visible")
    }
}

private struct InsufficientNavigationEvaluator: AssertionEvaluating {
    var providerID: String { "test.insufficient-evaluator" }
    func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment {
        .init(requestID: request.requestID, captureID: request.captureID, verdict: .insufficient,
            confidence: 1, evidenceIDs: [], reason: "Goal not established")
    }
}

private struct CriteriaEvaluator: AssertionEvaluating {
    var providerID: String { "test.criteria-evaluator" }
    func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment {
        let proved = request.successCriteria == "Meditation playing is visible" &&
            request.evidence.contains { $0.text.contains("Meditation playing") }
        return .init(requestID: request.requestID, captureID: request.captureID,
            verdict: proved ? .satisfied : .insufficient, confidence: 1,
            evidenceIDs: proved ? request.evidence.filter { $0.text.contains("Meditation playing") }.map(\.id) : [],
            reason: proved ? "Requested finish state is visible" : "Finish state is unproven")
    }
}

private actor UnlabelledTabDriver: RunnerDriving {
    private var snapshots: [CaptureID: UISnapshot] = [:]
    private(set) var tappedPractice = false
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot {
        let bundle = "dev.fixture"
        let elements: [UIElement] = [
            .init(identifier: nil, role: "application", label: "Fixture", value: nil,
                  frame: .init(x: 0, y: 0, width: 402, height: 874), isEnabled: true,
                  originBundleIdentifier: bundle),
            .init(identifier: "ladybug.fill", role: "button", label: "ladybug.fill", value: nil,
                  frame: .init(x: 358, y: 70, width: 40, height: 40), isEnabled: true,
                  isHittable: true, originBundleIdentifier: bundle)
        ] + ["waveform", "map", "running", "chart", "person"].enumerated().map { index, icon in
            UIElement(identifier: icon, role: "other", label: icon, value: nil,
                      frame: .init(x: Double(index) * 78 + 26, y: 800, width: 28, height: 28),
                      isEnabled: true, isHittable: true, originBundleIdentifier: bundle)
        }
        let snapshot = UISnapshot(captureID: .init(), elements: elements)
        snapshots[snapshot.captureID] = snapshot
        return snapshot
    }
    func provenance(for id: CaptureID) async -> CompanionCapture? {
        guard let snapshot = snapshots[id] else { return nil }
        return CompanionCapture(snapshot: snapshot, screenshotName: "tab.png", pixelWidth: 402,
            pixelHeight: 874, screenFrame: .init(x: 0, y: 0, width: 402, height: 874))
    }
    func recognizeText(for id: CaptureID, deadline: Date) async throws -> TextPerception {
        guard let snapshot = snapshots[id] else { throw DriverFailure.unavailable("Missing capture") }
        let started = Date()
        return TextPerception(captureID: id, geometry: .init(pixels: .init(width: 402, height: 874),
            screenFrame: .init(x: 0, y: 0, width: 402, height: 874)), screenshotStartedAt: snapshot.capturedAt,
            recognitionStartedAt: started, recognitionCompletedAt: Date(), recognitionMilliseconds: 1,
            provider: "test.ocr", imageSHA256: String(repeating: "a", count: 64),
            regions: [.init(text: "Practice", confidence: 0.95,
                            pixelBox: .init(x: 27, y: 835, width: 60, height: 20))])
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws {
        guard case .textTap(_, _, let text, _, _) = action, text == "practice" else {
            throw DriverFailure.notDispatched("Expected visible Practice tab tap")
        }
        tappedPractice = true
    }
    func stop() async {}
}

private struct TabEvidenceEvaluator: AssertionEvaluating {
    var providerID: String { "test.tab-evaluator" }
    func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment {
        let proof = request.evidence.filter { $0.id == "verified-tab-selection" }
        return .init(requestID: request.requestID, captureID: request.captureID,
            verdict: proof.count == 1 ? .satisfied : .insufficient, confidence: 1,
            evidenceIDs: proof.map(\.id), reason: "Practice was tapped and remains in the tab bar")
    }
}

private actor SavedInputDriver: RunnerDriving {
    private var entered = false
    private var complete = false
    private let uncertainContinue: Bool
    private var snapshots: [CaptureID: UISnapshot] = [:]
    private(set) var typedValues: [String] = []
    init(uncertainContinue: Bool = false) { self.uncertainContinue = uncertainContinue }
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot {
        let bundle = "dev.fixture"
        let elements: [UIElement] = [
            .init(identifier: nil, role: "application", label: "Fixture", value: nil,
                frame: .init(x: 0, y: 0, width: 402, height: 874), isEnabled: true,
                originBundleIdentifier: bundle),
            .init(identifier: nil, role: "staticText", label: complete ? "Onboarding complete" : "What's your name?", value: nil,
                frame: .init(x: 52, y: 605, width: 298, height: 30), isEnabled: true,
                originBundleIdentifier: bundle)
        ] + (complete ? [] : [
            .init(identifier: nil, role: "textField", label: "", value: entered ? "Saved answer" : nil,
                frame: .init(x: 48, y: entered ? 368 : 669, width: 306, height: 25), isEnabled: true,
                isHittable: true, originBundleIdentifier: bundle),
            .init(identifier: nil, role: "button", label: "Continue", value: nil,
                frame: .init(x: 133, y: entered ? 427 : 728, width: 136, height: 48), isEnabled: entered,
                isHittable: entered && uncertainContinue ? nil : entered, originBundleIdentifier: bundle)
        ]) + (entered && !complete ? [
            .init(identifier: nil, role: "keyboard", label: "", value: nil,
                frame: .init(x: 0, y: 583, width: 402, height: 291), isEnabled: true,
                originBundleIdentifier: bundle),
            .init(identifier: "shift", role: "button", label: "shift", value: nil,
                frame: .init(x: 5, y: 698, width: 51, height: 54), isEnabled: true,
                isHittable: true, originBundleIdentifier: bundle),
            .init(identifier: nil, role: "button", label: "continue", value: nil,
                frame: .init(x: 301, y: 752, width: 99, height: 54), isEnabled: true,
                isHittable: true, originBundleIdentifier: bundle),
            .init(identifier: nil, role: "button", label: "Emoji", value: nil,
                frame: .init(x: 8, y: 805, width: 68, height: 69), isEnabled: true,
                isHittable: true, originBundleIdentifier: bundle)
        ] : [])
        let snapshot = UISnapshot(captureID: .init(), elements: elements)
        snapshots[snapshot.captureID] = snapshot
        return snapshot
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws {
        switch action {
        case .typeTextElement(let value, let field) where field.role == "textField" && !entered:
            typedValues.append(value); entered = true
        case .tapElement(let button) where button.label == "Continue" && entered:
            complete = true
        default: throw DriverFailure.notDispatched("Unexpected input")
        }
    }
    func provenance(for id: CaptureID) async -> CompanionCapture? {
        guard let snapshot = snapshots[id] else { return nil }
        return CompanionCapture(snapshot: snapshot, screenshotName: "fixture.png", pixelWidth: 402,
            pixelHeight: 874, screenFrame: .init(x: 0, y: 0, width: 402, height: 874))
    }
    func recognizeText(for id: CaptureID, deadline: Date) async throws -> TextPerception {
        guard let snapshot = snapshots[id] else { throw DriverFailure.unavailable("Missing capture") }
        return TextPerception(captureID: id, geometry: .init(pixels: .init(width: 402, height: 874),
            screenFrame: .init(x: 0, y: 0, width: 402, height: 874)), screenshotStartedAt: snapshot.capturedAt,
            recognitionStartedAt: Date(), recognitionCompletedAt: Date(), recognitionMilliseconds: 1,
            provider: "test.ocr", imageSHA256: String(repeating: "a", count: 64), regions: [
                .init(text: "Continue", confidence: 0.95, pixelBox: .init(x: 150, y: 435, width: 102, height: 28)),
                .init(text: "continue", confidence: 0.95, pixelBox: .init(x: 320, y: 760, width: 64, height: 28))
            ])
    }
    func stop() async {}
}

private struct SavedInputChooser: GoalNavigating {
    func decide(_ request: GoalNavigationRequest) async throws -> GoalNavigationDecision {
        if request.screen.contains(where: { $0.text.contains("Onboarding complete") }) {
            return .init(captureID: request.captureID, kind: .complete, confidence: 1, reason: "Onboarding complete is visible")
        }
        let button = request.candidates.first { $0.label == "Continue" }
        return .init(captureID: request.captureID, kind: button == nil ? .blocked : .act,
            candidateID: button?.id, confidence: 1, reason: "Continue onboarding")
    }
}

private struct SavedInputEvaluator: AssertionEvaluating {
    var providerID: String { "test.saved-input" }
    func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment {
        let evidence = request.evidence.filter { $0.text.contains("Onboarding complete") }
        return .init(requestID: request.requestID, captureID: request.captureID,
            verdict: evidence.isEmpty ? .insufficient : .satisfied, confidence: 1,
            evidenceIDs: evidence.map(\.id), reason: "Onboarding completion is visible")
    }
}

final class GoalNavigationTests: XCTestCase {
    func testVisibleTabOCRCompletesGoalBeforeExploringDebugControl() async {
        let test = TestCase(name: "Onboarding", goal: "Complete onboarding",
            successCriteria: "When the practice tab is active", executionMode: .goal, blocks: [])
        let project = TestProject(name: "Fixture", app: .init(projectPath: "App.xcodeproj",
            scheme: "App", bundleIdentifier: "dev.fixture"), simulator: .init(deviceID: "device"),
            categories: [.init(name: "General", suites: [.init(name: "Suite", tests: [test])])])
        let driver = UnlabelledTabDriver()
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: TabEvidenceEvaluator(),
            goalNavigator: BlockedNavigationChooser()).startGoal(project: project)
        for await _ in handle.events {}
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let tapped = await driver.tappedPractice
        XCTAssertTrue(tapped)
    }

    func testTabProbeRequiresExplicitActiveTabAndBottomBar() {
        XCTAssertEqual(GoalNavigationSafety.requestedActiveTab("When the practice tab is active"), "practice")
        XCTAssertNil(GoalNavigationSafety.requestedActiveTab("Open the practice tab"))
        XCTAssertTrue(GoalNavigationSafety.isDiagnosticControl("ladybug.fill"))
    }

    func testTabProbeRejectsOverlayAndTextOutsideTabBar() async throws {
        let driver = UnlabelledTabDriver()
        let snapshot = try await driver.capture(deadline: Date().addingTimeInterval(5))
        let perception = try await driver.recognizeText(for: snapshot.captureID,
            deadline: Date().addingTimeInterval(5))
        let capture = ScreenCapture(id: snapshot.captureID, createdAt: snapshot.capturedAt,
            pixelSize: .init(width: 402, height: 874), screenshotRelativePath: "captures/tab.png")
        XCTAssertTrue(GoalNavigationSafety.visibleTabText("practice", in: perception, capture: capture,
            snapshot: snapshot, appBundleID: "dev.fixture"))
        let topText = TextPerception(captureID: snapshot.captureID, geometry: perception.geometry,
            screenshotStartedAt: snapshot.capturedAt, recognitionStartedAt: perception.recognitionStartedAt,
            recognitionCompletedAt: perception.recognitionCompletedAt, recognitionMilliseconds: 1,
            provider: "test.ocr", imageSHA256: String(repeating: "a", count: 64),
            regions: [.init(text: "Practice", confidence: 0.95,
                            pixelBox: .init(x: 27, y: 250, width: 60, height: 20))])
        XCTAssertFalse(GoalNavigationSafety.visibleTabText("practice", in: topText, capture: capture,
            snapshot: snapshot, appBundleID: "dev.fixture"))
        let overlaid = UISnapshot(captureID: snapshot.captureID, elements: snapshot.elements + [
            .init(identifier: nil, role: "alert", label: "Permission", value: nil,
                  frame: .init(x: 60, y: 300, width: 280, height: 200), isEnabled: true,
                  originBundleIdentifier: "com.apple.springboard")
        ])
        XCTAssertFalse(GoalNavigationSafety.likelyTabBar(in: overlaid, appBundleID: "dev.fixture"))
    }

    func testGoalRunEntersSavedNameThenContinuesWithoutRecordingTypedAction() async throws {
        let test = TestCase(name: "Onboarding", goal: "Complete onboarding", executionMode: .goal, blocks: [])
        let project = TestProject(name: "Fixture", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "dev.fixture"),
            simulator: .init(deviceID: "device"), categories: [.init(name: "General", suites: [.init(name: "Suite", tests: [test])])])
        let driver = SavedInputDriver()
        let initial = try await driver.capture(deadline: Date().addingTimeInterval(60))
        XCTAssertNotNil(GoalNavigationSafety.savedInputTarget(in: initial,
            inputs: [.init(name: "Name", value: "Saved answer")], appBundleID: project.app.bundleIdentifier))
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: SavedInputEvaluator(),
            goalNavigator: SavedInputChooser(), savedInputs: [.init(name: "Name", value: "Saved answer")])
            .startGoal(project: project)
        var events: [ExecutionEvent] = []
        for await event in handle.events { events.append(event) }
        let outcome = await handle.task.value.outcome
        let typedValues = await driver.typedValues
        let diagnostics = events.compactMap { if case .diagnostic(let text) = $0 { return text }; return nil }
        XCTAssertEqual(outcome, .passed, diagnostics.joined(separator: " | "))
        XCTAssertEqual(typedValues, ["Saved answer"], diagnostics.joined(separator: " | "))
        XCTAssertFalse(events.contains { if case .action(_, .typeTextElement(_, _)) = $0 { return true }; return false })
    }
    func testEmptyNameFieldAndDisabledContinueAreRecognizedAsBlocker() async throws {
        let snapshot = try await SavedInputDriver().capture(deadline: Date().addingTimeInterval(5))
        XCTAssertTrue(GoalNavigationSafety.emptyFieldBlocksContinue(in: snapshot, appBundleID: "dev.fixture"))
        XCTAssertFalse(GoalNavigationSafety.emptyFieldBlocksContinue(in: snapshot, appBundleID: "another.app"))
        XCTAssertTrue(ProviderFailure.unavailable.localizedDescription.contains("Provider Settings"))
    }
    func testKeyboardButtonsRemainAvailableAndAppContinueIsIdentifiedSeparately() async throws {
        let driver = SavedInputDriver()
        let initial = try await driver.capture(deadline: Date().addingTimeInterval(60))
        try await driver.perform(.typeTextElement("Saved answer", initial.elements[2]), deadline: Date().addingTimeInterval(60))
        let withKeyboard = try await driver.capture(deadline: Date().addingTimeInterval(60))
        let candidates = GoalNavigationSafety.candidates(in: withKeyboard, appBundleID: "dev.fixture")
        XCTAssertEqual(candidates.map(\.label), ["Continue", "shift", "continue", "Emoji"])
        XCTAssertEqual(candidates.map(\.isKeyboard), [false, true, true, true])
        let request = GoalNavigationRequest(goal: "Complete onboarding", snapshot: withKeyboard,
            candidates: candidates, recentActions: [])
        XCTAssertEqual(GoalNavigationSafety.obviousChoice(request, snapshot: withKeyboard,
            appBundleID: "dev.fixture")?.candidateID, candidates[0].id)
        let uncertain = UISnapshot(captureID: .init(), elements: withKeyboard.elements.enumerated().map { index, element in
            guard index == 3 else { return element }
            return UIElement(identifier: element.identifier, role: element.role, label: element.label,
                value: element.value, frame: element.frame, isEnabled: element.isEnabled,
                isHittable: nil, originBundleIdentifier: element.originBundleIdentifier)
        })
        XCTAssertEqual(GoalNavigationSafety.unconfirmedProgressButton(in: uncertain,
            appBundleID: "dev.fixture")?.label, "Continue")
    }
    func testBlockedNavigatorRechecksVisibleAppContinueBehindKeyboard() async throws {
        let test = TestCase(name: "Onboarding", goal: "Complete onboarding", executionMode: .goal, blocks: [])
        let project = TestProject(name: "Fixture", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "dev.fixture"),
            simulator: .init(deviceID: "device"), categories: [.init(name: "General", suites: [.init(name: "Suite", tests: [test])])])
        let driver = SavedInputDriver(uncertainContinue: true)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: SavedInputEvaluator(),
            goalNavigator: SavedInputChooser(), savedInputs: [.init(name: "Name", value: "Saved answer")])
            .startGoal(project: project)
        var diagnostics: [String] = []
        for await event in handle.events {
            if case .diagnostic(let message) = event { diagnostics.append(message) }
        }
        let outcome = await handle.task.value.outcome
        XCTAssertEqual(outcome, .passed, diagnostics.joined(separator: " | "))
        XCTAssertTrue(diagnostics.contains(where: { $0.contains("Rechecked the visible Continue button") }))
    }

    func testSavedNameMatchesUnlabelledFieldBesidePromptButNotAnAmbiguousOrForeignField() {
        let bundle = "dev.fixture"
        let prompt = UIElement(identifier: nil, role: "staticText", label: "What's your name?", value: nil,
            frame: .init(x: 52, y: 605, width: 298, height: 30), isEnabled: true,
            originBundleIdentifier: bundle)
        let field = UIElement(identifier: nil, role: "textField", label: "", value: nil,
            frame: .init(x: 48, y: 669, width: 306, height: 25), isEnabled: true,
            isHittable: true, originBundleIdentifier: bundle)
        let disabledContinue = UIElement(identifier: nil, role: "button", label: "Continue", value: nil,
            frame: nil, isEnabled: false, originBundleIdentifier: bundle)
        let input = GoalSavedInput(name: "Name", value: "Saved answer")
        let snapshot = UISnapshot(captureID: .init(), elements: [prompt, field, disabledContinue])
        XCTAssertEqual(GoalNavigationSafety.savedInputTarget(in: snapshot, inputs: [input], appBundleID: bundle)?.0, field)
        XCTAssertNil(GoalNavigationSafety.savedInputTarget(in: .init(captureID: .init(), elements: [field, disabledContinue]), inputs: [input], appBundleID: bundle))
        let secondField = UIElement(identifier: nil, role: "textField", label: "", value: nil,
            frame: .init(x: 48, y: 680, width: 306, height: 25), isEnabled: true,
            isHittable: true, originBundleIdentifier: bundle)
        XCTAssertNil(GoalNavigationSafety.savedInputTarget(in: .init(captureID: .init(), elements: [prompt, field, secondField]), inputs: [input], appBundleID: bundle))
        let foreignField = UIElement(identifier: nil, role: "textField", label: "Name", value: nil,
            frame: .init(x: 48, y: 669, width: 306, height: 25), isEnabled: true,
            isHittable: true, originBundleIdentifier: "system.sheet")
        XCTAssertNil(GoalNavigationSafety.savedInputTarget(in: .init(captureID: .init(), elements: [prompt, foreignField]), inputs: [input], appBundleID: bundle))
    }

    func testUnverifiedGoalDoesNotSaveReplayRoute() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GoalReplayStore(directory: directory)
        let saved = project()
        let handle = ExecutionEngine(driver: NavigationDriver(), assertionEvaluator: InsufficientNavigationEvaluator(),
            goalNavigator: NavigationChooser(), goalReplayStore: store).startGoal(project: saved)
        for await _ in handle.events {}
        let outcome = await handle.task.value.outcome
        let identity = try GoalReplayRoute.Identity(project: saved, test: saved.categories[0].suites[0].tests[0])
        let route = await store.load(identity)
        XCTAssertNotEqual(outcome, .passed)
        XCTAssertNil(route)
    }

    func testReplayRejectsAmbiguousOrUnavailableControl() {
        let button = UIElement(identifier: "next", role: "button", label: "Next", value: nil,
            frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture")
        let initial = UISnapshot(captureID: .init(), elements: [button])
        let step = GoalReplayRoute.Step(screen: GoalReplaySafety.screen(in: initial, appBundleID: "dev.fixture"), element: button)
        XCTAssertNotNil(GoalReplaySafety.candidate(for: step, in: initial, appBundleID: "dev.fixture"))
        let duplicate = UISnapshot(captureID: .init(), elements: [button, button])
        XCTAssertNil(GoalReplaySafety.candidate(for: step, in: duplicate, appBundleID: "dev.fixture"))
        let disabled = UISnapshot(captureID: .init(), elements: [.init(identifier: "next", role: "button",
            label: "Next", value: nil, frame: nil, isEnabled: false, isHittable: true,
            originBundleIdentifier: "dev.fixture")])
        XCTAssertNil(GoalReplaySafety.candidate(for: step, in: disabled, appBundleID: "dev.fixture"))
    }

    func testGoalWarmupCanUseAccessibilityButRequiredTextFallbackCannot() async {
        let goalHandle = ExecutionEngine(driver: NavigationDriver(), assertionEvaluator: NavigationEvaluator(),
            goalNavigator: NavigationChooser()).startGoal(project: project())
        for await _ in goalHandle.events {}
        let goalOutcome = await goalHandle.task.value.outcome
        XCTAssertEqual(goalOutcome, .passed)

        let strictTest = TestCase(name: "Needs OCR", blocks: [], recoveryPolicy: .init(allowTextFallback: true))
        let strictProject = TestProject(name: "Strict", app: .init(projectPath: "Fixture.xcodeproj", scheme: "Fixture",
            bundleIdentifier: "dev.fixture"), simulator: .init(deviceID: "fixture"),
            categories: [.init(name: "Strict", suites: [.init(name: "Strict", tests: [strictTest])])])
        let strictHandle = ExecutionEngine(driver: NavigationDriver()).start(project: strictProject)
        for await _ in strictHandle.events {}
        let strictOutcome = await strictHandle.task.value.outcome
        XCTAssertEqual(strictOutcome, .blocked)
    }

    func testVerifiedGoalRouteReplaysWithoutNavigatorAndAssessesAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GoalReplayStore(directory: directory)
        let saved = project()
        let firstDriver = NavigationDriver()
        let firstChooser = CountingNavigationChooser()
        let first = ExecutionEngine(driver: firstDriver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: firstChooser, goalReplayStore: store).startGoal(project: saved)
        for await _ in first.events {}
        let firstOutcome = await first.task.value.outcome
        XCTAssertEqual(firstOutcome, .passed)
        let firstCalls = await firstChooser.calls
        XCTAssertGreaterThan(firstCalls, 0)
        let identity = try GoalReplayRoute.Identity(project: saved, test: saved.categories[0].suites[0].tests[0])
        let savedRoute = await store.load(identity)
        XCTAssertEqual(savedRoute?.steps.count, 3)

        let secondDriver = NavigationDriver()
        let secondChooser = CountingNavigationChooser()
        let second = ExecutionEngine(driver: secondDriver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: secondChooser, goalReplayStore: store).startGoal(project: saved)
        var verifiedReplay = false
        for await event in second.events {
            if case .diagnostic(let message) = event, message.contains("Verified replay completed") { verifiedReplay = true }
        }
        let secondOutcome = await second.task.value.outcome
        let secondCalls = await secondChooser.calls
        let secondActions = await secondDriver.actions
        XCTAssertEqual(secondOutcome, .passed)
        XCTAssertEqual(secondCalls, 0)
        XCTAssertEqual(secondActions, ["Get Started", "Not Now", "Start meditation"])
        XCTAssertTrue(verifiedReplay)
    }

    func testChangedReplayScreenReturnsToLiveNavigator() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GoalReplayStore(directory: directory)
        let saved = project()
        let first = ExecutionEngine(driver: NavigationDriver(), assertionEvaluator: NavigationEvaluator(),
            goalNavigator: NavigationChooser(), goalReplayStore: store).startGoal(project: saved)
        for await _ in first.events {}
        let firstOutcome = await first.task.value.outcome
        XCTAssertEqual(firstOutcome, .passed)
        let chooser = CountingNavigationChooser()
        let second = ExecutionEngine(driver: NavigationDriver(welcomeTitle: "Welcome back"),
            assertionEvaluator: NavigationEvaluator(), goalNavigator: chooser, goalReplayStore: store).startGoal(project: saved)
        var sawFallback = false
        for await event in second.events {
            if case .diagnostic(let message) = event, message.contains("resuming live navigation") { sawFallback = true }
        }
        let secondOutcome = await second.task.value.outcome
        let liveCalls = await chooser.calls
        XCTAssertEqual(secondOutcome, .passed)
        XCTAssertGreaterThan(liveCalls, 0)
        XCTAssertTrue(sawFallback)
    }
    func testReturningAppleAccountSheetIsRecognized() {
        let now = Date()
        let text = TextPerception(captureID: .init(), geometry: .init(pixels: .init(width: 100, height: 100),
            screenFrame: .init(x: 0, y: 0, width: 100, height: 100)), screenshotStartedAt: now,
            recognitionStartedAt: now, recognitionCompletedAt: now, recognitionMilliseconds: 1,
            provider: "test.ocr", imageSHA256: String(repeating: "a", count: 64),
            regions: ["Sign in with Apple", "Sign in to Example App using your Apple Account.",
                "Example User", "Sign In with Password"].enumerated().map { index, line in
                .init(text: line, confidence: 0.95,
                    pixelBox: .init(x: 0, y: Double(index) * 10, width: 90, height: 8))
            })
        XCTAssertEqual(VisualInterruption.recognize(text), .appleAccountSignIn)
    }

    private func project() -> TestProject {
        .init(name: "Meditation", app: .init(projectPath: "Fixture.xcodeproj", scheme: "Fixture", bundleIdentifier: "dev.fixture"),
              simulator: .init(deviceID: "fixture"), categories: [.init(name: "Goal", suites: [.init(name: "Goal", tests: [.init(name: "Start meditation", goal: "Start a meditation", blocks: [], timeoutSeconds: 600)])])])
    }
    func testLiveGoalNavigatesOnboardingAndDismissesPaywallBeforeVerifyingGoal() async {
        let driver = NavigationDriver()
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(), goalNavigator: NavigationChooser()).startGoal(project: project())
        var events: [ExecutionEvent] = []
        for await event in handle.events { events.append(event) }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Get Started", "Not Now", "Start meditation"])
        XCTAssertTrue(events.contains { if case .goalAssessment(let evidence) = $0 { return evidence.outcome == .passed }; return false })
    }
    func testStaleCaptureRecapturesAndContinuesGoal() async {
        let driver = NavigationDriver(staleActionsRemaining: 7)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(), goalNavigator: NavigationChooser()).startGoal(project: project())
        var events: [ExecutionEvent] = []
        for await event in handle.events { events.append(event) }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Get Started", "Not Now", "Start meditation"])
        XCTAssertTrue(events.contains { event in
            if case .diagnostic(let message) = event { return message.contains("recapturing and retrying (attempt 7)") }
            return false
        })
    }
    func testDriverMappedStaleCaptureAlsoRecaptures() async {
        let driver = NavigationDriver(staleActionsRemaining: 2, mappedStale: true)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(), goalNavigator: NavigationChooser()).startGoal(project: project())
        for await _ in handle.events {}
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Get Started", "Not Now", "Start meditation"])
    }
    func testBlockedGoalExploresWithSwipeAndContinues() async {
        let driver = ExplorationDriver()
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(), goalNavigator: NavigationChooser()).startGoal(project: project())
        var diagnostics: [String] = []
        for await event in handle.events {
            if case .diagnostic(let message) = event { diagnostics.append(message) }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["up", "Start meditation"])
        XCTAssertTrue(diagnostics.contains("Exploratory up swipe changed visible app content"))
    }
    func testBlockedGoalTriesAllFourDirectionsBeforeEnding() async {
        let driver = StationarySwipeDriver()
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(), goalNavigator: NavigationChooser()).startGoal(project: project())
        var diagnostics: [String] = []
        for await event in handle.events {
            if case .diagnostic(let message) = event { diagnostics.append(message) }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .needsReview)
        let directions = await driver.directions
        XCTAssertEqual(directions, [.up, .down, .left, .right])
        XCTAssertTrue(diagnostics.contains("Exploratory up swipe did not change visible app content"))
    }
    func testBlockedModelUsesUniqueVisibleProgressControl() async {
        let driver = NavigationDriver()
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(), goalNavigator: BlockedNavigationChooser()).startGoal(project: project())
        for await _ in handle.events {}
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Get Started", "Not Now", "Start meditation"])
    }
    func testEmptyAccessibilityCandidatesUseOCRToTapVisiblePaywallControl() async {
        let driver = OCRPaywallDriver()
        let test = TestCase(name: "Train Tab Paywall", goal: "Tap Create scenario to show the paywall",
            successCriteria: "Subscription required is visible", executionMode: .goal,
            blocks: [], timeoutSeconds: 30)
        let goalProject = TestProject(name: "Paywall", app: .init(projectPath: "Fixture.xcodeproj",
            scheme: "Fixture", bundleIdentifier: "dev.fixture"), simulator: .init(deviceID: "device"),
            categories: [.init(name: "General", suites: [.init(name: "Suite", tests: [test])])])
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: OCRPaywallEvaluator(),
            goalNavigator: OCRPaywallChooser()).startGoal(project: goalProject)
        for await _ in handle.events {}
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let tapCount = await driver.tapCount
        XCTAssertEqual(tapCount, 1)
    }
    func testOCRCandidatesExcludePurchaseText() {
        let snapshot = UISnapshot(captureID: .init(), elements: [
            UIElement(identifier: nil, role: "application", label: "Fixture", value: nil,
                frame: .init(x: 0, y: 0, width: 400, height: 800), isEnabled: true,
                originBundleIdentifier: "dev.fixture")
        ])
        let started = Date()
        let perception = TextPerception(captureID: snapshot.captureID,
            geometry: .init(pixels: .init(width: 400, height: 800),
                screenFrame: .init(x: 0, y: 0, width: 400, height: 800)),
            screenshotStartedAt: snapshot.capturedAt, recognitionStartedAt: started,
            recognitionCompletedAt: Date(), recognitionMilliseconds: 1,
            provider: "test.ocr", imageSHA256: String(repeating: "a", count: 64),
            regions: [
                .init(text: "Create scenario", confidence: 0.96,
                    pixelBox: .init(x: 40, y: 180, width: 220, height: 40)),
                .init(text: "Start Free Trial", confidence: 0.96,
                    pixelBox: .init(x: 40, y: 320, width: 220, height: 40))
            ])
        let candidates = GoalNavigationSafety.ocrCandidates(perception, snapshot: snapshot,
            appBundleID: "dev.fixture")
        XCTAssertEqual(candidates.map(\.label), ["Create scenario"])
    }
    func testVisualControlUsesOffCentreFrameAndRejectsAmbiguousFrames() {
        let id = CaptureID()
        let app = UIElement(identifier: nil, role: "application", label: "Fixture", value: nil,
            frame: .init(x: 0, y: 0, width: 400, height: 800), isEnabled: true,
            originBundleIdentifier: "dev.fixture")
        let canvas = UIElement(identifier: nil, role: "other", label: nil, value: nil,
            frame: .init(x: 30, y: 160, width: 300, height: 90), isEnabled: true,
            isHittable: true, originBundleIdentifier: "dev.fixture")
        let region = TextRegion(text: "Create scenario", confidence: 0.95,
            pixelBox: .init(x: 45, y: 180, width: 130, height: 25))
        let perception = TextPerception(captureID: id, geometry: .init(pixels: .init(width: 400, height: 800),
            screenFrame: .init(x: 0, y: 0, width: 400, height: 800)), screenshotStartedAt: Date(),
            recognitionStartedAt: Date(), recognitionCompletedAt: Date(), recognitionMilliseconds: 1,
            provider: "test.ocr", imageSHA256: String(repeating: "a", count: 64), regions: [region])
        let selected = GoalNavigationSafety.enclosingVisualControl(region, perception: perception,
            snapshot: UISnapshot(captureID: id, elements: [app, canvas]), appBundleID: "dev.fixture")
        XCTAssertEqual(selected, canvas)
        XCTAssertNotEqual(canvas.frame!.x + canvas.frame!.width / 2, region.center.x)
        let duplicate = UIElement(identifier: nil, role: "other", label: nil, value: nil,
            frame: .init(x: 35, y: 165, width: 290, height: 85), isEnabled: true,
            isHittable: true, originBundleIdentifier: "dev.fixture")
        XCTAssertNil(GoalNavigationSafety.enclosingVisualControl(region, perception: perception,
            snapshot: UISnapshot(captureID: id, elements: [app, canvas, duplicate]), appBundleID: "dev.fixture"))
    }
    func testUnrelatedAccessibilityControlTriggersOCRCheck() {
        XCTAssertTrue(GoalNavigationSafety.shouldCheckOCR(goal: "Tap Create scenario",
            candidates: [.init(id: "profile", label: "Profile", elementIndex: 0)]))
        XCTAssertFalse(GoalNavigationSafety.shouldCheckOCR(goal: "Finish setup",
            candidates: [.init(id: "continue", label: "Continue", elementIndex: 0)]))
        let snapshot = UISnapshot(captureID: .init(), elements: [
            UIElement(identifier: nil, role: "application", label: "Fixture", value: nil,
                frame: .init(x: 0, y: 0, width: 400, height: 800), isEnabled: true,
                originBundleIdentifier: "dev.fixture"),
            UIElement(identifier: nil, role: "staticText", label: "Setup complete", value: nil,
                frame: .init(x: 50, y: 120, width: 300, height: 45), isEnabled: true,
                originBundleIdentifier: "dev.fixture")
        ])
        let request = GoalNavigationRequest(goal: "Tap Finish setup so Setup complete appears",
            snapshot: snapshot, candidates: [.init(id: "ocr-0", label: "Setup complete", elementIndex: nil,
                isOCR: true)], recentActions: [])
        XCTAssertNil(GoalNavigationSafety.requestedOCRChoice(request, snapshot: snapshot,
            appBundleID: "dev.fixture"))
        XCTAssertEqual(GoalNavigationSafety.literalVisibleSuccess("Setup complete is visible",
            snapshot: snapshot, appBundleID: "dev.fixture"), "Setup complete")
        let offscreen = UISnapshot(captureID: .init(), elements: [snapshot.elements[0],
            UIElement(identifier: nil, role: "staticText", label: "Setup complete", value: nil,
                frame: .init(x: 50, y: 900, width: 300, height: 45), isEnabled: true,
                originBundleIdentifier: "dev.fixture")])
        XCTAssertNil(GoalNavigationSafety.literalVisibleSuccess("Setup complete is visible",
            snapshot: offscreen, appBundleID: "dev.fixture"))
        let covered = UISnapshot(captureID: .init(), elements: snapshot.elements + [
            UIElement(identifier: nil, role: "alert", label: "Confirm", value: nil,
                frame: .init(x: 80, y: 300, width: 240, height: 150), isEnabled: true,
                containingAlertIdentifier: "alert:Confirm", containingAlertContext: "Confirm\nDismiss",
                originBundleIdentifier: "dev.fixture")])
        XCTAssertNil(GoalNavigationSafety.literalVisibleSuccess("Setup complete is visible",
            snapshot: covered, appBundleID: "dev.fixture"))
        let headingSnapshot = UISnapshot(captureID: .init(), elements: [snapshot.elements[0],
            UIElement(identifier: nil, role: "staticText", label: "Create scenario", value: nil,
                frame: .init(x: 50, y: 120, width: 300, height: 45), isEnabled: true,
                originBundleIdentifier: "dev.fixture")])
        XCTAssertEqual(GoalNavigationSafety.unactionableRequestedHeading(
            goal: "Tap Create scenario so Scenario created appears", snapshot: headingSnapshot,
            appBundleID: "dev.fixture"), "Create scenario")
        XCTAssertTrue(GoalNavigationSafety.mismatchesExplicitTap("Profile",
            goal: "Tap Create scenario so Scenario created appears"))
        XCTAssertFalse(GoalNavigationSafety.mismatchesExplicitTap("Create scenario",
            goal: "Tap Create scenario so Scenario created appears"))
    }
    func testStalledAccessibilityChoiceChecksOCRForRequestedControl() async {
        let driver = OCRPaywallDriver(incidentalAccessibilityControl: true)
        let test = TestCase(name: "Train Tab Paywall", goal: "Tap Create scenario to show the paywall",
            successCriteria: "Subscription required is visible", executionMode: .goal,
            blocks: [], timeoutSeconds: 30)
        let goalProject = TestProject(name: "Paywall", app: .init(projectPath: "Fixture.xcodeproj",
            scheme: "Fixture", bundleIdentifier: "dev.fixture"), simulator: .init(deviceID: "device"),
            categories: [.init(name: "General", suites: [.init(name: "Suite", tests: [test])])])
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: OCRPaywallEvaluator(),
            goalNavigator: OCRPaywallChooser()).startGoal(project: goalProject)
        for await _ in handle.events {}
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let tapCount = await driver.tapCount
        XCTAssertEqual(tapCount, 1)
    }
    func testAccurateOCRRecoversRequestedControlWhenFastPassMisses() async {
        let driver = OCRPaywallDriver(incidentalAccessibilityControl: true, fastMisses: true)
        let test = TestCase(name: "Fast miss", goal: "Tap Create scenario to show the paywall",
            successCriteria: "Subscription required is visible", executionMode: .goal,
            blocks: [], timeoutSeconds: 30)
        let goalProject = TestProject(name: "Paywall", app: .init(projectPath: "Fixture.xcodeproj",
            scheme: "Fixture", bundleIdentifier: "dev.fixture"), simulator: .init(deviceID: "device"),
            categories: [.init(name: "General", suites: [.init(name: "Suite", tests: [test])])])
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: OCRPaywallEvaluator(),
            goalNavigator: OCRPaywallChooser()).startGoal(project: goalProject)
        for await _ in handle.events {}
        let report = await handle.task.value
        let taps = await driver.tapCount
        let accurateCalls = await driver.accurateCalls
        XCTAssertEqual(report.outcome, .passed)
        XCTAssertEqual(taps, 1)
        XCTAssertGreaterThan(accurateCalls, 0)
    }
    func testRequestedHiddenControlSkipsDistractorWhenNavigatorIsBlocked() async {
        let driver = OCRPaywallDriver(incidentalAccessibilityControl: true)
        let test = TestCase(name: "Hidden control", goal: "Tap Create scenario to show the paywall",
            successCriteria: "Subscription required is visible", executionMode: .goal,
            blocks: [], timeoutSeconds: 30)
        let goalProject = TestProject(name: "Paywall", app: .init(projectPath: "Fixture.xcodeproj",
            scheme: "Fixture", bundleIdentifier: "dev.fixture"), simulator: .init(deviceID: "device"),
            categories: [.init(name: "General", suites: [.init(name: "Suite", tests: [test])])])
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: OCRPaywallEvaluator(),
            goalNavigator: BlockedBeforePaywallChooser()).startGoal(project: goalProject)
        for await _ in handle.events {}
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let taps = await driver.tapCount
        XCTAssertEqual(taps, 1)
    }
    func testLoginScreenUsesUniqueSafeControlWhenModelActionCannotBeVerified() async {
        let driver = LoginDriver()
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: MismatchedLoginChooser()).startGoal(project: project())
        var events: [ExecutionEvent] = []
        for await event in handle.events { events.append(event) }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Sign in with Apple"])
        XCTAssertTrue(events.contains { if case .diagnostic(let message) = $0 { return message.contains("using a visible progress choice") }; return false })
    }
    func testSavedGoalSummaryExplainsStalledLoginTap() async {
        let driver = LoginDriver(advances: false)
        let test = TestCase(name: "Onboard", goal: "Complete onboarding", executionMode: .goal, blocks: [], timeoutSeconds: 30)
        let saved = TestProject(name: "Meditation", app: .init(projectPath: "Fixture.xcodeproj", scheme: "Fixture", bundleIdentifier: "dev.fixture"),
            simulator: .init(deviceID: "fixture"), categories: [.init(name: "Goal", suites: [.init(name: "Goal", tests: [test])])])
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: MismatchedLoginChooser()).start(project: saved)
        var events: [ExecutionEvent] = []
        for await event in handle.events { events.append(event) }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .needsReview)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Sign in with Apple", "Sign in with Apple"])
        XCTAssertTrue(events.contains { if case .failureSummary(let summary) = $0 {
            return summary.source.reason.contains("After tapping Sign in with Apple")
        }; return false })
    }
    func testSavedGoalPausesForAppleSheetAndContinuesAfterHandoff() async {
        let driver = LoginDriver(advances: false, opensSheet: true)
        let test = TestCase(name: "Onboard", goal: "Start a meditation", executionMode: .goal, blocks: [], timeoutSeconds: 30)
        let saved = TestProject(name: "Meditation", app: .init(projectPath: "Fixture.xcodeproj", scheme: "Fixture", bundleIdentifier: "dev.fixture"),
            simulator: .init(deviceID: "fixture"), categories: [.init(name: "Goal", suites: [.init(name: "Goal", tests: [test])])])
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: MismatchedLoginChooser()).start(project: saved)
        var sawPause = false
        for await event in handle.events {
            if case .state(.paused) = event {
                sawPause = true
                await handle.control.resume()
            }
        }
        let report = await handle.task.value
        XCTAssertTrue(sawPause)
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Sign in with Apple", "Hide My Email", "Continue with Password"])
    }
    func testDelayedAppleSheetIsObservedBeforeRetryingLogin() async {
        let driver = LoginDriver(advances: false, opensSheet: true, sheetDelayCaptures: 3)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: MismatchedLoginChooser()).startGoal(project: project())
        var sawPause = false
        for await event in handle.events {
            if case .state(.paused) = event {
                sawPause = true
                await handle.control.resume()
            }
        }
        let report = await handle.task.value
        XCTAssertTrue(sawPause)
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Sign in with Apple", "Hide My Email", "Continue with Password"])
    }
    func testMissingStoredApplePasswordIsTypedBlocker() async {
        let driver = LoginDriver(advances: false, opensSheet: true, requiresPassword: true)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: MismatchedLoginChooser()).startGoal(project: project())
        var blockers: [ExecutionBlocker] = []
        for await event in handle.events {
            if case .state(.paused) = event { await handle.control.resume() }
            if case .blocker(let blocker) = event { blockers.append(blocker) }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .needsReview)
        XCTAssertEqual(blockers, [
            .legalConsentRequired("App account creation and Terms & Conditions"),
            .missingSecret(.appleAccountPassword(account: "fixture@example.invalid"))
        ])
    }
    func testReturningApplePasswordSheetWaitsForTransitionBeforeReadingPassword() async {
        let driver = LoginDriver(advances: false, opensSheet: true, returningAccount: true,
            passwordTransitionCaptures: 2)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: MismatchedLoginChooser()).startGoal(project: project())
        var blockers: [ExecutionBlocker] = []
        for await event in handle.events {
            if case .blocker(let blocker) = event { blockers.append(blocker) }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .needsReview)
        XCTAssertEqual(blockers, [.missingSecret(.appleAccountPassword(account: "fixture@example.invalid"))])
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Sign in with Apple", "Sign In with Password"])
    }
    func testHiddenSystemPasswordFieldIsTypedBlocker() async {
        let driver = LoginDriver(advances: false, opensSheet: true, requiresPassword: true,
            unavailablePasswordField: true)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: MismatchedLoginChooser()).startGoal(project: project())
        var blockers: [ExecutionBlocker] = []
        for await event in handle.events {
            if case .state(.paused) = event { await handle.control.resume() }
            if case .blocker(let blocker) = event { blockers.append(blocker) }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .needsReview)
        XCTAssertEqual(blockers, [
            .legalConsentRequired("App account creation and Terms & Conditions"),
            .secureInputUnavailable(.appleAccountPassword(account: "fixture@example.invalid"))
        ])
    }
    func testUnacknowledgedSystemPasswordInputIsTypedBlocker() async {
        let driver = LoginDriver(advances: false, opensSheet: true, requiresPassword: true,
            unverifiedPasswordInput: true)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: MismatchedLoginChooser()).startGoal(project: project())
        var blockers: [ExecutionBlocker] = []
        for await event in handle.events {
            if case .state(.paused) = event { await handle.control.resume() }
            if case .blocker(let blocker) = event { blockers.append(blocker) }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .needsReview)
        XCTAssertEqual(blockers, [
            .legalConsentRequired("App account creation and Terms & Conditions"),
            .secureInputUnverified(.appleAccountPassword(account: "fixture@example.invalid"))
        ])
    }
    func testSlowModelRecapturesBeforeDispatchingLoginTap() async {
        let driver = LoginDriver(requireFreshAction: true)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: SlowLoginChooser()).startGoal(project: project())
        for await _ in handle.events {}
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Sign in with Apple"])
        let captures = await driver.captureCount
        XCTAssertGreaterThanOrEqual(captures, 4)
    }
    func testMissingScriptedNextButtonRecoversThroughGoal() async {
        let driver = NavigationDriver()
        let test = TestCase(name: "Click through onboarding", goal: "Start a meditation",
            blocks: [.init(title: "Next Button", action: .tap(targets: [.text("Next Button")]))],
            assertions: [.exists(.text("Next Button"))], timeoutSeconds: 30)
        let scripted = TestProject(name: "Meditation", app: .init(projectPath: "Fixture.xcodeproj", scheme: "Fixture", bundleIdentifier: "dev.fixture"),
            simulator: .init(deviceID: "fixture"), categories: [.init(name: "Goal", suites: [.init(name: "Goal", tests: [test])])])
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(), goalNavigator: NavigationChooser()).start(project: scripted)
        var events: [ExecutionEvent] = []
        for await event in handle.events { events.append(event) }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Get Started", "Not Now", "Start meditation"])
        XCTAssertTrue(events.contains { if case .diagnostic(let message) = $0 { return message.contains("trying the goal") }; return false })
    }
    func testSavedGoalIgnoresStoredStepsAndVerifiesSuccessCriteria() async {
        let driver = NavigationDriver()
        let test = TestCase(name: "Meditation goal", goal: "Start a meditation",
            successCriteria: "Meditation playing is visible", executionMode: .goal,
            blocks: [.init(title: "Outdated Next", action: .tap(targets: [.text("Next Button")]))], timeoutSeconds: 30)
        let saved = TestProject(name: "Meditation", app: .init(projectPath: "Fixture.xcodeproj", scheme: "Fixture", bundleIdentifier: "dev.fixture"),
            simulator: .init(deviceID: "fixture"), categories: [.init(name: "Goal", suites: [.init(name: "Goal", tests: [test])])])
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: CriteriaEvaluator(), goalNavigator: NavigationChooser()).start(project: saved)
        var events: [ExecutionEvent] = []
        for await event in handle.events { events.append(event) }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["Get Started", "Not Now", "Start meditation"])
        XCTAssertFalse(events.contains { if case .blockStarted(let id) = $0 { return id == test.blocks[0].id }; return false })
        XCTAssertTrue(events.contains { if case .goalAssessment(let evidence) = $0 { return evidence.request?.successCriteria == test.successCriteria }; return false })
    }
    func testLegacyTestDefaultsToScriptedAndModeSwitchPreservesSteps() throws {
        let original = TestCase(name: "Legacy", goal: "Reach home", blocks: [.init(title: "Next", action: .tap(targets: [.text("Next")]))])
        var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        data.removeValue(forKey: "successCriteria")
        data.removeValue(forKey: "executionMode")
        let decoded = try JSONDecoder().decode(TestCase.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertEqual(decoded.effectiveExecutionMode, .scripted)
        XCTAssertEqual(decoded.replacing(executionMode: .goal).effectiveExecutionMode, .goal)
        XCTAssertEqual(decoded.replacing(executionMode: .goal).replacing(executionMode: .scripted).blocks, decoded.blocks)
        let goal = decoded.replacing(successCriteria: "Home screen is visible", executionMode: .goal)
        let roundTrip = try JSONDecoder().decode(TestCase.self, from: JSONEncoder().encode(goal))
        XCTAssertEqual(roundTrip.effectiveExecutionMode, .goal)
        XCTAssertEqual(roundTrip.successCriteria, "Home screen is visible")
        XCTAssertEqual(roundTrip.blocks, decoded.blocks)
    }
    func testObviousChoiceRefusesAmbiguousAndForeignControls() {
        func button(_ label: String, origin: String? = "dev.fixture") -> UIElement {
            .init(identifier: label, role: "button", label: label, value: nil, frame: nil,
                  isEnabled: true, isHittable: true, originBundleIdentifier: origin)
        }
        let ambiguous = UISnapshot(captureID: .init(), elements: [button("Next"), button("Continue")])
        let ambiguousRequest = GoalNavigationRequest(goal: "Proceed", snapshot: ambiguous,
            candidates: GoalNavigationSafety.candidates(in: ambiguous, appBundleID: "dev.fixture"), recentActions: [])
        XCTAssertNil(GoalNavigationSafety.obviousChoice(ambiguousRequest, snapshot: ambiguous, appBundleID: "dev.fixture"))

        let overlay = UISnapshot(captureID: .init(), elements: [button("Next"), button("Continue with Password", origin: "com.apple.AuthenticationServicesUI")])
        let overlayRequest = GoalNavigationRequest(goal: "Proceed", snapshot: overlay,
            candidates: GoalNavigationSafety.candidates(in: overlay, appBundleID: "dev.fixture"), recentActions: [])
        XCTAssertNil(GoalNavigationSafety.obviousChoice(overlayRequest, snapshot: overlay, appBundleID: "dev.fixture"))

        let onboarding = UISnapshot(captureID: .init(), elements: [button("Back"),
            .init(identifier: nil, role: "staticText", label: "Find your calm", value: nil, frame: nil)])
        let onboardingRequest = GoalNavigationRequest(goal: "Complete onboarding", snapshot: onboarding,
            candidates: GoalNavigationSafety.candidates(in: onboarding, appBundleID: "dev.fixture"), recentActions: [])
        XCTAssertNil(GoalNavigationSafety.obviousChoice(onboardingRequest, snapshot: onboarding, appBundleID: "dev.fixture"))

        let carousel = UISnapshot(captureID: .init(), elements: [
            .init(identifier: nil, role: "application", label: "Demo", value: nil,
                  frame: .init(x: 0, y: 0, width: 402, height: 874), originBundleIdentifier: "dev.fixture"),
            .init(identifier: "category-0", role: "button", label: "Focus", value: nil,
                  frame: .init(x: 51, y: 226, width: 300, height: 400),
                  isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture"),
            .init(identifier: "category-1", role: "button", label: "Relaxation", value: nil,
                  frame: .init(x: 386, y: 246, width: 270, height: 360),
                  isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture")
        ])
        let carouselRequest = GoalNavigationRequest(goal: "Start a meditation", snapshot: carousel,
            candidates: GoalNavigationSafety.candidates(in: carousel, appBundleID: "dev.fixture"), recentActions: [])
        XCTAssertEqual(GoalNavigationSafety.obviousChoice(carouselRequest, snapshot: carousel,
            appBundleID: "dev.fixture")?.candidateID, "element-1")
    }
    func testHealthDeclarationIsRecognizedForOnboarding() {
        let snapshot = UISnapshot(captureID: .init(), elements: [
            .init(identifier: nil, role: "staticText",
                  label: "I understand the risks and confirm that I do not have any of the listed conditions. I accept full responsibility for my use of this app.",
                  value: nil, frame: nil),
            .init(identifier: nil, role: "button", label: "Accept & Continue", value: nil,
                  frame: nil, isEnabled: true, isHittable: true)
        ])
        XCTAssertNotNil(GoalNavigationSafety.humanAttestationReason(in: snapshot))
    }
    func testGoalAutomaticallyAcceptsOnboardingDeclaration() async {
        let driver = DeclarationDriver()
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: NavigationChooser()).startGoal(project: project())
        var paused = false
        for await event in handle.events {
            if case .state(.paused) = event { paused = true }
        }
        let report = await handle.task.value
        let actions = await driver.actions
        XCTAssertEqual(report.outcome, .passed)
        XCTAssertEqual(actions, ["checkbox", "accept"])
        XCTAssertFalse(paused)
    }
    func testGoalReportsUnchangedDeclarationAfterAccept() async {
        let driver = DeclarationDriver(transitionsAfterAccept: false)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: NavigationEvaluator(),
            goalNavigator: NavigationChooser()).startGoal(project: project())
        for await _ in handle.events {}
        let report = await handle.task.value
        let actions = await driver.actions
        XCTAssertEqual(report.outcome, .needsReview)
        XCTAssertEqual(actions, ["checkbox", "accept"])
    }
    func testGenericPersonalAttestationRequiresExactStatement() {
        let statement = "I certify that I meet the eligibility requirements."
        let snapshot = UISnapshot(captureID: .init(), elements: [
            .init(identifier: nil, role: "staticText", label: statement, value: nil, frame: nil),
            .init(identifier: nil, role: "button", label: "Agree & Continue", value: nil,
                  frame: nil, isEnabled: false, isHittable: false)
        ])
        XCTAssertEqual(GoalNavigationSafety.humanAttestationReason(in: snapshot), statement)
        let ordinary = UISnapshot(captureID: .init(), elements: [
            .init(identifier: nil, role: "staticText", label: "You can begin now", value: nil, frame: nil),
            .init(identifier: nil, role: "button", label: "Begin", value: nil,
                  frame: nil, isEnabled: true, isHittable: true)
        ])
        XCTAssertNil(GoalNavigationSafety.humanAttestationReason(in: ordinary))
    }
    func testInstructionalSafetyTextDoesNotHideContinue() {
        let snapshot = UISnapshot(captureID: .init(), elements: [
            .init(identifier: nil, role: "staticText",
                  label: "Allow the meditation to guide you. Stop if you feel uncomfortable.",
                  value: nil, frame: nil),
            .init(identifier: "instructions-continue", role: "button", label: "Continue",
                  value: nil, frame: nil, isEnabled: true, isHittable: true,
                  originBundleIdentifier: "dev.fixture")
        ])
        XCTAssertFalse(GoalNavigationSafety.restrictedScreen(snapshot))
        let candidates = GoalNavigationSafety.candidates(in: snapshot, appBundleID: "dev.fixture")
        XCTAssertEqual(candidates.map(\.label), ["Continue"])
        let request = GoalNavigationRequest(goal: "Start meditation", snapshot: snapshot,
            candidates: candidates, recentActions: [])
        XCTAssertEqual(GoalNavigationSafety.obviousChoice(request, snapshot: snapshot,
            appBundleID: "dev.fixture")?.candidateID, "element-1")
    }
    func testSplitAccessibilityTimerIsReadable() {
        let labels = ["1", "4", ":", "5", "7"]
        let elements = labels.enumerated().map { index, label in
            UIElement(identifier: nil, role: "staticText", label: label, value: nil,
                frame: .init(x: Double(index * 20), y: 100, width: 15, height: 20))
        }
        let timer = GoalNavigationSafety.visibleTimer(in: .init(captureID: .init(), elements: elements))
        XCTAssertEqual(timer?.text, "14:57")
        XCTAssertEqual(timer?.seconds, 897)
    }
    func testPaywallPurchaseAndSystemControlsAreNotCandidates() {
        let snapshot = UISnapshot(captureID: .init(), elements: [
            .init(identifier: nil, role: "staticText", label: "Premium plan", value: nil, frame: nil),
            .init(identifier: nil, role: "button", label: "Start Free Trial", value: nil, frame: nil, isEnabled: true, isHittable: true),
            .init(identifier: nil, role: "button", label: "Not Now", value: nil, frame: nil, isEnabled: true, isHittable: true),
            .init(identifier: nil, role: "button", label: "Allow", value: nil, frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "com.apple.springboard")
        ])
        XCTAssertEqual(GoalNavigationSafety.candidates(in: snapshot, appBundleID: "dev.fixture").map(\.label), ["Not Now"])
        let request = GoalNavigationRequest(goal: "Start a meditation", snapshot: snapshot, candidates: GoalNavigationSafety.candidates(in: snapshot, appBundleID: "dev.fixture"), recentActions: [])
        let invented = GoalNavigationDecision(captureID: snapshot.captureID, kind: .act, candidateID: "element-1", confidence: 1, reason: "buy")
        XCTAssertNil(GoalNavigationSafety.selectedElement(invented, request: request, snapshot: snapshot, appBundleID: "dev.fixture"))
    }
    func testOrdinaryPlanQuestionDoesNotHideRequestedPaywallEntry() {
        let snapshot = UISnapshot(captureID: .init(), elements: [
            .init(identifier: nil, role: "button",
                  label: "Create scenario, Premium, Practise any real situation: interviews, trips, landlords, doctors.",
                  value: nil, frame: nil, isEnabled: true, isHittable: true,
                  originBundleIdentifier: "dev.fixture"),
            .init(identifier: nil, role: "button",
                  label: "Daily Check-in, A warm 2-minute routine. How are you? What's your plan today?, ~2 min",
                  value: nil, frame: nil, isEnabled: true, isHittable: true,
                  originBundleIdentifier: "dev.fixture")
        ])
        XCTAssertFalse(GoalNavigationSafety.restrictedScreen(snapshot))
        let candidates = GoalNavigationSafety.candidates(in: snapshot, appBundleID: "dev.fixture")
        XCTAssertEqual(candidates.map(\.id), ["element-0", "element-1"])
    }
    func testUncertainModelChoiceCanAdvanceSafeQuestion() {
        let snapshot = UISnapshot(captureID: .init(), elements: [
            .init(identifier: nil, role: "staticText", label: "How much Spanish do you know?", value: nil,
                  frame: nil, originBundleIdentifier: "dev.fixture"),
            .init(identifier: "back", role: "button", label: "Back", value: nil,
                  frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture"),
            .init(identifier: "none", role: "button", label: "No Experience", value: nil,
                  frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture"),
            .init(identifier: "beginner", role: "button", label: "Beginner", value: nil,
                  frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture")
        ])
        let candidates = GoalNavigationSafety.candidates(in: snapshot, appBundleID: "dev.fixture")
        let request = GoalNavigationRequest(goal: "Complete onboarding", snapshot: snapshot,
            candidates: candidates, recentActions: [])
        let decision = GoalNavigationDecision(captureID: snapshot.captureID, kind: .act,
            candidateID: "element-3", confidence: 0.6, reason: "Beginner advances the question")
        XCTAssertEqual(GoalNavigationSafety.selectedElement(decision, request: request,
            snapshot: snapshot, appBundleID: "dev.fixture")?.label, "Beginner")
        XCTAssertEqual(GoalNavigationSafety.questionChoice(request, snapshot: snapshot,
            appBundleID: "dev.fixture")?.candidateID, "element-2")
    }
    func testQuestionFallbackDoesNotChooseOnRestrictedScreen() {
        let snapshot = UISnapshot(captureID: .init(), elements: [
            .init(identifier: nil, role: "staticText", label: "Which premium plan?", value: nil,
                  frame: nil, originBundleIdentifier: "dev.fixture"),
            .init(identifier: "purchase", role: "button", label: "Purchase monthly", value: nil,
                  frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture"),
            .init(identifier: "annual", role: "button", label: "Annual plan", value: nil,
                  frame: nil, isEnabled: true, isHittable: true, originBundleIdentifier: "dev.fixture")
        ])
        let request = GoalNavigationRequest(goal: "Complete onboarding", snapshot: snapshot,
            candidates: GoalNavigationSafety.candidates(in: snapshot, appBundleID: "dev.fixture"), recentActions: [])
        XCTAssertNil(GoalNavigationSafety.questionChoice(request, snapshot: snapshot, appBundleID: "dev.fixture"))
    }
    func testExpiredWallDeadlineDispatchesNoInput() async {
        let driver = NavigationDriver()
        let (events, continuation) = AsyncStream<ExecutionEvent>.makeStream()
        _ = events
        let clock = ExecutionClock()
        let context = ExecutionContext(driver: driver, events: continuation, clock: clock,
            control: ExecutionControl(clock: clock, events: continuation), bundleIdentifier: "dev.fixture")
        let test = project().categories[0].suites[0].tests[0]
        let outcome = await context.navigateGoal(test, navigator: NavigationChooser(), evaluator: NavigationEvaluator(), wallDeadline: Date().addingTimeInterval(-1))
        XCTAssertEqual(outcome, .failed)
        let actions = await driver.actions
        XCTAssertTrue(actions.isEmpty)
        continuation.finish()
    }
}
