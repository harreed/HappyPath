import Foundation
import ProjectDomain

public enum InterruptionKind: String, Codable, Sendable {
    case none, knownReminder, alert, permissionPrompt, optionalNotificationPrompt, keyboard, firstRunSheet, offline, authenticationExpired, authenticationRequired, transient, applicationUnavailable, unresolvedStep
}
public struct InterruptionObservation: Codable, Sendable, Equatable {
    public let kind: InterruptionKind
    public let reason: String
    public let policyID: String?
    public let elements: [UIElement]
}

/// Signal recognition is separate from permission to mutate. App-owned alerts
/// still require a reviewed policy; SpringBoard prompts use a bound button.
public enum InterruptionLibrary {
    public static let reminderPolicy = "fixture.optional-reminder.v1"
    public static func recognize(_ snapshot: UISnapshot) -> InterruptionObservation {
        let elements = snapshot.elements
        let alerts = elements.filter { $0.role == "alert" || $0.containingAlertContext != nil }
        let text = elements.compactMap { $0.label }.joined(separator: " ").lowercased()
        func observed(_ kind: InterruptionKind, _ reason: String, _ nodes: [UIElement] = [], policy: String? = nil) -> InterruptionObservation {
            .init(kind: kind, reason: reason, policyID: policy, elements: nodes)
        }
        if !alerts.isEmpty {
            let systemAlerts = alerts.filter { $0.originBundleIdentifier == "com.apple.springboard" }
            if !systemAlerts.isEmpty {
                let systemText = (systemAlerts.compactMap(\.label) + systemAlerts.compactMap(\.containingAlertContext)).joined(separator: " ").lowercased()
                // Apple Account prompts have no affirmative button that can be
                // completed here, so their automatic action is a dismissal.
                let normalizedSystemText = TargetTextMatching.normalize(systemText)
                if normalizedSystemText.contains("sign in to your apple account") ||
                    (normalizedSystemText.contains("apple account verification") && normalizedSystemText.contains("enter the password for") && normalizedSystemText.contains("in settings")) {
                    return observed(.authenticationRequired, "System Apple Account sign-in prompt", systemAlerts)
                }
                if normalizedSystemText.contains("would like to send you notifications") &&
                    normalizedSystemText.contains("notifications may include alerts, sounds and icon badges") {
                    return observed(.optionalNotificationPrompt, "System notification request", systemAlerts)
                }
                let permission = systemText.contains("would like") || systemText.contains("allow") || systemText.contains("permission")
                return observed(permission ? .permissionPrompt : .alert, "SpringBoard alert", systemAlerts)
            }
            let contexts = Set(alerts.compactMap(\.containingAlertContext))
            let reminder = contexts.count == 1 && contexts.first?.contains("Try reminders?") == true && contexts.first?.contains("This optional interruption is injected by the fixture.") == true
            if reminder { return observed(.knownReminder, "Observed optional fixture reminder context", alerts, policy: reminderPolicy) }
            if text.contains("would like to") || text.contains("allow access") { return observed(.permissionPrompt, "Permission wording in an observed alert; no grant/deny policy", alerts) }
            return observed(.alert, "Unrecognized alert; no reviewed dismissal policy", alerts)
        }
        if elements.contains(where: { $0.role == "application" && ($0.label == "SpringBoard" || $0.identifier == "com.apple.springboard") }) {
            return observed(.applicationUnavailable, "SpringBoard application identity observed", elements.filter { $0.role == "application" })
        }
        if text.contains("session expired") || text.contains("sign in again") { return observed(.authenticationExpired, "Explicit session-expiry wording; reauthentication requires review", elements.filter { $0.label?.lowercased().contains("session expired") == true || $0.label?.lowercased().contains("sign in again") == true }) }
        if text.contains("offline") || text.contains("no internet connection") { return observed(.offline, "Explicit offline wording; reconnect/retry has no reviewed handler", elements.filter { $0.label?.lowercased().contains("offline") == true || $0.label?.lowercased().contains("no internet connection") == true }) }
        if elements.contains(where: { $0.role == "sheet" }) { return observed(.firstRunSheet, "Sheet observed; first-run intent is unconfirmed and requires review", elements.filter { $0.role == "sheet" }) }
        if elements.contains(where: { $0.role == "activityIndicator" || $0.role == "progressIndicator" }) { return observed(.transient, "Progress indicator observed; bounded wait only", elements.filter { $0.role == "activityIndicator" || $0.role == "progressIndicator" }) }
        if elements.contains(where: { $0.role == "keyboard" }) { return observed(.keyboard, "Keyboard observed; obstruction must be established by unresolved target", elements.filter { $0.role == "keyboard" }) }
        return observed(.none, "No supported interruption signal")
    }
    public static func exactPolicy(_ observation: InterruptionObservation, policies: [ReviewedAlertPolicy], bundleIdentifier: String) -> ReviewedAlertPolicy? {
        let matches = policies.filter { policy in
            let nodes = observation.elements
            guard policy.bundleIdentifier == bundleIdentifier, !nodes.isEmpty,
                  nodes.allSatisfy({ $0.originBundleIdentifier == nil || $0.originBundleIdentifier == bundleIdentifier }),
                  Set(nodes.compactMap(\.containingAlertIdentifier)) == [policy.alertIdentifier],
                  Set(nodes.compactMap(\.containingAlertContext)) == [policy.exactContext] else { return false }
            let buttons = nodes.filter { $0.role == "button" }
            return buttons.count == policy.buttons.count && policy.buttons.allSatisfy { reviewed in
                buttons.filter { $0.identifier == reviewed.identifier && $0.label == reviewed.label && $0.buttonRole != "destructive" }.count == 1
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Narrow dismiss-only allowlist for system auth dialogs. Only an exact
    /// `Close` (tolerant case/whitespace) qualifies. `Settings`, `Allow`,
    /// `Sign In`, `Continue` and anything else never qualify — tapping them
    /// would leave the app or grant/deny.
    public static func isSystemDismissButton(_ element: UIElement) -> Bool {
        guard element.role == "button",
              element.originBundleIdentifier == "com.apple.springboard",
              element.buttonRole != "destructive" else { return false }
        return TargetTextMatching.equals(element.label, "Close") || TargetTextMatching.equals(element.label, "Not Now") || TargetTextMatching.equals(element.label, "Don't Allow") || TargetTextMatching.equals(element.label, "Don’t Allow")
    }

    /// Unique safe Close candidate for an authenticationRequired observation.
    /// Returns nil when ambiguous, missing, disabled or not hittable.
    public static func uniqueSystemDismiss(_ observation: InterruptionObservation) -> UIElement? {
        guard observation.kind == .authenticationRequired || observation.kind == .optionalNotificationPrompt else { return nil }
        let buttons = observation.elements.filter { $0.role == "button" }
        let safe = buttons.filter { button in
            guard isSystemDismissButton(button), button.isEnabled == true, button.isHittable == true else { return false }
            if observation.kind == .optionalNotificationPrompt {
                return TargetTextMatching.equals(button.label, "Don't Allow") || TargetTextMatching.equals(button.label, "Don’t Allow")
            }
            return TargetTextMatching.equals(button.label, "Close") || TargetTextMatching.equals(button.label, "Not Now")
        }
        guard safe.count == 1 else { return nil }
        return safe[0]
    }

    /// Select one enabled, visible button from one observed SpringBoard alert.
    /// Prefer the broadest affirmative permission when iOS offers levels.
    /// A single remaining non-denial choice also qualifies; ties remain unresolved.
    public static func systemPromptChoice(_ observation: InterruptionObservation) -> UIElement? {
        let nodes = observation.elements
        guard !nodes.isEmpty, nodes.allSatisfy({ $0.originBundleIdentifier == "com.apple.springboard" }),
              Set(nodes.compactMap(\.containingAlertIdentifier)).count == 1,
              Set(nodes.compactMap(\.containingAlertContext)).count == 1 else { return nil }
        let buttons = nodes.filter { $0.role == "button" && $0.isEnabled == true && $0.isHittable == true && $0.buttonRole != "destructive" }
        let ranked = buttons.compactMap { button -> (UIElement, Int)? in
            guard let label = button.label else { return nil }
            let name = TargetTextMatching.normalize(label)
            let rank: Int?
            if observation.kind == .authenticationRequired {
                rank = ["close", "not now"].contains(name) ? 1 : nil
            } else {
                switch name {
                case "always allow", "allow always", "allow full access": rank = 10
                case "allow while using app", "allow while using the app": rank = 9
                case "allow once": rank = 8
                case "allow", "allow access", "allow all", "allow notifications": rank = 7
                case "ok", "okay", "continue", "enable", "turn on", "accept", "agree", "yes", "confirm": rank = 6
                default:
                    let excluded = ["don't allow", "don’t allow", "deny", "cancel", "not now", "later", "close", "no", "settings", "open settings", "learn more", "more info"]
                    let destructive = ["delete", "erase", "buy", "purchase", "pay"]
                    if excluded.contains(name) || destructive.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) {
                        rank = nil
                    } else if name.hasPrefix("allow ") {
                        rank = 7
                    } else if name.hasPrefix("enable ") || name.hasPrefix("accept ") || name.hasPrefix("continue ") {
                        rank = 6
                    } else {
                        rank = 1
                    }
                }
            }
            return rank.map { (button, $0) }
        }
        guard let highest = ranked.map(\.1).max() else { return nil }
        let best = ranked.filter { $0.1 == highest }
        return best.count == 1 ? best[0].0 : nil
    }

}
public struct RecoveryEvidence: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case proposed, dispatched, verified, refused, recapture, waiting }
    /// What authorized this recovery: a reviewed interruption policy, a safe
    /// dismissal escape, or an unambiguous progress control.
    public enum Origin: String, Codable, Sendable { case interruption, escape, progress }
    public let origin: Origin?
    public let blockID: UUID
    public let captureID: CaptureID
    public let geometry: PerceptionGeometry?
    public let interruption: InterruptionObservation
    public let candidates: [ActionCandidate]
    public let choice: CandidateChoice?
    public let provider: String
    public let status: Status
    public let reason: String
    public let actionCount: Int
    public let maximumActions: Int
    public let recoveryStartedAt: Date
    public let deadline: Date
    public let minimumConfidence: Double
    public let maximumCaptureAge: Double
    public let recaptureCount: Int
    public let verificationCaptureID: CaptureID?
    init(origin: Origin? = nil, blockID: UUID, captureID: CaptureID, geometry: PerceptionGeometry?, interruption: InterruptionObservation,
         candidates: [ActionCandidate], choice: CandidateChoice?, provider: String, status: Status, reason: String,
         actionCount: Int, maximumActions: Int, recoveryStartedAt: Date, deadline: Date, minimumConfidence: Double,
         maximumCaptureAge: Double, recaptureCount: Int, verificationCaptureID: CaptureID?) {
        self.origin = origin
        self.blockID = blockID; self.captureID = captureID; self.geometry = geometry; self.interruption = interruption
        self.candidates = candidates; self.choice = choice; self.provider = provider; self.status = status; self.reason = reason
        self.actionCount = actionCount; self.maximumActions = maximumActions; self.recoveryStartedAt = recoveryStartedAt
        self.deadline = deadline; self.minimumConfidence = minimumConfidence; self.maximumCaptureAge = maximumCaptureAge
        self.recaptureCount = recaptureCount; self.verificationCaptureID = verificationCaptureID
    }
}
public struct PerceptionWarmup: Codable, Sendable {
    public let startedAt: Date
    public let completedAt: Date
    public let milliseconds: Double
    public init(startedAt: Date, completedAt: Date, milliseconds: Double) { self.startedAt = startedAt; self.completedAt = completedAt; self.milliseconds = milliseconds }
}

/// State survives target retries and blocks, but never leaks between tests.
actor RecoveryBudget {
    var actionCount = 0
    var recaptureCount = 0
    var startedAt: Date?
    var escapeCount = 0
    var escapeStartedAt: Date?
    private var refusalBlocks: Set<UUID> = []
    func begin(now: Date) -> Date { if startedAt == nil { startedAt = now }; return startedAt! }
    func finishInterruption() { startedAt = nil }
    func consumeAction() { actionCount += 1 }
    func consumeRecapture() { recaptureCount += 1 }
    func beginEscape(now: Date) -> Date { if escapeStartedAt == nil { escapeStartedAt = now }; return escapeStartedAt! }
    func consumeEscape() { escapeCount += 1 }
    /// A refused escape is recorded once per block so polling waits stay quiet.
    func shouldRecordRefusal(blockID: UUID) -> Bool { refusalBlocks.insert(blockID).inserted }
}
