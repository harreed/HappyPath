import Foundation

public struct CandidateDecisionEvidence: Hashable, Codable, Sendable {
    public let requestID: UUID
    public let captureID: CaptureID
    public let provider: String
    public let optionIDs: [String]
    public let selectedID: String?
    public let probabilities: [String: Double]?
    public let confidence: Double?
    public let reason: String
    /// Structurally valid provider selection only; local policy/confidence/freshness still govern action.
    public let accepted: Bool
    public let invalidNumericValues: [String: String]?
    public let responseCaptureID: CaptureID?
    public let originalAccepted: Bool?
    public init(requestID: UUID, captureID: CaptureID, provider: String = "jev", optionIDs: [String], selectedID: String?, probabilities: [String: Double]?, confidence: Double?, reason: String, accepted: Bool, responseCaptureID: CaptureID? = nil, originalAccepted: Bool? = nil, invalidNumericValues: [String: String]? = nil) {
        var invalid: [String: String] = invalidNumericValues ?? [:]
        self.originalAccepted = originalAccepted
        for (key, value) in probabilities ?? [:] where !value.isFinite { invalid["probabilities." + key] = String(value) }
        if let confidence, !confidence.isFinite { invalid["confidence"] = String(confidence) }
        self.invalidNumericValues = invalid.isEmpty ? nil : invalid; self.responseCaptureID = responseCaptureID
        self.requestID = requestID; self.captureID = captureID; self.provider = provider; self.optionIDs = optionIDs; self.selectedID = selectedID
        self.probabilities = probabilities?.filter { $0.value.isFinite }; self.confidence = confidence.flatMap { $0.isFinite ? $0 : nil }; self.reason = reason; self.accepted = accepted
    }
}
public struct CandidateProviderRefusal: Error, Sendable {
    public let evidence: CandidateDecisionEvidence
    public init(_ evidence: CandidateDecisionEvidence) { self.evidence = evidence }
}

/// Recorded whenever hosted candidate choice was requested but the locally
/// reviewed choice was used instead. The fallback is evidence, never a silent swap.
public struct ProviderFallbackEvidence: Codable, Sendable, Equatable {
    public let provider: String
    public let reason: String
    public let fallback: String
    public let captureID: CaptureID
    public let blockID: UUID
    public init(provider: String = "jev", reason: String, fallback: String = "local.reviewed-policy", captureID: CaptureID, blockID: UUID) {
        self.provider = provider; self.reason = reason; self.fallback = fallback
        self.captureID = captureID; self.blockID = blockID
    }
    public var summary: String { "\(provider) unavailable — using \(fallback): \(reason)" }
}
