import Foundation

public enum RunOutcome: String, Codable, Sendable {
    case passed
    case failed
    case blocked
    case needsReview
    case cancelled

    public var displayName: String {
        switch self {
        case .passed: "Passed"
        case .failed: "Failed"
        case .blocked: "Blocked"
        case .needsReview: "Needs review"
        case .cancelled: "Cancelled"
        }
    }
}

public struct UIElement: Hashable, Codable, Sendable {
    public let identifier: String?
    public let role: String
    public let label: String?
    public let value: String?
    public let frame: CGRectValue?
    // Missing metadata from older snapshots stays unknown and cannot authorize actions.
    public let isEnabled: Bool?
    public let isHittable: Bool?
    public let containingAlertIdentifier: String?
    public let containingAlertContext: String?
    public let buttonRole: String?
    public let originBundleIdentifier: String?

    public init(identifier: String?, role: String, label: String?, value: String?, frame: CGRectValue?,
                isEnabled: Bool? = nil, isHittable: Bool? = nil,
                containingAlertIdentifier: String? = nil, containingAlertContext: String? = nil,
                buttonRole: String? = nil, originBundleIdentifier: String? = nil) {
        self.identifier = identifier
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.isEnabled = isEnabled
        self.isHittable = isHittable
        self.containingAlertIdentifier = containingAlertIdentifier
        self.containingAlertContext = containingAlertContext
        self.buttonRole = buttonRole
        self.originBundleIdentifier = originBundleIdentifier
    }
}

public struct CGRectValue: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct UISnapshot: Hashable, Codable, Sendable {
    public let captureID: CaptureID
    public let capturedAt: Date
    public let elements: [UIElement]

    public init(captureID: CaptureID, capturedAt: Date = Date(), elements: [UIElement]) {
        self.captureID = captureID
        self.capturedAt = capturedAt
        self.elements = elements
    }
}

public protocol AccessibilityBridging: Sendable {
    func snapshot(boundTo captureID: CaptureID) async throws -> UISnapshot
    func tap(identifier: String) async throws
    func enterText(_ text: String, intoIdentifier identifier: String) async throws
}

public protocol CandidateChoosing: Sendable {
    func choose(from candidates: [ActionCandidate], context: String) async throws -> CandidateChoice
}

public protocol ScreenObserving: Sendable {
    func observe(capture: ScreenCapture, snapshot: UISnapshot?) async throws -> ScreenObservation
}

public struct ScreenObservation: Hashable, Codable, Sendable {
    public let captureID: CaptureID
    public let summary: String
    public let confidence: Double

    public init(captureID: CaptureID, summary: String, confidence: Double) {
        self.captureID = captureID
        self.summary = summary
        self.confidence = confidence
    }
}
