import Foundation

public enum RunEventKind: String, Codable, Sendable {
    case runStarted
    case buildStarted
    case buildFinished
    case appInstalled
    case appLaunched
    case recordingStarted
    case captureCreated
    case candidatesCreated
    case candidateChosen
    case actionPerformed
    case assertionEvaluated
    case interruptionDetected
    case recordingStopped
    case runFinished
    case diagnostic
}

public struct RunEvent: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let timestamp: Date
    public let runID: UUID
    public let kind: RunEventKind
    public let message: String
    public let captureID: CaptureID?
    public let artifactRelativePath: String?

    public init(
        sequence: UInt64,
        timestamp: Date = Date(),
        runID: UUID,
        kind: RunEventKind,
        message: String,
        captureID: CaptureID? = nil,
        artifactRelativePath: String? = nil
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.runID = runID
        self.kind = kind
        self.message = message
        self.captureID = captureID
        self.artifactRelativePath = artifactRelativePath
    }
}
