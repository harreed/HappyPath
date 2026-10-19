import Foundation
import XCTest
import ProjectDomain
import RunnerCore
import ArtifactStore

final class ExecutionArchiveTests: XCTestCase {
    func testBulkRunDeletionRemovesEntireEvidenceFoldersOnlyWithinProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = root.appendingPathComponent("runs")
        let first = runs.appendingPathComponent("first")
        let second = runs.appendingPathComponent("second")
        let outside = root.appendingPathComponent("keep")
        for folder in [first, second, outside] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("captures"), withIntermediateDirectories: true)
            try Data("video".utf8).write(to: folder.appendingPathComponent("video.mp4"))
            try Data("image".utf8).write(to: folder.appendingPathComponent("captures/screen.png"))
            try Data("report".utf8).write(to: folder.appendingPathComponent("report.md"))
        }

        let result = RunArchiveDeletion.delete([first, first, second, outside, runs], projectURL: root)
        XCTAssertEqual(Set(result.deleted), Set([first, second]))
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("video.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runs.path))
    }

    func testHistorySummaryReadsRunEndpointsWithoutDecodingEveryEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = TestProject(name: "History", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.example.app"), simulator: .init(deviceID: "device"), categories: [])
        let store = try ExecutionArtifactStore(directory: root, project: project, selection: .all)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.append(.state(.preparing), timestamp: start)
        try await store.append(.state(.running), timestamp: start.addingTimeInterval(12.5))
        try await store.append(.state(.finished), timestamp: start.addingTimeInterval(25))

        let summary = try ExecutionArchiveSummary(directory: root)
        XCTAssertEqual(summary.title, "All tests")
        XCTAssertEqual(summary.outcome, "Incomplete")
        XCTAssertEqual(summary.date, start)
        XCTAssertEqual(summary.duration, 25)

        // The middle event is intentionally invalid. A history row only reads
        // the endpoints; opening the archive still validates the whole log.
        let eventsURL = root.appendingPathComponent("events.jsonl")
        var lines = try String(contentsOf: eventsURL, encoding: .utf8).split(separator: "\n").map(String.init)
        lines[1] = "invalid event payload"
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: eventsURL)
        XCTAssertEqual(try ExecutionArchiveSummary(directory: root).duration, 25)
        XCTAssertThrowsError(try ExecutionArchive(directory: root))
    }

    func testMovedExportResolvesOnlyItsOwnEvidenceAndPreservesSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original")
        let definition = TestProject(name: "Portable run", app: .init(projectPath: "/old/checkout/App.xcodeproj", scheme: "App", bundleIdentifier: "org.example.app"), simulator: .init(deviceID: "device"), categories: [])
        let store = try ExecutionArtifactStore(directory: source, project: definition, selection: .all)
        let capture = CaptureID()
        let snapshot = UISnapshot(captureID: capture, capturedAt: Date(timeIntervalSince1970: 1_800_000_000.321), elements: [])
        try await store.append(.capture(snapshot))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("captures"), withIntermediateDirectories: true)
        let png = Data("capture-bytes".utf8), raw = Data("snapshot-bytes".utf8), video = Data("video-bytes".utf8)
        try png.write(to: source.appendingPathComponent("captures/\(capture).png"))
        try raw.write(to: source.appendingPathComponent("captures/\(capture).json"))
        try video.write(to: source.appendingPathComponent("video.mp4"))
        try Data("Companion build timed out; partial compiler output".utf8).write(to: source.appendingPathComponent("companion-build.log"))
        let request = GoalAssessmentRequest(goal: "Appearance", snapshot: snapshot, deadline: Date().addingTimeInterval(30), mode: .imageUnavailable)
        let goal = GoalAssessmentEvidence(testID: UUID(), goal: "Appearance", request: request, provider: "unavailable", assessment: nil, minimumConfidence: 0.9, outcome: .needsReview, reason: "Image observation unavailable")
        try await store.append(.goalAssessment(goal))
        let terminal = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"blocked\",\"tests\":[]}".utf8))
        try await store.append(.finished(terminal))
        try await store.finish(terminal)
        let exported = root.appendingPathComponent("export")
        try ExecutionArtifactStore.export(directory: source, to: exported)
        let moved = root.appendingPathComponent("relocated run")
        try FileManager.default.moveItem(at: exported, to: moved)
        try FileManager.default.removeItem(at: source)

        let archive = try ExecutionArchive(directory: moved)
        XCTAssertEqual(archive.project, definition)
        XCTAssertEqual(archive.report?.outcome, .blocked)
        XCTAssertEqual(archive.snapshot(for: capture), snapshot)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archive.screenshotURL(for: capture))), png)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archive.rawSnapshotURL(for: capture))), raw)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archive.videoURL)), video)
        XCTAssertNotNil(archive.readableReportURL)
        let readable = try String(contentsOf: XCTUnwrap(archive.readableReportURL))
        XCTAssertTrue(readable.contains("Authoritative assessment reason: Image observation unavailable"))
        XCTAssertTrue(readable.contains("Evidence mode: imageUnavailable"))
        XCTAssertTrue(readable.contains("captures/\(capture).png"))
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(archive.readableReportURL)).contains("[Companion build log](companion-build.log)"))
        XCTAssertNotNil(archive.evidenceURL(relativePath: "companion-build.log"))
        XCTAssertNil(archive.screenshotURL(for: CaptureID()))
        XCTAssertNil(archive.evidenceURL(relativePath: source.path))
        let external = root.appendingPathComponent("outside.png")
        try png.write(to: external)
        XCTAssertNil(archive.evidenceURL(relativePath: "../outside.png"))
        try FileManager.default.createSymbolicLink(at: moved.appendingPathComponent("escape.png"), withDestinationURL: external)
        XCTAssertNil(archive.evidenceURL(relativePath: "escape.png"))
        try Data("{\"outcome\":\"passed\",\"tests\":[]}".utf8).write(to: moved.appendingPathComponent("run.json"), options: .atomic)
        XCTAssertThrowsError(try ExecutionArchive(directory: moved)) { error in
            guard case ExecutionArtifactError.invalidTerminalResult = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testUnfinishedArchiveRemainsInspectableWithoutInferredSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = TestProject(name: "In progress", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.example.app"), simulator: .init(deviceID: "device"), categories: [])
        let store = try ExecutionArtifactStore(directory: root, project: project, selection: .all)
        try await store.append(.state(.preparing))
        let archive = try ExecutionArchive(directory: root)
        XCTAssertNil(archive.report)
        XCTAssertNil(archive.videoURL)
        XCTAssertEqual(archive.events.count, 1)
        XCTAssertEqual(try archive.review.tests.count, 0)
        try Data("corrupt terminal".utf8).write(to: root.appendingPathComponent("run.json"))
        XCTAssertThrowsError(try ExecutionArchive(directory: root))
    }

    func testFailureCloseRetainsEventsWithoutCreatingSuccessReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = TestProject(name: "Interrupted persistence", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.example.app"), simulator: .init(deviceID: "device"), categories: [])
        let store = try ExecutionArtifactStore(directory: root, project: project, selection: .all)
        try await store.append(.state(.preparing))
        await store.closeAfterFailure()
        await store.closeAfterFailure()
        do { try await store.append(.state(.finished)); XCTFail("Closed writer accepted an event") }
        catch ExecutionArtifactError.finalized { }
        let archive = try ExecutionArchive(directory: root)
        XCTAssertEqual(archive.events.count, 1)
        XCTAssertNil(archive.report)
    }

    func testReadableReportFailureCannotCommitSuccessfulTerminalMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = TestProject(name: "Failed report write", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.example.app"), simulator: .init(deviceID: "device"), categories: [])
        let store = try ExecutionArtifactStore(directory: root, project: project, selection: .all)
        try await store.append(.state(.finished))
        // A directory at the report filename forces the real atomic file write to fail.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("report.md"), withIntermediateDirectories: false)
        let terminal = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"passed\",\"tests\":[]}".utf8))
        do { try await store.finish(terminal); XCTFail("Expected report write failure") } catch { }
        await store.closeAfterFailure()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("run.json").path))
        XCTAssertNil(try ExecutionArchive(directory: root).report)
    }
}
