import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import RunnerCore

/// Deterministic, on-device screenshot comparison. Image bytes never leave the process.
public struct LocalPixelComparator: VisualComparing {
    public init() {}

    public func compare(actualImageData: Data, referenceImageData: Data,
                        capture: ScreenCapture, policy: VisualComparisonPolicy = .init()) throws -> VisualComparisonEvidence {
        try policy.validate(for: capture.pixelSize)
        let total = capture.pixelSize.width.multipliedReportingOverflow(by: capture.pixelSize.height)
        guard !total.overflow, total.partialValue <= 20_000_000,
              actualImageData.count <= 100_000_000, referenceImageData.count <= 100_000_000 else {
            throw VisualComparisonFailure.invalidImage
        }
        let actual = try pixels(actualImageData, expected: capture.pixelSize)
        let reference = try pixels(referenceImageData, expected: capture.pixelSize)
        let width = capture.pixelSize.width, height = capture.pixelSize.height
        var compared = 0, changed = 0
        var sum: UInt64 = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            // Core Graphics bitmap storage starts at the bottom; evidence uses top-left pixels.
            let y = height - 1 - row
            for x in 0..<width {
                if policy.ignoredRegions.contains(where: { r in
                    Double(x) >= r.x && Double(x) < r.x + r.width &&
                    Double(y) >= r.y && Double(y) < r.y + r.height
                }) { continue }
                let offset = (row * width + x) * 4
                let differences = (0..<3).map { abs(Int(actual[offset + $0]) - Int(reference[offset + $0])) }
                sum += UInt64(differences.reduce(0, +))
                compared += 1
                if differences.max()! >= Int(policy.changedChannelThreshold) && differences.max()! > 0 {
                    changed += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard compared > 0 else { throw VisualComparisonFailure.noComparablePixels }
        let bounds = changed == 0 ? nil : CGRectValue(x: Double(minX), y: Double(minY),
            width: Double(maxX - minX + 1), height: Double(maxY - minY + 1))
        return VisualComparisonEvidence(captureID: capture.id, capturedAt: capture.createdAt,
            actualImageSHA256: digest(actualImageData), referenceImageSHA256: digest(referenceImageData),
            pixelSize: capture.pixelSize, comparedPixelCount: compared, changedPixelCount: changed,
            meanChannelDifference: Double(sum) / Double(compared * 3 * 255), changedBounds: bounds,
            policy: policy, provider: "local.pixel-comparison.v1")
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func pixels(_ data: Data, expected: PixelSize) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VisualComparisonFailure.invalidImage
        }
        guard image.width == expected.width, image.height == expected.height else {
            throw VisualComparisonFailure.dimensionMismatch
        }
        var output = [UInt8](repeating: 0, count: expected.width * expected.height * 4)
        let drawn = output.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: expected.width, height: expected.height,
                                          bitsPerComponent: 8, bytesPerRow: expected.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                              CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: expected.width, height: expected.height))
            return true
        }
        guard drawn else { throw VisualComparisonFailure.invalidImage }
        return output
    }
}
