import Foundation
import XCTest
import ProjectDomain
import ArtifactStore

final class SimulatorDiagnosticsTests: XCTestCase {
    func testCollectsOnlyMatchingCrashDuringRunAndWritesPortableEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = root.appendingPathComponent("run")
        let crashes = root.appendingPathComponent("crashes")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(60)
        func fixture(_ name: String, text: String, modified: Date) throws {
            let url = crashes.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        try fixture("Demo-001.ips", text: "bundleID: org.example.demo\nexception: test", modified: start.addingTimeInterval(5))
        try fixture("Demo-002.ips", text: "bundleID: org.example.other", modified: start.addingTimeInterval(10))
        try fixture("Demo-003.ips", text: "bundleID: org.example.demo", modified: start.addingTimeInterval(-100))
        try fixture("Other-004.ips", text: "bundleID: org.example.demo", modified: start.addingTimeInterval(10))
        let project = TestProject(name: "Demo", app: .init(projectPath: "Demo.xcodeproj", scheme: "Demo", bundleIdentifier: "org.example.demo"), simulator: .init(deviceID: "test-device"), categories: [])
        let collector = SimulatorDiagnosticsCollector(crashDirectory: crashes) { _, _, _, _, _ in "one relevant log line" }
        let manifest = try collector.collect(in: run, project: project, startedAt: start, endedAt: end)
        XCTAssertEqual(manifest.crashReports, ["crashes/Demo-001.ips"])
        XCTAssertNotNil(manifest.suspectedCause)
        XCTAssertEqual(manifest.deviceLogStatus, "Captured")
        XCTAssertEqual(try String(contentsOf: run.appendingPathComponent("device.log"), encoding: .utf8), "one relevant log line")
        XCTAssertEqual(SimulatorDiagnosticsManifest.read(in: run)?.crashReports, manifest.crashReports)
    }

    func testUnavailableLogAndNoCrashDoNotInventCause() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = TestProject(name: "Demo", app: .init(projectPath: "Demo.xcodeproj", scheme: "Demo", bundleIdentifier: "org.example.demo"), simulator: .init(deviceID: "test-device"), categories: [])
        let collector = SimulatorDiagnosticsCollector(crashDirectory: root.appendingPathComponent("missing")) { _, _, _, _, _ in nil }
        let manifest = try collector.collect(in: root, project: project, startedAt: Date(), endedAt: Date())
        XCTAssertNil(manifest.suspectedCause)
        XCTAssertTrue(manifest.crashReports.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("device.log").path))
    }
}
