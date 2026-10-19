import CoreGraphics
import Foundation
import ImageIO
@testable import ModelProviders
import RunnerCore
import UniformTypeIdentifiers
import XCTest

private actor VisionHTTPStub: ClaudeVisionHTTPClient {
    let body: Data
    let status: Int
    let url: URL
    var captured: URLRequest?
    init(_ body: Data, status: Int = 200,
         url: URL = URL(string: "https://api.anthropic.com/v1/messages")!) {
        self.body = body; self.status = status; self.url = url
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured = request
        return (body, HTTPURLResponse(url: url, statusCode: status,
                                      httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

final class ClaudeVisionProviderTests: XCTestCase {
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    private func request() throws -> ImageAssessmentRequest {
        .init(capture: .init(pixelSize: .init(width: 2, height: 2),
                             screenshotRelativePath: "captures/test.png"),
              imageData: try png(), question: "Is the page blue?",
              deadline: Date().addingTimeInterval(5))
    }
    private func response(verdict: String = "insufficient", confidence: Double = 0.91,
                          reason: String = "The colour cannot be determined") -> Data {
        let answer = "{\"verdict\":\"\(verdict)\",\"confidence\":\(confidence),\"reason\":\"\(reason)\"}"
        let message: [String: Any] = ["type": "message", "role": "assistant",
            "model": "claude-haiku-5-5", "stop_reason": "end_turn",
            "content": [["type": "text", "text": answer]]]
        return try! JSONSerialization.data(withJSONObject: message)
    }

    func testWireShapeAndCaptureBindingOnlyAfterOptIn() async throws {
        let stub = VisionHTTPStub(response())
        let provider = ClaudeVisionProvider(client: stub, apiKey: "test-only-key")
        let input = try request()
        do {
            _ = try await provider.assess(input)
            XCTFail("Provider accepted an unapproved direct call")
        } catch { XCTAssertEqual(error as? ImageAssessmentFailure, .remoteConsentRequired) }
        do {
            _ = try await ImageAssessmentGate().assess(input, with: provider, choice: .localOnly)
            XCTFail("Remote bytes sent without opt-in")
        } catch { XCTAssertEqual(error as? ImageAssessmentFailure, .remoteConsentRequired) }
        let before = await stub.captured
        XCTAssertNil(before)
        let result = try await ImageAssessmentGate().assess(input, with: provider,
            choice: .allowRemoteForThisRun, minimumConfidence: 0.8)
        XCTAssertEqual(result.captureID, input.capture.id)
        XCTAssertEqual(result.imageSHA256, input.imageSHA256)
        XCTAssertEqual(result.verdict, .insufficient)
        XCTAssertTrue(result.rawResponse?.contains("\"verdict\":\"insufficient\"") == true)
        let capturedRequest = await stub.captured
        let sent = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-api-key"), "test-only-key")
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(wire["model"] as? String, "claude-haiku-5-5")
        let messages = try XCTUnwrap(wire["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "image")
        let source = try XCTUnwrap(content.first?["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(Data(base64Encoded: source["data"] as? String ?? ""), input.imageData)
        XCTAssertFalse(String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self).contains("test-only-key"))
    }

    func testRedirectOversizeAndMalformedResponseAreRejected() async throws {
        let input = try request()
        let cases: [(Data, Int, URL)] = [
            (response(), 302, URL(string: "https://evil.example/redirect")!),
            (Data(repeating: 65, count: 128_001), 200, URL(string: "https://api.anthropic.com/v1/messages")!),
            (response(verdict: "invented"), 200, URL(string: "https://api.anthropic.com/v1/messages")!),
            (response(confidence: 1.2), 200, URL(string: "https://api.anthropic.com/v1/messages")!)
        ]
        for (body, status, url) in cases {
            let provider = ClaudeVisionProvider(client: VisionHTTPStub(body, status: status, url: url),
                                                apiKey: "test-key")
            do {
                _ = try await ImageAssessmentGate().assess(input, with: provider,
                    choice: .allowRemoteForThisRun)
                XCTFail("Accepted invalid response")
            } catch let error as ImageAssessmentFailure {
                XCTAssertTrue(error == .unavailable || error == .invalidResponse)
            }
        }
    }
}
