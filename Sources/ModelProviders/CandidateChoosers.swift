import Foundation
import RunnerCore

public enum CandidateChooserError: Error, Equatable {
    case duplicateCandidateIDs
    case mixedCaptures
    case noSafeCandidates
    case staleResponse
    case unknownCandidate(UUID)
    case invalidConfidence(Double)
    case invalidDistribution
}

/// Predictable local chooser for development and deterministic recovery rules.
public struct DeterministicCandidateChooser: CandidateChoosing {
    public init() {}

    public func choose(from candidates: [ActionCandidate], context: String) async throws -> CandidateChoice {
        try validateCandidateSet(candidates)
        guard let candidate = candidates.first(where: { $0.isSafeForAutomaticExecution }) else {
            throw CandidateChooserError.noSafeCandidates
        }
        return CandidateChoice(
            candidateID: candidate.id,
            captureID: candidate.captureID,
            confidence: 1,
            rationale: "First locally allowlisted candidate"
        )
    }
}

public struct CandidateDecisionRequest: Codable, Sendable, Equatable {
    public struct Option: Codable, Sendable, Equatable {
        public let id: UUID
        public let title: String
    }

    public let requestID: UUID
    public let captureID: CaptureID
    public let context: String
    public let options: [Option]
    public init(requestID: UUID = UUID(), captureID: CaptureID, context: String, options: [Option]) { self.requestID = requestID; self.captureID = captureID; self.context = context; self.options = options }
}

public struct CandidateDecisionResponse: Codable, Sendable, Equatable {
    public let captureID: CaptureID
    public let candidateID: UUID
    public let confidence: Double
    public let rationale: String?
    public let probabilities: [String: Double]?
    public let abstained: Bool

    public init(captureID: CaptureID, candidateID: UUID, confidence: Double, rationale: String? = nil, probabilities: [String: Double]? = nil, abstained: Bool = false) {
        self.captureID = captureID
        self.candidateID = candidateID
        self.confidence = confidence
        self.rationale = rationale
        self.probabilities = probabilities; self.abstained = abstained
    }
}

/// Boundary for a Jev SDK/HTTP implementation. Authentication stays in the host app.
public protocol JevDecisionTransport: Sendable {
    func decide(_ request: CandidateDecisionRequest) async throws -> CandidateDecisionResponse
}

/// Sends only labels and opaque IDs, then validates Jev's typed response locally.
public struct JevCandidateChooser<Transport: JevDecisionTransport>: CandidateChoosing {
    private let transport: Transport

    public init(transport: Transport) {
        self.transport = transport
    }

    public func choose(from candidates: [ActionCandidate], context: String) async throws -> CandidateChoice {
        try validateCandidateSet(candidates)
        guard let captureID = candidates.first?.captureID,
              candidates.allSatisfy({ $0.captureID == captureID }) else {
            throw CandidateChooserError.noSafeCandidates
        }
        let safeCandidates = candidates.filter(\.isSafeForAutomaticExecution)
        guard !safeCandidates.isEmpty else { throw CandidateChooserError.noSafeCandidates }

        let request = CandidateDecisionRequest(
            captureID: captureID,
            context: context,
            options: safeCandidates.map { .init(id: $0.id, title: $0.title) }
        )
        let response = try await transport.decide(request)
        let optionIDs = safeCandidates.map { $0.id.uuidString } + ["abstain"]
        let selected = response.abstained ? "abstain" : response.candidateID.uuidString
        func refusal(_ reason: String) -> CandidateProviderRefusal { .init(.init(requestID: request.requestID, captureID: captureID, optionIDs: optionIDs, selectedID: selected, probabilities: response.probabilities, confidence: response.confidence, reason: reason, accepted: false, responseCaptureID: response.captureID)) }
        guard response.captureID == captureID else { throw refusal("Provider response capture mismatch") }
        guard response.abstained || safeCandidates.contains(where: { $0.id == response.candidateID }) else { throw refusal("Unknown provider candidate ID") }
        guard response.confidence.isFinite, (0...1).contains(response.confidence) else { throw refusal("Invalid provider confidence") }
        let probabilities = response.probabilities ?? [:]
        let valid = Set(probabilities.keys) == Set(optionIDs) && probabilities.values.allSatisfy { $0.isFinite && (0...1).contains($0) } && abs(probabilities.values.reduce(0, +) - 1) <= 0.001 && probabilities[selected] == probabilities.values.max() && probabilities.values.filter { $0 == probabilities.values.max() }.count == 1
        let evidence = CandidateDecisionEvidence(requestID: request.requestID, captureID: captureID, optionIDs: optionIDs, selectedID: selected, probabilities: response.probabilities, confidence: response.confidence, reason: !valid ? "Invalid provider probability distribution" : response.abstained ? "Provider abstained; no action permitted" : "Host bound the response to its originating request; concentration is not a safety guarantee", accepted: valid && !response.abstained)
        guard valid, !response.abstained else { throw CandidateProviderRefusal(evidence) }
        return CandidateChoice(
            candidateID: response.candidateID,
            captureID: response.captureID,
            confidence: response.confidence,
            rationale: evidence.reason, providerEvidence: evidence
        )
    }
}

private func validateCandidateSet(_ candidates: [ActionCandidate]) throws {
    guard Set(candidates.map(\.id)).count == candidates.count else {
        throw CandidateChooserError.duplicateCandidateIDs
    }
    if let captureID = candidates.first?.captureID,
       !candidates.allSatisfy({ $0.captureID == captureID }) {
        throw CandidateChooserError.mixedCaptures
    }
}

/// An app-specific reviewed dismissal, including the alert context and button semantics.
public struct KnownAlertDismissal: Hashable, Sendable {
    public let alertIdentifier: String
    public let alertContext: String
    public let buttonIdentifier: String
    public let buttonLabel: String
    public let buttonRole: String

    public init(alertIdentifier: String, alertContext: String, buttonIdentifier: String,
                buttonLabel: String, buttonRole: String) {
        self.alertIdentifier = alertIdentifier
        self.alertContext = alertContext
        self.buttonIdentifier = buttonIdentifier
        self.buttonLabel = buttonLabel
        self.buttonRole = buttonRole
    }
}

public enum InterruptionCandidateFactory {
    /// Unknown alerts and incomplete legacy snapshots fail closed. Policies are explicit opt-in.
    public static func safeDismissCandidates(from snapshot: UISnapshot,
                                              policies: [KnownAlertDismissal] = []) -> [ActionCandidate] {
        snapshot.elements.compactMap { element in
            guard let identifier = element.identifier, !identifier.isEmpty,
                  let label = element.label,
                  element.role == "button", element.isEnabled == true, element.isHittable == true,
                  element.buttonRole != "destructive",
                  snapshot.elements.filter({ $0.identifier == identifier }).count == 1,
                  policies.contains(where: {
                      !$0.alertIdentifier.isEmpty && !$0.alertContext.isEmpty &&
                      $0.alertIdentifier == element.containingAlertIdentifier &&
                      $0.alertContext == element.containingAlertContext &&
                      $0.buttonIdentifier == identifier && $0.buttonLabel == label &&
                      $0.buttonRole == element.buttonRole
                  }) else { return nil }
            return ActionCandidate(captureID: snapshot.captureID, title: "Tap \(label)",
                action: .tapAccessibilityIdentifier(identifier), isSafeForAutomaticExecution: true)
        }
    }
}
