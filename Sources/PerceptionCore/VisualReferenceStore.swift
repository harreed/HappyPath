import CryptoKit
import Foundation
import ImageIO
import RunnerCore
import UniformTypeIdentifiers

public struct ApprovedVisualReference: Sendable, Equatable {
    public let id: UUID
    public let relativePath: String
    public let sha256: String
    public let pixelSize: PixelSize
}

/// Copies a preserved capture into the project's references directory only
/// when the user explicitly approves that screenshot in the UI.
public struct VisualReferenceStore: Sendable {
    public init() {}

    public func approve(capture: ScreenCapture, runDirectory: URL,
                        projectDirectory: URL) throws -> ApprovedVisualReference {
        guard capture.screenshotRelativePath == "captures/\(capture.id).png" else {
            throw VisualComparisonFailure.captureMismatch
        }
        let runRoot = runDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let source = runDirectory.appendingPathComponent(capture.screenshotRelativePath).standardizedFileURL
        guard source.resolvingSymlinksInPath().deletingLastPathComponent() == runRoot.appendingPathComponent("captures"),
              (try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isSymbolicLink) == false,
              let sourceSize = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              sourceSize > 0, sourceSize <= 100_000_000 else { throw VisualComparisonFailure.invalidImage }
        let data = try Data(contentsOf: source)
        guard data.count <= 100_000_000,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) == 1,
              CGImageSourceGetType(imageSource) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw VisualComparisonFailure.invalidImage
        }
        guard image.width == capture.pixelSize.width, image.height == capture.pixelSize.height else {
            throw VisualComparisonFailure.dimensionMismatch
        }
        let id = UUID()
        let relativePath = "references/\(id.uuidString.lowercased()).png"
        let destination = projectDirectory.appendingPathComponent(relativePath)
        let projectRoot = projectDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let referenceDirectory = destination.deletingLastPathComponent()
        guard referenceDirectory.standardizedFileURL.resolvingSymlinksInPath() == projectRoot.appendingPathComponent("references") else {
            throw VisualComparisonFailure.invalidImage
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(id.uuidString.lowercased()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return .init(id: id, relativePath: relativePath,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            pixelSize: capture.pixelSize)
    }
}
