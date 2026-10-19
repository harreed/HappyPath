import Foundation
import ProjectDomain

public enum GoalEvidenceMode: String, Codable, Sendable { case semanticText, ocrText, imageUnavailable, imageObserved }
public struct GoalEvidenceItem: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}
public struct GoalAssessmentRequest: Codable, Sendable {
    public let requestID: UUID
    public let goal: String
    public let successCriteria: String
    public let captureID: CaptureID
    public let capturedAt: Date
    public let requestedAt: Date
    public let deadline: Date
    public let mode: GoalEvidenceMode
    public let evidence: [GoalEvidenceItem]
    public init(requestID: UUID = UUID(), goal: String, successCriteria: String = "", snapshot: UISnapshot, deadline: Date, mode: GoalEvidenceMode = .semanticText, evidence: [GoalEvidenceItem]? = nil) {
        self.requestID = requestID; self.goal = goal; self.successCriteria = successCriteria
        captureID = snapshot.captureID; capturedAt = snapshot.capturedAt
        requestedAt = Date(); self.deadline = deadline; self.mode = mode
        self.evidence = evidence ?? snapshot.elements.enumerated().map { index, element in
            GoalEvidenceItem(id: "semantic-\(index)", text: "role=\(element.role); identifier=\(element.identifier ?? ""); label=\(element.label ?? ""); value=\(element.value ?? "")")
        }
    }
    private enum CodingKeys: String, CodingKey { case requestID, goal, successCriteria, captureID, capturedAt, requestedAt, deadline, mode, evidence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        goal = try c.decode(String.self, forKey: .goal)
        successCriteria = try c.decodeIfPresent(String.self, forKey: .successCriteria) ?? ""
        captureID = try c.decode(CaptureID.self, forKey: .captureID)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        requestedAt = try c.decode(Date.self, forKey: .requestedAt)
        deadline = try c.decode(Date.self, forKey: .deadline)
        mode = try c.decode(GoalEvidenceMode.self, forKey: .mode)
        evidence = try c.decode([GoalEvidenceItem].self, forKey: .evidence)
    }
}
public struct AssertionAssessment: Codable, Sendable {
    public enum Verdict: String, Codable, Sendable { case satisfied, notSatisfied, insufficient }
    public let requestID: UUID
    public let captureID: CaptureID
    public let verdict: Verdict
    public let requiresImage: Bool
    public let confidence: Double
    public let evidenceIDs: [String]
    public let reason: String
    public let rawResponse: String?
    public init(requestID: UUID, captureID: CaptureID, verdict: Verdict, requiresImage: Bool = false, confidence: Double, evidenceIDs: [String], reason: String, rawResponse: String? = nil) {
        self.requestID = requestID; self.captureID = captureID; self.verdict = verdict; self.requiresImage = requiresImage
        self.confidence = confidence; self.evidenceIDs = evidenceIDs; self.reason = reason; self.rawResponse = rawResponse
    }
}
public protocol AssertionEvaluating: Sendable {
    var providerID: String { get }
    func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment
}
public struct UnavailableAssertionEvaluator: AssertionEvaluating {
    public var providerID: String { "unavailable" }
    public init() {}
    public func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment { throw ProviderFailure.unavailable }
}
public enum ProviderFailure: LocalizedError, Sendable {
    case unavailable, busy, deadline, invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The model service is unavailable. Check Provider Settings."
        case .busy: "The model service is busy."
        case .deadline: "The model service did not respond before its deadline."
        case .invalidResponse: "The model service returned an invalid response."
        }
    }
}
public struct GoalAssessmentEvidence: Codable, Sendable {
    public let testID: UUID
    public let goal: String
    public let request: GoalAssessmentRequest?
    public let provider: String
    public let completedAt: Date
    public let assessment: AssertionAssessment?
    public let imageAssessment: ImageAssessment?
    public let minimumConfidence: Double
    public let invalidNumericValues: [String: String]?
    public let outcome: RunOutcome
    public let reason: String
    public init(testID: UUID, goal: String, request: GoalAssessmentRequest?, provider: String, assessment: AssertionAssessment?, minimumConfidence: Double, outcome: RunOutcome, reason: String, invalidNumericValues: [String: String]? = nil, imageAssessment: ImageAssessment? = nil) {
        self.testID = testID; self.goal = goal; self.request = request; self.provider = provider; self.assessment = assessment
        self.imageAssessment = imageAssessment
        completedAt = Date(); self.invalidNumericValues = invalidNumericValues; self.minimumConfidence = minimumConfidence; self.outcome = outcome; self.reason = reason
    }
    /// Read-only interpretation of immutable final evidence, never an action permit.
    public static func validate(_ response: AssertionAssessment, request: GoalAssessmentRequest, minimumConfidence: Double, now: Date = Date()) -> (RunOutcome, String) {
        guard [now, request.capturedAt, request.requestedAt, request.deadline].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              request.capturedAt <= request.requestedAt, request.requestedAt.timeIntervalSince(request.capturedAt) < 8,
              request.requestedAt <= now, now < request.deadline else { return (.needsReview, "Assessment evidence or response timing is invalid") }
        guard response.requestID == request.requestID, response.captureID == request.captureID else { return (.needsReview, "Assessment request/capture mismatch") }
        guard response.confidence.isFinite, (0...1).contains(response.confidence), minimumConfidence.isFinite, (0...1).contains(minimumConfidence) else { return (.needsReview, "Invalid assessment confidence") }
        guard request.mode != .imageUnavailable, request.mode != .imageObserved, !response.requiresImage else { return (.needsReview, "Screenshot model observation is unavailable; text is not image evidence") }
        let known = Set(request.evidence.map(\.id))
        guard known.count == request.evidence.count, Set(response.evidenceIDs).count == response.evidenceIDs.count,
              response.evidenceIDs.allSatisfy(known.contains) else { return (.needsReview, "Unknown or duplicate assessment evidence reference") }
        guard response.verdict != .insufficient, !response.evidenceIDs.isEmpty, !response.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (.needsReview, "Insufficient cited evidence for final goal") }
        guard response.confidence >= minimumConfidence else { return (.needsReview, "Assessment confidence below local threshold") }
        return (response.verdict == .satisfied ? .passed : .failed, response.reason)
    }
}
public struct FailureSummaryRequest: Codable, Sendable {
    public let testID: UUID
    public let outcome: RunOutcome
    public let reason: String
    public let assessmentRequestID: UUID?
    public init(testID: UUID, outcome: RunOutcome, reason: String, assessmentRequestID: UUID?) { self.testID = testID; self.outcome = outcome; self.reason = reason; self.assessmentRequestID = assessmentRequestID }
}
public struct FailureSummaryEvidence: Codable, Sendable {
    public let source: FailureSummaryRequest
    public let provider: String
    public let text: String
    public let rawResponse: String?
    public init(source: FailureSummaryRequest, provider: String, text: String, rawResponse: String? = nil) { self.source = source; self.provider = provider; self.text = text; self.rawResponse = rawResponse }
}
public protocol FailureSummarising: Sendable {
    func summarise(_ request: FailureSummaryRequest) async throws -> FailureSummaryEvidence
}
public struct RecordedFailureSummariser: FailureSummarising {
    public init() {}
    public func summarise(_ request: FailureSummaryRequest) async throws -> FailureSummaryEvidence {
        .init(source: request, provider: "local.recorded-evidence", text: "\(request.outcome.rawValue): \(request.reason)")
    }
}

/// Races immutable provider work without making cancellation wait for an uncooperative API.
/// Provider implementations must independently limit their active workers.
public func boundedProviderCall<T: Sendable>(deadline: Date, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = ProviderRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.start(continuation, deadline: deadline, operation: operation)
        }
    } onCancel: { race.finish(.failure(CancellationError())) }
}
private final class ProviderRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []
    func start(_ c: CheckedContinuation<T, Error>, deadline: Date, operation: @escaping @Sendable () async throws -> T) {
        lock.lock()
        if let result { lock.unlock(); c.resume(with: result); return }
        continuation = c
        tasks = [Task { do { self.finish(.success(try await operation())) } catch { self.finish(.failure(error)) } }, Task {
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))); self.finish(.failure(ProviderFailure.deadline)) } catch {}
        }]
        lock.unlock()
    }
    func finish(_ value: Result<T, Error>) {
        lock.lock(); guard result == nil else { lock.unlock(); return }; result = value
        let c = continuation; continuation = nil; let pending = tasks; tasks = []; lock.unlock()
        pending.forEach { $0.cancel() }; c?.resume(with: value)
    }
}
