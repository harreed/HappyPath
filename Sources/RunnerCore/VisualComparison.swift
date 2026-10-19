import Foundation

/// A local comparison against an approved screenshot. It makes no semantic claim
/// about objects, colours, or the meaning of a screen.
public struct VisualComparisonPolicy: Codable, Sendable, Equatable {
    public let maximumMeanChannelDifference: Double
    public let maximumChangedPixelFraction: Double
    public let changedChannelThreshold: UInt8
    public let ignoredRegions: [CGRectValue]

    public init(maximumMeanChannelDifference: Double = 0.02,
                maximumChangedPixelFraction: Double = 0.01,
                changedChannelThreshold: UInt8 = 16,
                ignoredRegions: [CGRectValue] = []) {
        self.maximumMeanChannelDifference = maximumMeanChannelDifference
        self.maximumChangedPixelFraction = maximumChangedPixelFraction
        self.changedChannelThreshold = changedChannelThreshold
        self.ignoredRegions = ignoredRegions
    }

    public func validate(for size: PixelSize) throws {
        guard maximumMeanChannelDifference.isFinite, (0...1).contains(maximumMeanChannelDifference),
              maximumChangedPixelFraction.isFinite, (0...1).contains(maximumChangedPixelFraction),
              ignoredRegions.count <= 32,
              ignoredRegions.allSatisfy({ region in
                  [region.x, region.y, region.width, region.height].allSatisfy(\.isFinite) &&
                  region.x >= 0 && region.y >= 0 && region.width > 0 && region.height > 0 &&
                  region.x + region.width <= Double(size.width) &&
                  region.y + region.height <= Double(size.height)
              }) else { throw VisualComparisonFailure.invalidPolicy }
    }
}

public enum VisualComparisonFailure: Error, Equatable, Sendable {
    case invalidPolicy, invalidImage, dimensionMismatch, noComparablePixels
    case captureMismatch, invalidEvidence
}

public protocol VisualComparing: Sendable {
    func compare(actualImageData: Data, referenceImageData: Data,
                 capture: ScreenCapture, policy: VisualComparisonPolicy) throws -> VisualComparisonEvidence
}

public struct VisualComparisonEvidence: Codable, Sendable, Equatable {
    public let captureID: CaptureID
    public let capturedAt: Date
    public let actualImageSHA256: String
    public let referenceImageSHA256: String
    public let pixelSize: PixelSize
    public let comparedPixelCount: Int
    public let changedPixelCount: Int
    /// Mean absolute RGB channel difference, scaled to 0...1.
    public let meanChannelDifference: Double
    /// The smallest top-left-origin rectangle containing all changed pixels.
    public let changedBounds: CGRectValue?
    public let policy: VisualComparisonPolicy
    public let provider: String

    public init(captureID: CaptureID, capturedAt: Date, actualImageSHA256: String,
                referenceImageSHA256: String, pixelSize: PixelSize,
                comparedPixelCount: Int, changedPixelCount: Int,
                meanChannelDifference: Double, changedBounds: CGRectValue?,
                policy: VisualComparisonPolicy, provider: String) {
        self.captureID = captureID; self.capturedAt = capturedAt
        self.actualImageSHA256 = actualImageSHA256; self.referenceImageSHA256 = referenceImageSHA256
        self.pixelSize = pixelSize; self.comparedPixelCount = comparedPixelCount
        self.changedPixelCount = changedPixelCount; self.meanChannelDifference = meanChannelDifference
        self.changedBounds = changedBounds; self.policy = policy; self.provider = provider
    }

    public var changedPixelFraction: Double { Double(changedPixelCount) / Double(comparedPixelCount) }
    public var matchesReference: Bool {
        meanChannelDifference <= policy.maximumMeanChannelDifference &&
        changedPixelFraction <= policy.maximumChangedPixelFraction
    }

    public func validate(capture: ScreenCapture, actualImageSHA256: String) throws {
        guard captureID == capture.id, capturedAt == capture.createdAt else { throw VisualComparisonFailure.captureMismatch }
        try policy.validate(for: pixelSize)
        let total = pixelSize.width.multipliedReportingOverflow(by: pixelSize.height)
        guard !total.overflow, pixelSize == capture.pixelSize,
              comparedPixelCount > 0, comparedPixelCount <= total.partialValue,
              changedPixelCount >= 0, changedPixelCount <= comparedPixelCount,
              meanChannelDifference.isFinite, (0...1).contains(meanChannelDifference),
              provider == "local.pixel-comparison.v1",
              Self.isDigest(self.actualImageSHA256), Self.isDigest(referenceImageSHA256),
              self.actualImageSHA256 == actualImageSHA256.lowercased(),
              (changedPixelCount == 0) == (changedBounds == nil) else { throw VisualComparisonFailure.invalidEvidence }
        if let bounds = changedBounds {
            guard [bounds.x, bounds.y, bounds.width, bounds.height].allSatisfy(\.isFinite),
                  bounds.x >= 0, bounds.y >= 0, bounds.width > 0, bounds.height > 0,
                  bounds.x + bounds.width <= Double(pixelSize.width),
                  bounds.y + bounds.height <= Double(pixelSize.height) else { throw VisualComparisonFailure.invalidEvidence }
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
    }
}
