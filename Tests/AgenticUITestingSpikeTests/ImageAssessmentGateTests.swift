import Foundation
import CoreGraphics
import ImageIO
import RunnerCore
import UniformTypeIdentifiers
import XCTest

private actor StubImageAssessor: ImageAssessing {
    nonisolated let providerID = "stub.remote"
    nonisolated let processingLocation: ImageProcessingLocation = .remote
    private var calls = 0
    func assess(_ request: ImageAssessmentRequest) async throws -> ImageAssessment {
        calls += 1
        return .init(captureID: request.capture.id, imageSHA256: request.imageSHA256,
            verdict: .satisfied, confidence: 0.9, reason: "Visible object", providerID: providerID,
            processingLocation: processingLocation, purpose: request.purpose)
    }
    func callCount() -> Int { calls }
}

private actor RoutingAssessor: ImageAssessing {
    nonisolated let providerID: String
    nonisolated let processingLocation: ImageProcessingLocation = .remote
    let verdict: ImageAssessment.Verdict
    let confidence: Double
    let failure: ImageAssessmentFailure?
    private var captures: [(CaptureID, String)] = []

    init(id: String, verdict: ImageAssessment.Verdict = .satisfied,
         confidence: Double = 0.9, failure: ImageAssessmentFailure? = nil) {
        providerID = id; self.verdict = verdict; self.confidence = confidence; self.failure = failure
    }
    func assess(_ request: ImageAssessmentRequest) async throws -> ImageAssessment {
        captures.append((request.capture.id, request.imageSHA256))
        if let failure { throw failure }
        return .init(captureID: request.capture.id, imageSHA256: request.imageSHA256,
            verdict: verdict, confidence: confidence, reason: "Fixture observation",
            providerID: providerID, processingLocation: processingLocation,
            purpose: request.purpose)
    }
    func observed() -> [(CaptureID, String)] { captures }
}

final class ImageAssessmentGateTests: XCTestCase {
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testRemoteProviderRequiresExplicitChoiceBeforeCall() async throws {
        let provider = StubImageAssessor()
        let capture = ScreenCapture(pixelSize: .init(width: 1, height: 1), screenshotRelativePath: "screen.png")
        let request = ImageAssessmentRequest(capture: capture, imageData: try png(),
            question: "Is the icon blue?", deadline: Date().addingTimeInterval(5))
        do {
            _ = try await ImageAssessmentGate().assess(request, with: provider, choice: .localOnly)
            XCTFail("Remote provider was called")
        } catch { XCTAssertEqual(error as? ImageAssessmentFailure, .remoteConsentRequired) }
        let callsBeforeOptIn = await provider.callCount()
        XCTAssertEqual(callsBeforeOptIn, 0)
        let response = try await ImageAssessmentGate().assess(request, with: provider, choice: .allowRemoteForThisRun)
        XCTAssertEqual(response.captureID, capture.id)
        let callsAfterOptIn = await provider.callCount()
        XCTAssertEqual(callsAfterOptIn, 1)
    }

    func testArchivedImageCanBeReadWithoutRefreshingItsCaptureTime() async throws {
        let provider = StubImageAssessor()
        let capture = ScreenCapture(createdAt: Date().addingTimeInterval(-3600),
            pixelSize: .init(width: 1, height: 1), screenshotRelativePath: "captures/old.png")
        let image = try png()
        let live = ImageAssessmentRequest(capture: capture, imageData: image,
            question: "Is the icon blue?", deadline: Date().addingTimeInterval(5))
        do {
            _ = try await ImageAssessmentGate().assess(live, with: provider,
                choice: .allowRemoteForThisRun)
            XCTFail("Stale image used for live action support")
        } catch { XCTAssertEqual(error as? ImageAssessmentFailure, .invalidRequest) }
        let archived = ImageAssessmentRequest(capture: capture, imageData: image,
            question: "Is the icon blue?", deadline: Date().addingTimeInterval(5),
            purpose: .archivedReadOnly)
        let response = try await ImageAssessmentGate().assess(archived, with: provider,
            choice: .allowRemoteForThisRun)
        XCTAssertEqual(response.purpose, .archivedReadOnly)
        XCTAssertEqual(response.captureID, capture.id)
    }

    func testRouterUsesClefResultWithoutSendingImageToClaude() async throws {
        let clef = RoutingAssessor(id: "clef", confidence: 0.72)
        let claude = RoutingAssessor(id: "claude")
        let request = ImageAssessmentRequest(capture: ScreenCapture(pixelSize: .init(width: 1, height: 1),
            screenshotRelativePath: "screen.png"), imageData: try png(),
            question: "Does this screenshot show success?", deadline: Date().addingTimeInterval(5))
        let response = try await ImageAssessmentRouter(primary: clef, fallback: claude,
            primaryMinimumConfidence: 0.4, fallbackMinimumConfidence: 0.8)
            .assess(request, choice: .allowRemoteForThisRun)
        XCTAssertEqual(response.providerID, "clef")
        let clefCalls = await clef.observed().count
        let claudeCalls = await claude.observed().count
        XCTAssertEqual(clefCalls, 1)
        XCTAssertEqual(claudeCalls, 0)
    }

    func testRouterEscalatesLowConfidenceOnSameCapture() async throws {
        let clef = RoutingAssessor(id: "clef", verdict: .notSatisfied, confidence: 0.3)
        let claude = RoutingAssessor(id: "claude", verdict: .satisfied, confidence: 0.9)
        let request = ImageAssessmentRequest(capture: ScreenCapture(pixelSize: .init(width: 1, height: 1),
            screenshotRelativePath: "screen.png"), imageData: try png(),
            question: "Does this screenshot show success?", deadline: Date().addingTimeInterval(5))
        let response = try await ImageAssessmentRouter(primary: clef, fallback: claude,
            primaryMinimumConfidence: 0.4, fallbackMinimumConfidence: 0.8)
            .assess(request, choice: .allowRemoteForThisRun)
        XCTAssertEqual(response.providerID, "claude")
        let first = await clef.observed()
        let second = await claude.observed()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(first.first?.0, second.first?.0)
        XCTAssertEqual(first.first?.1, second.first?.1)
    }

    func testRouterEscalatesInsufficientAndUnavailableAnswers() async throws {
        let request = ImageAssessmentRequest(capture: ScreenCapture(pixelSize: .init(width: 1, height: 1),
            screenshotRelativePath: "screen.png"), imageData: try png(),
            question: "Is the icon blue?", deadline: Date().addingTimeInterval(5))
        for primary in [
            RoutingAssessor(id: "clef", verdict: .insufficient, confidence: 0.6),
            RoutingAssessor(id: "clef", failure: .unavailable),
        ] {
            let claude = RoutingAssessor(id: "claude", confidence: 0.9)
            let response = try await ImageAssessmentRouter(primary: primary, fallback: claude,
                primaryMinimumConfidence: 0.4, fallbackMinimumConfidence: 0.8)
                .assess(request, choice: .allowRemoteForThisRun)
            XCTAssertEqual(response.providerID, "claude")
            let first = await primary.observed()
            let second = await claude.observed()
            XCTAssertEqual(first.first?.0, second.first?.0)
            XCTAssertEqual(first.first?.1, second.first?.1)
        }
    }

    func testRouterNeverCallsEitherRemoteProviderWithoutRunConsent() async throws {
        let clef = RoutingAssessor(id: "clef", confidence: 0.3)
        let claude = RoutingAssessor(id: "claude")
        let request = ImageAssessmentRequest(capture: ScreenCapture(pixelSize: .init(width: 1, height: 1),
            screenshotRelativePath: "screen.png"), imageData: try png(),
            question: "Does this screenshot show success?", deadline: Date().addingTimeInterval(5))
        do {
            _ = try await ImageAssessmentRouter(primary: clef, fallback: claude,
                primaryMinimumConfidence: 0.4, fallbackMinimumConfidence: 0.8)
                .assess(request, choice: .localOnly)
            XCTFail("Remote providers were called")
        } catch { XCTAssertEqual(error as? ImageAssessmentFailure, .remoteConsentRequired) }
        let clefCalls = await clef.observed().count
        let claudeCalls = await claude.observed().count
        XCTAssertEqual(clefCalls, 0)
        XCTAssertEqual(claudeCalls, 0)
    }
}
