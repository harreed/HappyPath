import CoreGraphics
import Foundation
import ImageIO
@testable import ModelProviders
import RunnerCore
import UniformTypeIdentifiers
import XCTest

private final class ClefURLStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastRequest: URLRequest?
    nonisolated(unsafe) private static var lastBody: Data?

    static func reset() { lock.withLock { lastRequest = nil; lastBody = nil } }
    static func captured() -> URLRequest? { lock.withLock { lastRequest } }
    static func capturedBody() -> Data? { lock.withLock { lastBody } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var sentBody = request.httpBody
        if sentBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(contentsOf: buffer.prefix(count))
            }
            sentBody = collected
        }
        Self.lock.withLock { Self.lastRequest = request; Self.lastBody = sentBody }
        let body = Data("""
        {"model":"@cf/cloudflare/clef-flash","answers":{"verdict":{"type":"choice","choice":"insufficient","confidence":0.91,"probabilities":{"satisfied":0.03,"notSatisfied":0.06,"insufficient":0.91}}},"usage":{"input_tokens":100,"output_tokens":0}}
        """.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClefVisionProviderTests: XCTestCase {
    private func request() throws -> ImageAssessmentRequest {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return .init(capture: .init(pixelSize: .init(width: 2, height: 2),
            screenshotRelativePath: "captures/test.png"), imageData: bytes as Data,
            question: "Is the finish state visible?", deadline: Date().addingTimeInterval(10))
    }

    func testApprovedImageCallUsesClefAndBindsResultToCapture() async throws {
        ClefURLStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClefURLStub.self]
        let provider = ClefVisionProvider(accountID: "test-account", apiToken: "test-token",
            session: URLSession(configuration: config))
        let input = try request()
        do {
            _ = try await ImageAssessmentGate().assess(input, with: provider, choice: .localOnly)
            XCTFail("Sent remote screenshot without approval")
        } catch { XCTAssertEqual(error as? ImageAssessmentFailure, .remoteConsentRequired) }
        XCTAssertNil(ClefURLStub.captured())

        let result = try await ImageAssessmentGate().assess(input, with: provider,
            choice: .allowRemoteForThisRun, minimumConfidence: 0.8)
        XCTAssertEqual(result.captureID, input.capture.id)
        XCTAssertEqual(result.imageSHA256, input.imageSHA256)
        XCTAssertEqual(result.verdict, .insufficient)
        XCTAssertEqual(result.providerID, "cloudflare.clef-flash.vision")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result.rawResponse).utf8)) as? [String: Any])
        let content = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((try XCTUnwrap(raw["content"] as? String)).utf8)) as? [String: Any])
        XCTAssertEqual(content["verdict"] as? String, result.verdict.rawValue)
        XCTAssertEqual(raw["confidence"] as? Double, result.confidence)
        let request = try XCTUnwrap(ClefURLStub.captured())
        XCTAssertEqual(request.url?.host, "api.cloudflare.com")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let sentBody = try XCTUnwrap(ClefURLStub.capturedBody())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "clef-flash")
        XCTAssertEqual((body["images"] as? [Any])?.count, 1)
        XCTAssertFalse(String(decoding: sentBody, as: UTF8.self).contains("test-token"))
    }
}
