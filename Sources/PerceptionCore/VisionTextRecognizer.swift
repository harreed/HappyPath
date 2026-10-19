import Foundation
import Vision
import ImageIO
import CoreGraphics
import CryptoKit
import RunnerCore

/// Extracted from the Phase 0 OCR benchmark: accurate English Vision recognition,
/// converting Vision bottom-left normalized boxes into screenshot top-left pixels.
public actor VisionTextRecognizer: TextRecognizing {
    private let lifecycle: @Sendable (String) -> Void
    public init(lifecycle: @escaping @Sendable (String) -> Void = { _ in }) { self.lifecycle = lifecycle }
    public func prewarm() async throws {
        try Task.checkCancellation()
        guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else { throw PerceptionFailure.invalidImage }
        _ = try await run(image, level: .accurate)
        try Task.checkCancellation()
    }
    public func prewarmFast() async throws {
        try Task.checkCancellation()
        guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else { throw PerceptionFailure.invalidImage }
        _ = try await run(image, level: .fast)
        try Task.checkCancellation()
    }
    public func recognize(imageData: Data, capture: ScreenCapture, geometry: PerceptionGeometry) async throws -> TextPerception {
        try await recognize(imageData: imageData, capture: capture, geometry: geometry, level: .accurate)
    }
    public func recognizeFast(imageData: Data, capture: ScreenCapture, geometry: PerceptionGeometry) async throws -> TextPerception {
        try await recognize(imageData: imageData, capture: capture, geometry: geometry, level: .fast)
    }
    private func recognize(imageData: Data, capture: ScreenCapture, geometry: PerceptionGeometry,
                           level: VNRequestTextRecognitionLevel) async throws -> TextPerception {
        try Task.checkCancellation()
        try geometry.validate()
        guard geometry.pixels == capture.pixelSize,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PerceptionFailure.invalidImage }
        guard image.width == capture.pixelSize.width, image.height == capture.pixelSize.height else { throw PerceptionFailure.invalidGeometry }
        let started = Date(); let tick = DispatchTime.now().uptimeNanoseconds
        let regions = try await run(image, level: level)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - tick) / 1_000_000
        try Task.checkCancellation()
        return TextPerception(captureID: capture.id, geometry: geometry, screenshotStartedAt: capture.createdAt,
            recognitionStartedAt: started, recognitionCompletedAt: Date(), recognitionMilliseconds: elapsed,
            provider: level == .fast ? "apple.vision.ocr.fast" : "apple.vision.ocr",
            imageSHA256: SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined(), regions: regions)
    }
    private func run(_ image: CGImage, level: VNRequestTextRecognitionLevel) async throws -> [TextRegion] {
        let work = VisionWork(lifecycle: lifecycle, level: level)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                work.start(image: image, continuation: continuation)
            }
        } onCancel: { work.cancel() }
    }
}

/// The continuation is resumed on cancellation even when Vision is still unwinding.
/// A cancelled worker owns only immutable pixels and can never dispatch UI input.
private final class VisionWork: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "production.vision.serial", qos: .userInitiated)
    private static let admissionLock = NSLock()
    private static var active = false
    private let lifecycle: @Sendable (String) -> Void
    private let level: VNRequestTextRecognitionLevel
    init(lifecycle: @escaping @Sendable (String) -> Void, level: VNRequestTextRecognitionLevel) {
        self.lifecycle = lifecycle; self.level = level
    }
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var continuation: CheckedContinuation<[TextRegion], Error>?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true
        let request = request; let continuation = continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        lifecycle("cancelRequested")
        request?.cancel()
    }
    func start(image: CGImage, continuation: CheckedContinuation<[TextRegion], Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        lock.unlock()
        Self.admissionLock.lock()
        guard !Self.active else {
            Self.admissionLock.unlock()
            lock.lock(); let completion = self.continuation; self.continuation = nil; lock.unlock()
            completion?.resume(throwing: PerceptionFailure.workerBusy)
            return
        }
        Self.active = true; Self.admissionLock.unlock()
        Self.queue.async {
            defer { Self.admissionLock.lock(); Self.active = false; Self.admissionLock.unlock() }
            let result = Result { try self.perform(image) }
            self.lock.lock(); let completion = self.continuation; self.continuation = nil; self.request = nil; self.lock.unlock()
            self.lifecycle("workerFinished")
            completion?.resume(with: result)
        }
    }
    private func perform(_ image: CGImage) throws -> [TextRegion] {
        let request = VNRecognizeTextRequest()
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        self.request = request
        lock.unlock()
        request.recognitionLevel = level
        request.recognitionLanguages = ["en-US"]
        lifecycle("requestStarted")
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return TextRegion(text: text.string, confidence: Double(text.confidence), pixelBox: CGRectValue(
                x: box.minX * Double(image.width), y: (1 - box.maxY) * Double(image.height),
                width: box.width * Double(image.width), height: box.height * Double(image.height)))
        }
    }
}
