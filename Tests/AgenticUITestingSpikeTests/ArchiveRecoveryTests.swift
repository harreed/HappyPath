import Foundation
import XCTest
import ProjectDomain
import RunnerCore
import ArtifactStore

final class ArchiveRecoveryTests: XCTestCase {
    private func makeProject() -> TestProject {
        TestProject(name: "Recovery Test", app: .init(projectPath: "Test.xcodeproj", scheme: "Test", bundleIdentifier: "test.app"), simulator: .init(deviceID: "device"), categories: [])
    }

    private func writeEvents(at url: URL, lines: [String]) throws {
        let data = lines.joined(separator: "\n") + "\n"
        try data.write(to: url, atomically: true, encoding: .utf8)
    }

    private func createCompleteRun(at source: URL) async throws {
        let definition = makeProject()
        let store = try ExecutionArtifactStore(directory: source, project: definition, selection: .all)
        try await store.append(.state(.preparing))
        try await store.append(.state(.running))
        let terminal = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"passed\",\"tests\":[]}".utf8))
        try await store.append(.finished(terminal))
        try await store.finish(terminal)
    }

    func testTornTailRecoveryPreservesCommittedPrefix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("torn-tail")
        let definition = makeProject()
        let store = try ExecutionArtifactStore(directory: source, project: definition, selection: .all)

        let capture = CaptureID()
        let snapshot = UISnapshot(captureID: capture, capturedAt: Date(timeIntervalSince1970: 1_800_000_000.321), elements: [])
        try await store.append(.capture(snapshot))
        try await store.append(.state(.preparing))
        let terminal = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"passed\",\"tests\":[]}".utf8))
        try await store.append(.finished(terminal))
        try await store.finish(terminal)

        let eventsURL = source.appendingPathComponent("events.jsonl")
        var original = try String(contentsOf: eventsURL)
        original = String(original.dropLast(1))
        try original.write(to: eventsURL, atomically: true, encoding: .utf8)

        let destination = root.appendingPathComponent("recovered")
        let manifest = try ArchiveRecovery.recover(source, to: destination, mode: .nativePrefix)

        XCTAssertTrue(manifest.incomplete)
        XCTAssertEqual(manifest.mode, .nativePrefix)
        XCTAssertEqual(manifest.eventCount, 2)
        XCTAssertGreaterThan(manifest.omittedTailBytes, 0)

        let recovered = try ExecutionArchive(directory: destination)
        XCTAssertNil(recovered.report)
        XCTAssertEqual(recovered.events.count, 2)
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(recovered.readableReportURL)).contains("Recovered / incomplete"))

        let originalDir = destination.appendingPathComponent("original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalDir.appendingPathComponent("events.jsonl").path))
    }

    func testMiddleCorruptionRejectsRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("middle-corrupt")
        let definition = makeProject()
        let store = try ExecutionArtifactStore(directory: source, project: definition, selection: .all)

        try await store.append(.state(.preparing))
        try await store.append(.state(.running))

        let eventsURL = source.appendingPathComponent("events.jsonl")
        var original = try String(contentsOf: eventsURL)
        let lines = original.split(separator: "\n")
        var modified = Array(lines)
        modified[1] = "{\"sequence\":999,\"timestamp\":1000,\"event\":{\"state\":{\"_0\":\"running\"}}}"
        try (modified.joined(separator: "\n") + "\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let destination = root.appendingPathComponent("recovered")
        do {
            _ = try ArchiveRecovery.recover(source, to: destination, mode: .nativePrefix)
            XCTFail("Expected recovery to fail on middle corruption")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Invalid event sequence") || error.localizedDescription.contains("sequence") || error.localizedDescription.contains("999"))
        }
    }

    func testTerminalFaultMismatchRejectsRunJson() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("terminal-fault")
        let definition = makeProject()
        let store = try ExecutionArtifactStore(directory: source, project: definition, selection: .all)

        try await store.append(.state(.preparing))
        let terminal = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"passed\",\"tests\":[]}".utf8))
        try await store.append(.finished(terminal))
        try await store.finish(terminal)

        try Data("{\"outcome\":\"failed\",\"tests\":[]}".utf8).write(to: source.appendingPathComponent("run.json"), options: .atomic)

        let destination = root.appendingPathComponent("recovered")
        let manifest = try ArchiveRecovery.recover(source, to: destination, mode: .nativePrefix)

        XCTAssertTrue(manifest.incomplete)
        let recovered = try ExecutionArchive(directory: destination)
        XCTAssertNil(recovered.report)
    }

    func testLegacyISOImportConvertsDatesAndPreservesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy-import")

        try FileManager.default.createDirectory(at: source.appendingPathComponent("captures"), withIntermediateDirectories: true)
        let definition = makeProject()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(definition).write(to: source.appendingPathComponent("project.json"), options: .atomic)
        try encoder.encode(RunSelection.all).write(to: source.appendingPathComponent("selection.json"), options: .atomic)

        let isoDate = "2026-09-19T14:30:00.123Z"
        let line1 = "{\"sequence\":1,\"timestamp\":\"\(isoDate)\",\"event\":{\"state\":{\"_0\":\"preparing\"}}}"
        let line2 = "{\"sequence\":2,\"timestamp\":\"\(isoDate)\",\"event\":{\"state\":{\"_0\":\"running\"}}}"
        try writeEvents(at: source.appendingPathComponent("events.jsonl"), lines: [line1, line2])

        let terminal = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"passed\",\"tests\":[]}".utf8))
        let terminalEncoder = JSONEncoder()
        terminalEncoder.dateEncodingStrategy = .iso8601
        try terminalEncoder.encode(terminal).write(to: source.appendingPathComponent("run.json"), options: .atomic)

        let destination = root.appendingPathComponent("imported")
        let manifest = try ArchiveRecovery.recover(source, to: destination, mode: .legacyISOImport)

        XCTAssertEqual(manifest.mode, .legacyISOImport)
        XCTAssertEqual(manifest.dateConversions.count, 2)

        let imported = try ExecutionArchive(directory: destination)
        XCTAssertEqual(imported.events.count, 2)
        XCTAssertEqual(imported.events[0].timestamp.timeIntervalSince1970, 1_789_828_200.123, accuracy: 0.01)
    }

    func testLegacyISOImportRejectsMixedFormat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy-mixed")

        try FileManager.default.createDirectory(at: source.appendingPathComponent("captures"), withIntermediateDirectories: true)
        let definition = makeProject()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(definition).write(to: source.appendingPathComponent("project.json"), options: .atomic)
        try encoder.encode(RunSelection.all).write(to: source.appendingPathComponent("selection.json"), options: .atomic)

        try Data("{\"eventFormatVersion\":2,\"dateEncoding\":\"millisecondsSince1970\"}".utf8).write(to: source.appendingPathComponent("artifact-format.json"), options: .atomic)

        let line1 = "{\"sequence\":1,\"timestamp\":\"2026-09-19T14:30:00.123Z\",\"event\":{\"state\":\"preparing\"}}"
        try writeEvents(at: source.appendingPathComponent("events.jsonl"), lines: [line1])

        let destination = root.appendingPathComponent("imported")
        do {
            _ = try ArchiveRecovery.recover(source, to: destination, mode: .legacyISOImport)
            XCTFail("Expected legacy import to reject mixed format")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Legacy import requires an unmarked Phase1 ISO archive"))
        }
    }

    func testSessionIdentityRecordsProcessAndKernelStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("session-test")
        let definition = makeProject()
        let store = try ExecutionArtifactStore(directory: source, project: definition, selection: .all)

        try await store.append(.state(.preparing))
        let terminal = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"passed\",\"tests\":[]}".utf8))
        try await store.append(.finished(terminal))
        try await store.finish(terminal)

        let session = try RunSession.read(in: source)
        XCTAssertEqual(session.schemaVersion, 1)
        XCTAssertNotNil(session.owner)
        XCTAssertEqual(session.owner?.pid, getpid())
        XCTAssertTrue(session.closed)
    }

    func testResourceRecordsCreatedForCompanionAndVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("resource-test")
        let definition = makeProject()
        _ = try ExecutionArtifactStore(directory: source, project: definition, selection: .all)

        try RunResourceRecord.record(in: source, role: "companion host", pid: getpid(), simulatorID: "sim-123", bundleIdentifier: "test.runner")
        try RunResourceRecord.record(in: source, role: "video recorder", pid: getpid(), simulatorID: "sim-123")

        let files = try FileManager.default.contentsOfDirectory(atPath: source.path)
        let resourceFiles = files.filter { $0.hasPrefix("resource-") && $0.hasSuffix(".json") }
        XCTAssertEqual(resourceFiles.count, 2)

        for file in resourceFiles {
            let data = try Data(contentsOf: source.appendingPathComponent(file))
            let record = try JSONDecoder().decode(RunResourceRecord.self, from: data)
            XCTAssertEqual(record.schemaVersion, 1)
            XCTAssertEqual(record.sessionID, (try RunSession.read(in: source)).sessionID)
            XCTAssertNotNil(record.process)
            XCTAssertNotNil(record.simulatorID)
        }
    }

    func testRecoveryRefusesWhenLiveOwnerMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("live-owner")
        let definition = makeProject()
        let store = try ExecutionArtifactStore(directory: source, project: definition, selection: .all)

        try await store.append(.state(.preparing))
        try await store.append(.state(.running))
        // Do NOT call finish() - session remains unclosed with current PID

        let destination = root.appendingPathComponent("recovered")
        do {
            _ = try ArchiveRecovery.recover(source, to: destination, mode: .nativePrefix)
            XCTFail("Expected recovery to fail when live owner matches")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("recorded owner still matches a live process"))
        }
    }

    func testRecoveryPreservesOriginalBytesAndManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("preserve-test")
        let definition = makeProject()
        let store = try ExecutionArtifactStore(directory: source, project: definition, selection: .all)

        try await store.append(.state(.preparing))
        let terminal = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"passed\",\"tests\":[]}".utf8))
        try await store.append(.finished(terminal))
        try await store.finish(terminal)

        let destination = root.appendingPathComponent("recovered")
        let manifest = try ArchiveRecovery.recover(source, to: destination, mode: .nativePrefix)

        let originalDir = destination.appendingPathComponent("original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalDir.appendingPathComponent("events.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalDir.appendingPathComponent("run.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalDir.appendingPathComponent("project.json").path))

        XCTAssertEqual(manifest.originalManifest.count, manifest.originalManifest.filter { $0.value != "directory" }.count + manifest.originalManifest.filter { $0.value == "directory" }.count)
        XCTAssertEqual(manifest.originalEventsSHA256, ArchiveRecovery.hash(try Data(contentsOf: originalDir.appendingPathComponent("events.jsonl"))))
        XCTAssertEqual(manifest.committedPrefixBytes, try Data(contentsOf: originalDir.appendingPathComponent("events.jsonl")).count)
    }

    func testRecoveryRejectsSymlinkInSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("symlink-test")
        let definition = makeProject()
        let store = try ExecutionArtifactStore(directory: source, project: definition, selection: .all)

        try await store.append(.state(.preparing))
        let terminal = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"passed\",\"tests\":[]}".utf8))
        try await store.append(.finished(terminal))
        try await store.finish(terminal)

        let outside = root.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: outside, options: .atomic)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape.txt"), withDestinationURL: outside)

        let destination = root.appendingPathComponent("recovered")
        do {
            _ = try ArchiveRecovery.recover(source, to: destination, mode: .nativePrefix)
            XCTFail("Expected recovery to reject symlink")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Unsupported link or special file") || error.localizedDescription.contains("Symbolic links are not supported"))
        }
    }

    func testNativeDiagnosisOfCorruptedArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("corrupted")
        try await createCompleteRun(at: source)

        let eventsURL = source.appendingPathComponent("events.jsonl")
        var original = try String(contentsOf: eventsURL)
        original = String(original.dropLast(1))
        try original.write(to: eventsURL, atomically: true, encoding: .utf8)

        let diagnosis = try ArchiveRecovery.diagnose(source)
        XCTAssertEqual(diagnosis.events.count, 2)
        XCTAssertFalse(diagnosis.sourceComplete)
        XCTAssertGreaterThan(diagnosis.originalEvents.count - diagnosis.committedBytes.count, 0)

        do {
            _ = try ExecutionArchive(directory: source)
            XCTFail("Expected ExecutionArchive to fail on corrupted archive")
        } catch {
            XCTAssertTrue(error is ExecutionArtifactError)
        }
    }

    func testNativeRecoveryAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("recover-test")
        try await createCompleteRun(at: source)

        let eventsURL = source.appendingPathComponent("events.jsonl")
        var original = try String(contentsOf: eventsURL)
        original = String(original.dropLast(1))
        try original.write(to: eventsURL, atomically: true, encoding: .utf8)

        let destination = root.appendingPathComponent("recovered-native")
        let manifest = try ArchiveRecovery.recover(source, to: destination, mode: .nativePrefix)

        XCTAssertTrue(manifest.incomplete)
        XCTAssertEqual(manifest.mode, .nativePrefix)
        XCTAssertEqual(manifest.eventCount, 2)

        let recovered = try ExecutionArchive(directory: destination)
        XCTAssertNil(recovered.report)
        XCTAssertEqual(recovered.events.count, 2)
        XCTAssertTrue(recovered.recovery?.incomplete == true)

        let exported = root.appendingPathComponent("exported-run")
        try ExecutionArtifactStore.export(directory: destination, to: exported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))

        let reExported = try ExecutionArchive(directory: exported)
        XCTAssertEqual(reExported.events.count, 2)
    }

    func testNativeLegacyImportAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy-test")

        try FileManager.default.createDirectory(at: source.appendingPathComponent("captures"), withIntermediateDirectories: true)
        let definition = makeProject()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(definition).write(to: source.appendingPathComponent("project.json"), options: .atomic)
        try encoder.encode(RunSelection.all).write(to: source.appendingPathComponent("selection.json"), options: .atomic)

        let isoDate = "2026-09-19T14:30:00.123Z"
        let line1 = "{\"sequence\":1,\"timestamp\":\"\(isoDate)\",\"event\":{\"state\":{\"_0\":\"preparing\"}}}"
        let line2 = "{\"sequence\":2,\"timestamp\":\"\(isoDate)\",\"event\":{\"state\":{\"_0\":\"running\"}}}"
        let line3 = "{\"sequence\":3,\"timestamp\":\"\(isoDate)\",\"event\":{\"finished\":{\"_0\":{\"outcome\":\"passed\",\"tests\":[]}}}}"
        try writeEvents(at: source.appendingPathComponent("events.jsonl"), lines: [line1, line2, line3])

        let terminal = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"passed\",\"tests\":[]}".utf8))
        let terminalEncoder = JSONEncoder()
        terminalEncoder.dateEncodingStrategy = .iso8601
        try terminalEncoder.encode(terminal).write(to: source.appendingPathComponent("run.json"), options: .atomic)

        let destination = root.appendingPathComponent("imported-native")
        let manifest = try ArchiveRecovery.recover(source, to: destination, mode: .legacyISOImport)

        XCTAssertEqual(manifest.mode, .legacyISOImport)
        XCTAssertFalse(manifest.incomplete)

        let imported = try ExecutionArchive(directory: destination)
        XCTAssertEqual(imported.events.count, 3)
        XCTAssertFalse(imported.recovery?.incomplete == true)
        XCTAssertEqual(imported.report?.outcome, .passed)

        let exported = root.appendingPathComponent("exported-legacy")
        try ExecutionArtifactStore.export(directory: destination, to: exported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
    }
}