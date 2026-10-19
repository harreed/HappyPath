import Foundation
import XCTest
@testable import ArtifactStore
@testable import RunnerCore

final class ArtifactStoreTests: XCTestCase {
    func testCreatesLayoutAndWritesAppendOnlyEventsAndSnapshot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let runID = UUID()
        let store = try RunArtifactStore(baseDirectory: base, runID: runID, startedAt: Date(timeIntervalSince1970: 0))
        let capture = CaptureID()

        try await store.append(RunEvent(
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            runID: runID,
            kind: .runStarted,
            message: "Started"
        ))
        try await store.append(RunEvent(
            sequence: 2,
            timestamp: Date(timeIntervalSince1970: 2),
            runID: runID,
            kind: .captureCreated,
            message: "Captured",
            captureID: capture,
            artifactRelativePath: "screenshots/0001.png"
        ))
        let snapshotURL = try await store.writeSnapshot(
            UISnapshot(captureID: capture, elements: []),
            stepIndex: 1
        )
        let layout = await store.layout

        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.screenshots.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.snapshots.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.decisions.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))

        let lines = try String(contentsOf: layout.events, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    func testRejectsDuplicateSnapshotWithoutChangingOriginal() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try RunArtifactStore(baseDirectory: base)
        let snapshot = UISnapshot(captureID: CaptureID(), elements: [])
        let url = try await store.writeSnapshot(snapshot, stepIndex: 1)
        let original = try Data(contentsOf: url)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: original))

        do {
            _ = try await store.writeSnapshot(snapshot, stepIndex: 1)
            XCTFail("Expected duplicate snapshot to fail")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteFileExists.rawValue)
        }

        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testRejectsNonIncreasingSequence() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let runID = UUID()
        let store = try RunArtifactStore(baseDirectory: base, runID: runID)
        try await store.append(RunEvent(sequence: 2, runID: runID, kind: .diagnostic, message: "first"))

        do {
            try await store.append(RunEvent(sequence: 2, runID: runID, kind: .diagnostic, message: "duplicate"))
            XCTFail("Expected duplicate sequence to fail")
        } catch let error as ArtifactStoreError {
            guard case .nonIncreasingSequence(previous: 2, received: 2) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
