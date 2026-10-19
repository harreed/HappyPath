import Foundation
import RunnerCore

public struct RunArtifactLayout: Sendable, Equatable {
    public let root: URL
    public let screenshots: URL
    public let snapshots: URL
    public let decisions: URL
    public let video: URL
    public let events: URL

    public init(root: URL) {
        self.root = root
        screenshots = root.appendingPathComponent("screenshots", isDirectory: true)
        snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        decisions = root.appendingPathComponent("decisions", isDirectory: true)
        video = root.appendingPathComponent("video.mp4", isDirectory: false)
        events = root.appendingPathComponent("events.jsonl", isDirectory: false)
    }

    public func screenshotURL(stepIndex: Int, captureID: CaptureID) -> URL {
        screenshots.appendingPathComponent(
            String(format: "%04d-%@.png", stepIndex, captureID.description),
            isDirectory: false
        )
    }

    public func snapshotURL(stepIndex: Int, captureID: CaptureID) -> URL {
        snapshots.appendingPathComponent(
            String(format: "%04d-%@.json", stepIndex, captureID.description),
            isDirectory: false
        )
    }
}

public enum ArtifactStoreError: Error {
    case eventBelongsToDifferentRun(expected: UUID, received: UUID)
    case nonIncreasingSequence(previous: UInt64, received: UInt64)
}

/// An append-only JSON Lines log plus a predictable run artifact directory.
public actor RunArtifactStore {
    public let runID: UUID
    public let layout: RunArtifactLayout

    private let eventHandle: FileHandle
    private let encoder: JSONEncoder
    private var lastSequence: UInt64?

    public init(baseDirectory: URL, runID: UUID = UUID(), startedAt: Date = Date()) throws {
        self.runID = runID

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let directoryName = "\(formatter.string(from: startedAt))-\(runID.uuidString.lowercased())"
            .replacingOccurrences(of: ":", with: "-")
        layout = RunArtifactLayout(root: baseDirectory.appendingPathComponent(directoryName, isDirectory: true))

        try FileManager.default.createDirectory(at: layout.screenshots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.snapshots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.decisions, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: layout.events.path, contents: nil)
        eventHandle = try FileHandle(forWritingTo: layout.events)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    deinit {
        try? eventHandle.close()
    }

    public func append(_ event: RunEvent) throws {
        guard event.runID == runID else {
            throw ArtifactStoreError.eventBelongsToDifferentRun(expected: runID, received: event.runID)
        }
        if let lastSequence, event.sequence <= lastSequence {
            throw ArtifactStoreError.nonIncreasingSequence(previous: lastSequence, received: event.sequence)
        }

        var bytes = try encoder.encode(event)
        bytes.append(0x0A)
        try eventHandle.write(contentsOf: bytes)
        try eventHandle.synchronize()
        lastSequence = event.sequence
    }

    public func writeSnapshot(_ snapshot: UISnapshot, stepIndex: Int) throws -> URL {
        let url = layout.snapshotURL(stepIndex: stepIndex, captureID: snapshot.captureID)
        let data = try encoder.encode(snapshot)
        // Foundation does not support combining .atomic with .withoutOverwriting.
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}
