import CoreGraphics
import Foundation
import ImageIO
@testable import ModelProviders
import RunnerCore
import UniformTypeIdentifiers
import XCTest

private actor JevVisionStub: JevHTTPClient {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let questions = (try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])?["questions"] as! [String: Any]
        var answers: [String: [String: Any]] = [:]
        for name in questions.keys {
            answers[name] = ["type": "choice", "choice": name == "goal" ? "notSatisfied" : "blocked", "confidence": 0.91]
        }
        return (try JSONSerialization.data(withJSONObject: ["answers": answers]), 200)
    }
    func captured() -> [URLRequest] { requests }
}

final class JevVisionProviderTests: XCTestCase {
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    func testRemoteImageRequiresRunApprovalAndBindsCapture() async throws {
        let stub = JevVisionStub()
        let provider = JevVisionProvider(apiKey: "test-key", client: stub)
        let input = ImageAssessmentRequest(capture: .init(pixelSize: .init(width: 2, height: 2),
            screenshotRelativePath: "captures/test.png"), imageData: try png(),
            question: "Has the goal been reached?", deadline: Date().addingTimeInterval(10))
        do {
            _ = try await ImageAssessmentGate().assess(input, with: provider, choice: .localOnly)
            XCTFail("A screenshot was sent without approval")
        } catch { XCTAssertEqual(error as? ImageAssessmentFailure, .remoteConsentRequired) }
        let beforeApproval = await stub.captured()
        XCTAssertTrue(beforeApproval.isEmpty)

        let result = try await ImageAssessmentGate().assess(input, with: provider,
            choice: .allowRemoteForThisRun, minimumConfidence: 0.4)
        XCTAssertEqual(result.captureID, input.capture.id)
        XCTAssertEqual(result.imageSHA256, input.imageSHA256)
        XCTAssertEqual(result.verdict, .notSatisfied)
        let captured = await stub.captured()
        let sent = try XCTUnwrap(captured.first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"), "true")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "jev-1.14.0")
        XCTAssertNotNil((body["assets"] as? [String: Any])?["screen"])
    }

    func testFailedControlIsRemovedFromQuestion() async throws {
        let stub = JevVisionStub()
        let provider = JevVisionProvider(apiKey: "test-key", client: stub)
        let snapshot = UISnapshot(captureID: .init(), elements: [])
        let request = GoalNavigationRequest(goal: "Open next page", snapshot: snapshot,
            candidates: [.init(id: "failed", label: "Continue", elementIndex: 0),
                         .init(id: "available", label: "Skip", elementIndex: 1)],
            recentActions: ["Continue"], suppressedLabels: ["Continue"], imageData: try png())
        _ = try await provider.decide(request)
        let captured = await stub.captured()
        let sent = try XCTUnwrap(captured.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.httpBody!) as? [String: Any])
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
        let next = try XCTUnwrap(questions["next"])
        let criteria = try XCTUnwrap(next["criteria"] as? [String: String])
        XCTAssertNil(criteria["failed"])
        XCTAssertNotNil(criteria["available"])
        XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])["imageData"])
    }
}
