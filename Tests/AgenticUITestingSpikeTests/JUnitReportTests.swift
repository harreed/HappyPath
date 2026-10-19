import Foundation
import XCTest
import ProjectDomain
import RunnerCore
import ArtifactStore

final class JUnitReportTests: XCTestCase {
    func testFailureAndIncompleteTestsProduceEscapedFailuresWithoutDiagnostics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ProjectDomain.TestCase(name: "Sign in <guest> & continue", blocks: [])
        let second = ProjectDomain.TestCase(name: "Never started", blocks: [])
        let project = TestProject(name: "CI", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.example.app"),
            simulator: .init(deviceID: "device"), categories: [.init(name: "A & B", suites: [.init(name: "Smoke \"suite\"", tests: [first, second])])])
        let store = try ExecutionArtifactStore(directory: directory, project: project, selection: .all)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await store.append(.testStarted(first.id), timestamp: start)
        _ = try await store.append(.diagnostic("PRIVATE_TOKEN=do-not-export"))
        _ = try await store.append(.testFinished(first.id, .failed), timestamp: start.addingTimeInterval(2))
        let report = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"blocked\",\"tests\":[{\"testID\":\"\(first.id.uuidString)\",\"outcome\":\"failed\"}]}".utf8))
        _ = try await store.append(.finished(report))
        try await store.finish(report)
        let xml = try String(contentsOf: directory.appendingPathComponent("junit.xml"), encoding: .utf8)
        XCTAssertTrue(xml.contains("tests=\"2\" failures=\"2\""))
        XCTAssertTrue(xml.contains("name=\"Sign in &lt;guest&gt; &amp; continue\""))
        XCTAssertTrue(xml.contains("classname=\"A &amp; B / Smoke &quot;suite&quot;\""))
        XCTAssertTrue(xml.contains("time=\"2.000\""))
        XCTAssertTrue(xml.contains("type=\"incomplete\""))
        XCTAssertFalse(xml.contains("PRIVATE_TOKEN"))
    }

    func testPreparationFailureCreatesFailingCase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = TestProject(name: "Empty", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.example.app"), simulator: .init(deviceID: "device"), categories: [])
        let store = try ExecutionArtifactStore(directory: directory, project: project, selection: .all)
        let report = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"blocked\",\"tests\":[]}".utf8))
        _ = try await store.append(.finished(report))
        try await store.finish(report)
        let xml = try String(contentsOf: directory.appendingPathComponent("junit.xml"), encoding: .utf8)
        XCTAssertTrue(xml.contains("tests=\"1\" failures=\"1\""))
        XCTAssertTrue(xml.contains("name=\"Run completion\""))
    }

    func testJUnitWriteFailureDoesNotPreventTerminalArchiveCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = TestProject(name: "Commit", app: .init(projectPath: "App.xcodeproj", scheme: "App", bundleIdentifier: "org.example.app"), simulator: .init(deviceID: "device"), categories: [])
        let store = try ExecutionArtifactStore(directory: directory, project: project, selection: .all)
        let report = try JSONDecoder().decode(ExecutionReport.self, from: Data("{\"outcome\":\"blocked\",\"tests\":[]}".utf8))
        _ = try await store.append(.finished(report))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("junit.xml"), withIntermediateDirectories: false)
        try await store.finish(report)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("junit.xml").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("run.json").path))
        XCTAssertTrue(try RunSession.read(in: directory).closed)
    }
}
