import XCTest
import RunnerCore
import PerceptionCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
final class PerceptionTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1000)
    func fixture(regions: [TextRegion]? = nil, age: Double = 1) -> (ScreenCapture, TextPerception) {
        let capture = ScreenCapture(createdAt: date, pixelSize: PixelSize(width: 100, height: 200), screenshotRelativePath: "test.png")
        let evidence = TextPerception(captureID: capture.id, geometry: PerceptionGeometry(pixels: capture.pixelSize, screenFrame: CGRectValue(x: 0, y: 0, width: 50, height: 100)), screenshotStartedAt: date,
            recognitionStartedAt: date, recognitionCompletedAt: date.addingTimeInterval(age), recognitionMilliseconds: age * 1000,
            provider: "test.ocr", imageSHA256: String(repeating: "a", count: 64), regions: regions ?? [TextRegion(text: "Finish setup", confidence: 0.95, pixelBox: CGRectValue(x: 20, y: 60, width: 60, height: 20))])
        return (capture, evidence)
    }
    func testCaptureBoundTransformAndUniqueMatch() throws {
        let (c,e) = fixture()
        let region = try e.uniqueMatch(text: "Finish setup", minimumConfidence: 0.9, capture: c, now: date.addingTimeInterval(1))
        XCTAssertEqual(try e.geometry.screenPoint(for: region.center), PixelPoint(x: 25, y: 35))
    }
    func testAmbiguityIncludesLowConfidenceDuplicate() {
        let r = TextRegion(text: "Finish setup", confidence: 0.2, pixelBox: CGRectValue(x: 0, y: 0, width: 10, height: 10))
        let (c,e) = fixture(regions: [r,r])
        XCTAssertThrowsError(try e.uniqueMatch(text: r.text, minimumConfidence: 0.9, capture: c, now: date.addingTimeInterval(1))) { XCTAssertEqual($0 as? PerceptionFailure, .ambiguousMatch) }
    }
    func testSlowRecognitionRequiresRecaptureAndFutureDateRefused() {
        let (c,e) = fixture(age: 9)
        XCTAssertThrowsError(try e.validate(capture: c, now: date.addingTimeInterval(9), maximumAge: 8)) { XCTAssertEqual($0 as? PerceptionFailure, .staleCapture) }
        XCTAssertThrowsError(try e.validate(capture: c, now: date.addingTimeInterval(-1), maximumAge: 8))
    }
    func testIdentityDimensionsAndMalformedEvidence() throws {
        let (c,e) = fixture()
        XCTAssertThrowsError(try e.validate(capture: ScreenCapture(pixelSize: c.pixelSize, screenshotRelativePath: "x"), now: date.addingTimeInterval(1), maximumAge: 8))
        let malformed = try JSONDecoder().decode(PixelSize.self, from: Data("{\"width\":0,\"height\":-1}".utf8))
        XCTAssertThrowsError(try PerceptionGeometry(pixels: malformed, screenFrame: e.geometry.screenFrame).validate())
        let (badCapture,bad) = fixture(regions: [TextRegion(text: "Finish setup", confidence: .nan, pixelBox: CGRectValue(x: 0, y: 0, width: 10, height: 10))])
        XCTAssertThrowsError(try bad.validate(capture: badCapture, now: date.addingTimeInterval(1), maximumAge: 8))
        let mismatch = ScreenCapture(id: c.id, createdAt: date, pixelSize: PixelSize(width: 5, height: 10), screenshotRelativePath: "x")
        XCTAssertThrowsError(try e.validate(capture: mismatch, now: date.addingTimeInterval(1), maximumAge: 8))
    }
    func testInvalidImageRejected() async throws {
        let (c,e) = fixture()
        do { _ = try await VisionTextRecognizer().recognize(imageData: Data(), capture: c, geometry: e.geometry); XCTFail("accepted") } catch { XCTAssertEqual(error as? PerceptionFailure, .invalidImage) }
    }
    func testProvenanceUnknownOrderedMalformedAndFuture() throws {
        let (c,e) = fixture()
        func bound(_ p: Date? = nil, _ s: Date? = nil, _ end: Date? = nil) -> CompanionCapture {
            CompanionCapture(snapshot: UISnapshot(captureID: c.id, capturedAt: date, elements: []), screenshotName: "x", pixelWidth: 100, pixelHeight: 200, screenFrame: e.geometry.screenFrame, screenshotCompletedAt: p, semanticStartedAt: s, semanticCompletedAt: end)
        }
        XCTAssertFalse(try bound().validatedTiming(now: date))
        XCTAssertTrue(try bound(date, date, date).validatedTiming(now: date))
        XCTAssertThrowsError(try bound(date, nil, date).validatedTiming(now: date))
        XCTAssertThrowsError(try bound(date, date.addingTimeInterval(-1), date).validatedTiming(now: date))
        XCTAssertThrowsError(try bound(date, date, Date(timeIntervalSince1970: .infinity)).validatedTiming(now: date))
        XCTAssertThrowsError(try bound(date, date, date).validatedTiming(now: date.addingTimeInterval(-1)))
        let split = CompanionCapture(snapshot: UISnapshot(captureID: c.id, capturedAt: date, elements: []),
            screenshotName: "x", pixelWidth: 100, pixelHeight: 200, screenFrame: e.geometry.screenFrame,
            screenshotCompletedAt: date, semanticStartedAt: date,
            semanticTreeCompletedAt: date.addingTimeInterval(1), semanticCompletedAt: date.addingTimeInterval(2))
        XCTAssertTrue(try split.validatedTiming(now: date.addingTimeInterval(2)))
        let unordered = CompanionCapture(snapshot: split.snapshot, screenshotName: "x", pixelWidth: 100,
            pixelHeight: 200, screenFrame: e.geometry.screenFrame, screenshotCompletedAt: date,
            semanticStartedAt: date, semanticTreeCompletedAt: date.addingTimeInterval(3),
            semanticCompletedAt: date.addingTimeInterval(2))
        XCTAssertThrowsError(try unordered.validatedTiming(now: date.addingTimeInterval(3)))
    }
    func testOutOfBoundsBoxAndInvalidThreshold() {
        let (c,e) = fixture()
        XCTAssertThrowsError(try e.uniqueMatch(text: "Finish setup", minimumConfidence: .nan, capture: c, now: date.addingTimeInterval(1)))
        let (b,r) = fixture(regions: [TextRegion(text: "Finish setup", confidence: 1, pixelBox: CGRectValue(x: 99, y: 0, width: 10, height: 10))])
        XCTAssertThrowsError(try r.validate(capture: b, now: date.addingTimeInterval(1), maximumAge: 8))
    }
    func testActualPNGDimensionMismatch() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let data = bytes as Data
        let (c,e) = fixture()
        do { _ = try await VisionTextRecognizer().recognize(imageData: data, capture: c, geometry: e.geometry); XCTFail("accepted wrong dimensions") }
        catch { XCTAssertEqual(error as? PerceptionFailure, .invalidGeometry) }
    }

}
