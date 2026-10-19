import Foundation

public struct CaptureID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public struct PixelPoint: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct PixelSize: Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
    }
}

public struct ScreenCapture: Hashable, Codable, Sendable {
    public let id: CaptureID
    public let createdAt: Date
    public let pixelSize: PixelSize
    public let screenshotRelativePath: String

    public init(
        id: CaptureID = CaptureID(),
        createdAt: Date = Date(),
        pixelSize: PixelSize,
        screenshotRelativePath: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pixelSize = pixelSize
        self.screenshotRelativePath = screenshotRelativePath
    }
}

public enum CandidateAction: Hashable, Codable, Sendable {
    case tapAccessibilityIdentifier(String)
    case tapAlertButton(UIElement)
    case tapElement(UIElement)
    case tapPoint(PixelPoint)
    case dismiss
    case wait(milliseconds: Int)
    case fail(reason: String)
}

public struct ActionCandidate: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let captureID: CaptureID
    public let title: String
    public let action: CandidateAction
    public let isSafeForAutomaticExecution: Bool

    public init(
        id: UUID = UUID(),
        captureID: CaptureID,
        title: String,
        action: CandidateAction,
        isSafeForAutomaticExecution: Bool
    ) {
        self.id = id
        self.captureID = captureID
        self.title = title
        self.action = action
        self.isSafeForAutomaticExecution = isSafeForAutomaticExecution
    }
}

public struct CandidateChoice: Hashable, Codable, Sendable {
    public let candidateID: UUID
    public let captureID: CaptureID
    public let confidence: Double
    public let rationale: String?
    public let providerEvidence: CandidateDecisionEvidence?

    public init(candidateID: UUID, captureID: CaptureID, confidence: Double, rationale: String? = nil, providerEvidence: CandidateDecisionEvidence? = nil) {
        self.candidateID = candidateID
        self.captureID = captureID
        self.confidence = confidence
        self.rationale = rationale
        self.providerEvidence = providerEvidence
    }
}

public enum CaptureActionGateError: Error, Equatable {
    case captureReactivation(CaptureID)
    case invalidConfidence
    case invalidThreshold
    case duplicateCandidateIDs
    case noActiveCapture
    case staleCapture(expected: CaptureID, received: CaptureID)
    case captureAlreadyConsumed(CaptureID)
    case unknownCandidate(UUID)
    case candidateCaptureMismatch
    case unsafeCandidate
    case confidenceBelowThreshold(required: Double, received: Double)
}

/// Atomically enforces one action for one immutable capture.
public actor CaptureActionGate {
    private var activeCaptureID: CaptureID?
    private var activatedCaptureIDs: Set<CaptureID> = []
    private var consumedCaptureIDs: Set<CaptureID> = []

    public init() {}

    public func activate(_ captureID: CaptureID) throws {
        guard activatedCaptureIDs.insert(captureID).inserted else {
            throw CaptureActionGateError.captureReactivation(captureID)
        }
        activeCaptureID = captureID
    }

    public func validateAndConsume(
        choice: CandidateChoice,
        candidates: [ActionCandidate],
        minimumConfidence: Double
    ) throws -> ActionCandidate {
        guard let activeCaptureID else {
            throw CaptureActionGateError.noActiveCapture
        }
        guard choice.captureID == activeCaptureID else {
            throw CaptureActionGateError.staleCapture(expected: activeCaptureID, received: choice.captureID)
        }
        guard !consumedCaptureIDs.contains(activeCaptureID) else {
            throw CaptureActionGateError.captureAlreadyConsumed(activeCaptureID)
        }
        guard minimumConfidence.isFinite, (0...1).contains(minimumConfidence) else {
            throw CaptureActionGateError.invalidThreshold
        }
        guard choice.confidence.isFinite, (0...1).contains(choice.confidence) else {
            throw CaptureActionGateError.invalidConfidence
        }
        guard Set(candidates.map(\.id)).count == candidates.count else {
            throw CaptureActionGateError.duplicateCandidateIDs
        }
        guard candidates.allSatisfy({ $0.captureID == activeCaptureID }) else {
            throw CaptureActionGateError.candidateCaptureMismatch
        }
        guard let candidate = candidates.first(where: { $0.id == choice.candidateID }) else {
            throw CaptureActionGateError.unknownCandidate(choice.candidateID)
        }
        guard candidate.captureID == activeCaptureID else {
            throw CaptureActionGateError.candidateCaptureMismatch
        }
        guard candidate.isSafeForAutomaticExecution else {
            throw CaptureActionGateError.unsafeCandidate
        }
        guard choice.confidence >= minimumConfidence else {
            throw CaptureActionGateError.confidenceBelowThreshold(
                required: minimumConfidence,
                received: choice.confidence
            )
        }

        consumedCaptureIDs.insert(activeCaptureID)
        return candidate
    }
}
