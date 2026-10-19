import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageProcessingLocation: String, Codable, Sendable {
    case onDevice, remote
}

/// The caller must obtain this choice from an explicit user setting before using a remote provider.
public enum ImageDisclosureChoice: String, Codable, Sendable {
    case localOnly, allowRemoteForThisRun
}

public enum ImageAssessmentPurpose: String, Codable, Sendable {
    case liveActionSupport
    case archivedReadOnly
}

public struct ImageAssessmentRequest: Sendable {
    public let capture: ScreenCapture
    public let imageData: Data
    public let question: String
    public let deadline: Date
    public let purpose: ImageAssessmentPurpose
    private var remoteTransferAuthorized = false

    public init(capture: ScreenCapture, imageData: Data, question: String, deadline: Date,
                purpose: ImageAssessmentPurpose = .liveActionSupport) {
        self.capture = capture; self.imageData = imageData; self.question = question
        self.deadline = deadline; self.purpose = purpose
    }

    public var imageSHA256: String {
        SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
    }
    public var permitsRemoteTransfer: Bool { remoteTransferAuthorized }
    func authorizingRemoteTransfer() -> Self {
        var approved = self
        approved.remoteTransferAuthorized = true
        return approved
    }
}

public struct ImageAssessment: Codable, Sendable {
    public enum Verdict: String, Codable, Sendable { case satisfied, notSatisfied, insufficient }
    public let captureID: CaptureID
    public let imageSHA256: String
    public let verdict: Verdict
    public let confidence: Double
    public let reason: String
    public let providerID: String
    public let processingLocation: ImageProcessingLocation
    public let purpose: ImageAssessmentPurpose
    public let rawResponse: String?

    public init(captureID: CaptureID, imageSHA256: String, verdict: Verdict,
                confidence: Double, reason: String, providerID: String,
                processingLocation: ImageProcessingLocation,
                purpose: ImageAssessmentPurpose = .liveActionSupport, rawResponse: String? = nil) {
        self.captureID = captureID; self.imageSHA256 = imageSHA256; self.verdict = verdict
        self.confidence = confidence; self.reason = reason; self.providerID = providerID
        self.processingLocation = processingLocation; self.purpose = purpose
        self.rawResponse = rawResponse
    }

    public func validate(for request: ImageAssessmentRequest, provider: any ImageAssessing,
                         minimumConfidence: Double, now: Date = Date()) throws {
        guard captureID == request.capture.id, imageSHA256 == request.imageSHA256,
              providerID == provider.providerID, processingLocation == provider.processingLocation,
              purpose == request.purpose,
              confidence.isFinite, (0...1).contains(confidence),
              minimumConfidence.isFinite, (0...1).contains(minimumConfidence),
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reason.count <= 4000,
              now.timeIntervalSince1970.isFinite, now < request.deadline,
              confidence >= minimumConfidence else { throw ImageAssessmentFailure.invalidResponse }
    }
}

public enum ImageAssessmentFailure: Error, Equatable, Sendable {
    case unavailable, remoteConsentRequired, invalidRequest, invalidResponse
}

public protocol ImageAssessing: Sendable {
    var providerID: String { get }
    var processingLocation: ImageProcessingLocation { get }
    func assess(_ request: ImageAssessmentRequest) async throws -> ImageAssessment
}

/// Central gate for an image model. Calling code must pass the user's run-level choice.
/// Pixel comparison does not use this boundary because it never sends image bytes to a model.
public struct ImageAssessmentGate: Sendable {
    public init() {}

    public func assess(_ request: ImageAssessmentRequest, with provider: any ImageAssessing,
                       choice: ImageDisclosureChoice, minimumConfidence: Double = 0.8) async throws -> ImageAssessment {
        guard provider.processingLocation != .remote || choice == .allowRemoteForThisRun else {
            throw ImageAssessmentFailure.remoteConsentRequired
        }
        let now = Date()
        guard !request.imageData.isEmpty, request.imageData.count <= 20_000_000,
              !request.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.question.count <= 8000,
              request.capture.createdAt.timeIntervalSince1970.isFinite,
              request.deadline.timeIntervalSince1970.isFinite,
              request.capture.createdAt <= now,
              (request.purpose == .archivedReadOnly ||
                  now.timeIntervalSince(request.capture.createdAt) < 8),
              now < request.deadline,
              minimumConfidence.isFinite, (0...1).contains(minimumConfidence) else {
            throw ImageAssessmentFailure.invalidRequest
        }
        guard let source = CGImageSourceCreateWithData(request.imageData as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == request.capture.pixelSize.width,
              image.height == request.capture.pixelSize.height else {
            throw ImageAssessmentFailure.invalidRequest
        }
        let approvedRequest = provider.processingLocation == .remote
            ? request.authorizingRemoteTransfer() : request
        let response = try await boundedProviderCall(deadline: request.deadline) {
            try await provider.assess(approvedRequest)
        }
        try response.validate(for: request, provider: provider, minimumConfidence: minimumConfidence)
        return response
    }
}

/// Uses one capture for both providers, escalating only when the first answer
/// is uncertain or fails local validation. Each provider is checked by the
/// same consent and capture-binding gate.
public struct ImageAssessmentRouter: Sendable {
    public let primary: any ImageAssessing
    public let fallback: (any ImageAssessing)?
    public let primaryMinimumConfidence: Double
    public let fallbackMinimumConfidence: Double

    public init(primary: any ImageAssessing, fallback: (any ImageAssessing)? = nil,
                primaryMinimumConfidence: Double, fallbackMinimumConfidence: Double) {
        self.primary = primary
        self.fallback = fallback
        self.primaryMinimumConfidence = primaryMinimumConfidence
        self.fallbackMinimumConfidence = fallbackMinimumConfidence
    }

    public func assess(_ request: ImageAssessmentRequest,
                       choice: ImageDisclosureChoice) async throws -> ImageAssessment {
        let gate = ImageAssessmentGate()
        var first: ImageAssessment?
        do {
            first = try await gate.assess(request, with: primary, choice: choice,
                minimumConfidence: primaryMinimumConfidence)
        } catch is CancellationError { throw CancellationError() }
        catch {
            switch error {
            case ImageAssessmentFailure.remoteConsentRequired, ImageAssessmentFailure.invalidRequest:
                throw error
            default:
                guard fallback != nil else { throw error }
            }
        }
        if let first, first.verdict != .insufficient { return first }
        guard let fallback else {
            if let first { return first }
            throw ImageAssessmentFailure.unavailable
        }
        do {
            return try await gate.assess(request, with: fallback, choice: choice,
                minimumConfidence: fallbackMinimumConfidence)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let first { return first }
            throw error
        }
    }
}
