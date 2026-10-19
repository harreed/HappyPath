import Foundation
import AVFoundation
import AppKit

// Usage: swift Scripts/verify_video.swift VIDEO.mp4 OUTPUT.json
struct VideoEvidence: Codable {
    let source: String
    let durationSeconds: Double
    let decodedFrameCount: Int
    let decodedFrameTimesSeconds: [Double]
    let pixelWidth: Int
    let pixelHeight: Int
    let notes: String
}
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    fputs("Usage: swift Scripts/verify_video.swift VIDEO.mp4 OUTPUT.json\n", stderr)
    exit(2)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[0]))
let duration = try await asset.load(.duration).seconds
guard duration.isFinite, duration > 0 else {
    throw NSError(domain: "VideoVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Video duration is invalid"])
}
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
let positions = [0.0, duration / 2, max(0, duration - 0.15)]
var times: [Double] = []
var width = 0
var height = 0
for position in positions {
    let frame = try await generator.image(at: CMTime(seconds: position, preferredTimescale: 600))
    width = frame.image.width
    height = frame.image.height
    times.append(frame.actualTime.seconds)
}
let evidence = VideoEvidence(source: arguments[0], durationSeconds: duration,
    decodedFrameCount: times.count, decodedFrameTimesSeconds: times,
    pixelWidth: width, pixelHeight: height,
    notes: "AVFoundation decoded requested start/middle/end samples. This proves sampled playability; matching the full action timeline remains a separate artifact review.")
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(evidence).write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
print("Decoded \(times.count) frames from \(duration)-second video (\(width)x\(height))")
