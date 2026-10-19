import Foundation

/// Pixel boxes have top-left origin; screenFrame maps these pixels into XCTest points.
public struct PerceptionGeometry: Hashable, Codable, Sendable {
    public let pixels: PixelSize
    public let screenFrame: CGRectValue
    public init(pixels: PixelSize, screenFrame: CGRectValue) { self.pixels = pixels; self.screenFrame = screenFrame }
    public func validate() throws {
        guard pixels.width > 0, pixels.height > 0,
              [screenFrame.x, screenFrame.y, screenFrame.width, screenFrame.height].allSatisfy(\.isFinite),
              screenFrame.width > 0, screenFrame.height > 0,
              (screenFrame.x + screenFrame.width).isFinite, (screenFrame.y + screenFrame.height).isFinite else { throw PerceptionFailure.invalidGeometry }
    }
    public func screenPoint(for pixel: PixelPoint) throws -> PixelPoint {
        try validate()
        guard pixel.x.isFinite, pixel.y.isFinite, pixel.x >= 0, pixel.y >= 0,
              pixel.x < Double(pixels.width), pixel.y < Double(pixels.height) else { throw PerceptionFailure.invalidGeometry }
        return PixelPoint(x: screenFrame.x + pixel.x / Double(pixels.width) * screenFrame.width,
                          y: screenFrame.y + pixel.y / Double(pixels.height) * screenFrame.height)
    }
}
public enum PerceptionFailure: Error, Equatable { case workerBusy, invalidGeometry, captureMismatch, invalidTiming, staleCapture, invalidEvidence, ambiguousMatch, noMatch, invalidImage }
public struct TextRegion: Hashable, Codable, Sendable {
    public let text: String
    public let confidence: Double
    public let pixelBox: CGRectValue
    public init(text: String, confidence: Double, pixelBox: CGRectValue) { self.text = text; self.confidence = confidence; self.pixelBox = pixelBox }
    public var center: PixelPoint { PixelPoint(x: pixelBox.x + pixelBox.width / 2, y: pixelBox.y + pixelBox.height / 2) }
}
public struct TextPerception: Hashable, Codable, Sendable {
    public let captureID: CaptureID
    public let geometry: PerceptionGeometry
    public let screenshotStartedAt: Date
    public let recognitionStartedAt: Date
    public let recognitionCompletedAt: Date
    public let recognitionMilliseconds: Double
    public let provider: String
    public let imageSHA256: String
    public let regions: [TextRegion]
    public init(captureID: CaptureID, geometry: PerceptionGeometry, screenshotStartedAt: Date,
                recognitionStartedAt: Date, recognitionCompletedAt: Date, recognitionMilliseconds: Double,
                provider: String, imageSHA256: String, regions: [TextRegion]) {
        self.captureID = captureID; self.geometry = geometry; self.screenshotStartedAt = screenshotStartedAt
        self.recognitionStartedAt = recognitionStartedAt; self.recognitionCompletedAt = recognitionCompletedAt
        self.recognitionMilliseconds = recognitionMilliseconds; self.provider = provider; self.imageSHA256 = imageSHA256; self.regions = regions
    }
    /// Call again immediately before dispatch. A successful OCR result is not an action permit.
    public func validate(capture: ScreenCapture, now: Date, maximumAge: TimeInterval) throws {
        guard captureID == capture.id else { throw PerceptionFailure.captureMismatch }
        try geometry.validate()
        guard geometry.pixels == capture.pixelSize else { throw PerceptionFailure.invalidGeometry }
        guard screenshotStartedAt == capture.createdAt,
              [now, screenshotStartedAt, recognitionStartedAt, recognitionCompletedAt].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              maximumAge.isFinite, maximumAge > 0, maximumAge <= 10,
              screenshotStartedAt <= recognitionStartedAt, recognitionStartedAt <= recognitionCompletedAt,
              recognitionCompletedAt <= now, recognitionMilliseconds.isFinite, recognitionMilliseconds >= 0 else { throw PerceptionFailure.invalidTiming }
        guard now.timeIntervalSince(screenshotStartedAt) < maximumAge else { throw PerceptionFailure.staleCapture }
        guard !provider.isEmpty, imageSHA256.count == 64, imageSHA256.allSatisfy({ $0.isHexDigit }), regions.allSatisfy({ r in
            let b = r.pixelBox
            return !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && r.confidence.isFinite && (0...1).contains(r.confidence) &&
            [b.x, b.y, b.width, b.height].allSatisfy(\.isFinite) && b.x >= 0 && b.y >= 0 && b.width > 0 && b.height > 0 &&
            b.x + b.width <= Double(geometry.pixels.width) && b.y + b.height <= Double(geometry.pixels.height)
        }) else { throw PerceptionFailure.invalidEvidence }
    }
    public func uniqueMatch(text: String, minimumConfidence: Double, capture: ScreenCapture, now: Date = Date(), maximumAge: TimeInterval = 8) throws -> TextRegion {
        try validate(capture: capture, now: now, maximumAge: maximumAge)
        guard minimumConfidence.isFinite, (0...1).contains(minimumConfidence), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PerceptionFailure.invalidEvidence }
        let exact = regions.filter { TargetTextMatching.equals($0.text, text) }
        let candidates = exact.isEmpty
            ? regions.filter { TargetTextMatching.contains($0.text, text) }
            : exact
        guard candidates.count <= 1 else { throw PerceptionFailure.ambiguousMatch }
        guard let match = candidates.first, match.confidence >= minimumConfidence else { throw PerceptionFailure.noMatch }
        return match
    }
}
public protocol TextRecognizing: Sendable {
    /// Explicit startup cost, before acquiring action-bearing captures.
    func prewarm() async throws
    func prewarmFast() async throws
    func recognize(imageData: Data, capture: ScreenCapture, geometry: PerceptionGeometry) async throws -> TextPerception
    func recognizeFast(imageData: Data, capture: ScreenCapture, geometry: PerceptionGeometry) async throws -> TextPerception
}
public extension TextRecognizing {
    func prewarmFast() async throws { try await prewarm() }
    func recognizeFast(imageData: Data, capture: ScreenCapture, geometry: PerceptionGeometry) async throws -> TextPerception {
        try await recognize(imageData: imageData, capture: capture, geometry: geometry)
    }
}

public extension CompanionCapture {
    /// Nil means legacy provenance is unknown. These intervals are sequential,
    /// not an atomic pixel/accessibility snapshot (hittability queries are live).
    func validatedTiming(now: Date = Date()) throws -> Bool {
        let start = snapshot.capturedAt
        guard start.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite, start <= now else { throw PerceptionFailure.invalidTiming }
        let values = [screenshotCompletedAt, semanticStartedAt, semanticTreeCompletedAt, semanticCompletedAt]
        guard values.contains(where: { $0 != nil }) else { return false }
        guard let pixelsEnd = screenshotCompletedAt, let semanticStart = semanticStartedAt, let semanticEnd = semanticCompletedAt,
              [pixelsEnd, semanticStart, semanticEnd].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              start <= pixelsEnd, pixelsEnd <= semanticStart, semanticStart <= semanticEnd, semanticEnd <= now else { throw PerceptionFailure.invalidTiming }
        if let treeEnd = semanticTreeCompletedAt {
            guard treeEnd.timeIntervalSince1970.isFinite,
                  semanticStart <= treeEnd, treeEnd <= semanticEnd else { throw PerceptionFailure.invalidTiming }
        }
        return true
    }
}

/// OCR text is never advertised as screenshot model inference.
public enum PerceptionRole: String, Codable, Sendable { case textRecognition, screenshotModelObservation }
public struct PerceptionCapability: Hashable, Codable, Sendable {
    public let role: PerceptionRole
    public let available: Bool
    public let reason: String
    public init(role: PerceptionRole, available: Bool, reason: String) { self.role = role; self.available = available; self.reason = reason }
    public static let localScreenshotModel = PerceptionCapability(role: .screenshotModelObservation, available: false,
        reason: "Screenshot model observation is not connected to this runner. Vision OCR is text recognition only.")
}
