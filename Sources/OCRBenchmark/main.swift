import Foundation
import RunnerCore
import PerceptionCore
import ImageIO
import CryptoKit

// Usage: swift Scripts/benchmark_ocr.swift OUTPUT.json IMAGE.png [IMAGE.png ...]
// Inputs must be retained source captures; repeated pixels are counted explicitly.
struct Region: Codable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
struct Measurement: Codable {
    let path: String
    let sha256: String
    let pixelWidth: Int
    let pixelHeight: Int
    let firstPassMilliseconds: Double
    let repeatMilliseconds: Double
    let regions: [Region]
}
struct Report: Codable {
    let generatedAt: Date
    let sourceCaptureCount: Int
    let distinctImageCount: Int
    let firstRequestMilliseconds: Double
    let measurements: [Measurement]
    let notes: String
}
@main struct Benchmark {
static func main() async throws {
let recognizer = VisionTextRecognizer()
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    fputs("Usage: swift Scripts/benchmark_ocr.swift OUTPUT.json IMAGE.png [IMAGE.png ...]\n", stderr)
    exit(2)
}
var measurements: [Measurement] = []
for path in args.dropFirst() {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "OCRBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid image: \(path)"])
    }
    var timings: [Double] = []
    var regions: [Region] = []
    for pass in 0..<2 {
        let capture = ScreenCapture(pixelSize: PixelSize(width: image.width, height: image.height), screenshotRelativePath: path)
        let result = try await recognizer.recognize(imageData: data, capture: capture,
            geometry: PerceptionGeometry(pixels: capture.pixelSize, screenFrame: CGRectValue(x: 0, y: 0, width: Double(image.width), height: Double(image.height))))
        timings.append(result.recognitionMilliseconds)
        if pass == 0 {
            regions = result.regions.map { Region(text: $0.text, confidence: Float($0.confidence), x: $0.pixelBox.x, y: $0.pixelBox.y, width: $0.pixelBox.width, height: $0.pixelBox.height) }
        }
    }
    measurements.append(Measurement(path: path,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        pixelWidth: image.width, pixelHeight: image.height,
        firstPassMilliseconds: timings[0], repeatMilliseconds: timings[1], regions: regions))
}
let report = Report(generatedAt: Date(), sourceCaptureCount: measurements.count,
    distinctImageCount: Set(measurements.map(\.sha256)).count,
    firstRequestMilliseconds: measurements[0].firstPassMilliseconds,
    measurements: measurements,
    notes: "First request is process-cold only; OS/model caches were not flushed. Each retained image is recognized twice. Pixel regions use top-left origin. Distinct hashes measure unique image bytes, not distinct UI states. Corpus representativeness requires separate review.")
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601
try encoder.encode(report).write(to: URL(fileURLWithPath: args[0]), options: .atomic)
print("Measured \(measurements.count) captures (\(report.distinctImageCount) unique image hashes)")

}
}
