import Foundation
import RunnerCore
import PerceptionCore

@main struct Acceptance {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { fatalError("Usage: PerceptionAcceptance OUTPUT.json CAPTURE.json [...]") }
        let decoder = JSONDecoder()
        let recognizer = VisionTextRecognizer()
        let start = Date()
        try await recognizer.prewarm()
        let prewarmMilliseconds = Date().timeIntervalSince(start) * 1000
        var evidence: [TextPerception] = []
        for path in args.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let bound = try decoder.decode(CompanionCapture.self, from: Data(contentsOf: url))
            let png = url.deletingPathExtension().appendingPathExtension("png")
            let capture = ScreenCapture(id: bound.snapshot.captureID, createdAt: bound.snapshot.capturedAt,
                pixelSize: PixelSize(width: bound.pixelWidth, height: bound.pixelHeight), screenshotRelativePath: png.path)
            let result = try await recognizer.recognize(imageData: Data(contentsOf: png), capture: capture,
                geometry: PerceptionGeometry(pixels: capture.pixelSize, screenFrame: bound.screenFrame))
            guard result.regions.contains(where: { $0.text == "Finish setup" && $0.confidence >= 0.8 }) else { fatalError("Missing actual hidden fixture target") }
            do { try result.validate(capture: capture, now: Date(), maximumAge: 8); fatalError("Retained capture authorized!") }
            catch PerceptionFailure.staleCapture { }
            evidence.append(result)
        }
        struct Report: Encodable { let prewarmMilliseconds: Double; let notes: String; let evidence: [TextPerception] }
        let report = Report(prewarmMilliseconds: prewarmMilliseconds,
            notes: "Actual retained fixture pixels; original capture IDs and dates preserved. Finish setup recognized by Vision OCR only. Retained captures rejected as stale. No live action or Apple image-model inference.", evidence: evidence)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: args[0]))
        print("PASS: \(evidence.count) retained captures recognized and refused as stale; prewarm \(prewarmMilliseconds)ms")
    }
}
