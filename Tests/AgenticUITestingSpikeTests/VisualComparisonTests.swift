import CoreGraphics
import Foundation
import ImageIO
import PerceptionCore
import RunnerCore
import UniformTypeIdentifiers
import XCTest

final class VisualComparisonTests: XCTestCase {
    private func png(width: Int = 4, height: Int = 4, changedPixel: Bool = false) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if changedPixel {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testIdenticalBaselinePassesWithCaptureBoundEvidence() throws {
        let data = try png()
        let capture = ScreenCapture(pixelSize: .init(width: 4, height: 4), screenshotRelativePath: "capture.png")
        let evidence = try LocalPixelComparator().compare(actualImageData: data, referenceImageData: data, capture: capture)
        XCTAssertTrue(evidence.matchesReference)
        XCTAssertEqual(evidence.comparedPixelCount, 16)
        XCTAssertEqual(evidence.changedPixelCount, 0)
        XCTAssertNil(evidence.changedBounds)
        XCTAssertNoThrow(try evidence.validate(capture: capture, actualImageSHA256: evidence.actualImageSHA256))
        XCTAssertThrowsError(try evidence.validate(capture: ScreenCapture(pixelSize: capture.pixelSize, screenshotRelativePath: "other.png"), actualImageSHA256: evidence.actualImageSHA256))
        XCTAssertThrowsError(try evidence.validate(capture: capture, actualImageSHA256: String(repeating: "0", count: 64)))
    }

    func testSinglePixelChangeFailsAndCanBeMasked() throws {
        let reference = try png(), actual = try png(changedPixel: true)
        let capture = ScreenCapture(pixelSize: .init(width: 4, height: 4), screenshotRelativePath: "capture.png")
        let strict = VisualComparisonPolicy(maximumMeanChannelDifference: 0, maximumChangedPixelFraction: 0)
        let difference = try LocalPixelComparator().compare(actualImageData: actual, referenceImageData: reference,
            capture: capture, policy: strict)
        XCTAssertFalse(difference.matchesReference)
        XCTAssertEqual(difference.changedPixelCount, 1)
        XCTAssertGreaterThan(difference.meanChannelDifference, 0)
        let bound = try XCTUnwrap(difference.changedBounds)
        let masked = try LocalPixelComparator().compare(actualImageData: actual, referenceImageData: reference,
            capture: capture, policy: .init(maximumMeanChannelDifference: 0,
                maximumChangedPixelFraction: 0, ignoredRegions: [bound]))
        XCTAssertTrue(masked.matchesReference)
        XCTAssertEqual(masked.comparedPixelCount, 15)
    }

    func testInvalidReferenceAndMaskAreRejected() throws {
        let actual = try png()
        let capture = ScreenCapture(pixelSize: .init(width: 4, height: 4), screenshotRelativePath: "capture.png")
        XCTAssertThrowsError(try LocalPixelComparator().compare(actualImageData: actual,
            referenceImageData: try png(width: 2, height: 2), capture: capture)) {
            XCTAssertEqual($0 as? VisualComparisonFailure, .dimensionMismatch)
        }
        XCTAssertThrowsError(try LocalPixelComparator().compare(actualImageData: actual,
            referenceImageData: Data("not an image".utf8), capture: capture)) {
            XCTAssertEqual($0 as? VisualComparisonFailure, .invalidImage)
        }
        let allMasked = VisualComparisonPolicy(ignoredRegions: [.init(x: 0, y: 0, width: 4, height: 4)])
        XCTAssertThrowsError(try LocalPixelComparator().compare(actualImageData: actual,
            referenceImageData: actual, capture: capture, policy: allMasked)) {
            XCTAssertEqual($0 as? VisualComparisonFailure, .noComparablePixels)
        }
    }

    func testApprovedReferenceIsCopiedIntoProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let run = root.appendingPathComponent("run"), project = root.appendingPathComponent("project")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: run.appendingPathComponent("captures"), withIntermediateDirectories: true)
        let capture = ScreenCapture(pixelSize: .init(width: 4, height: 4),
            screenshotRelativePath: "captures/placeholder.png")
        let bound = ScreenCapture(id: capture.id, createdAt: capture.createdAt,
            pixelSize: capture.pixelSize, screenshotRelativePath: "captures/\(capture.id).png")
        let data = try png()
        try data.write(to: run.appendingPathComponent(bound.screenshotRelativePath))
        let approved = try VisualReferenceStore().approve(capture: bound,
            runDirectory: run, projectDirectory: project)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent(approved.relativePath)), data)
        XCTAssertEqual(approved.sha256.count, 64)
        XCTAssertThrowsError(try VisualReferenceStore().approve(capture: capture,
            runDirectory: run, projectDirectory: project))
    }
}
