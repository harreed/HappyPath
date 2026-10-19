import XCTest
import Foundation
import ProjectDomain
import ArtifactStore

final class ProjectPortabilityTests: XCTestCase {
    let fm = FileManager.default
    func temporary() throws -> URL { let url = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString); try fm.createDirectory(at: url, withIntermediateDirectories: true); return url }
    func historical() throws -> Data {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "LegacyProject", withExtension: "json"))
        return try Data(contentsOf: fixture)
    }
    func testHistoricalMigrationPreservesOnlyVersionChangeAndOriginalBytes() throws {
        let old = try historical(), preview = try ProjectMigration.preview(data: old)
        XCTAssertEqual(preview.sourceVersion, 1)
        var expected = try JSONSerialization.jsonObject(with: old) as! [String: Any]; expected["schemaVersion"] = 2
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: expected, options: .sortedKeys), try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: preview.converted), options: .sortedKeys))
        let dir = try temporary(); defer { try? fm.removeItem(at: dir) }
        try old.write(to: dir.appendingPathComponent("project.json")); try preview.commit(to: dir)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("migrations/\(preview.originalSHA256)/project.v1.json")), old)
        XCTAssertEqual(try ProjectBundleStore().load(from: dir), preview.project)
        XCTAssertEqual(try ProjectMigration.preview(data: preview.converted).changes, [])
    }
    func testInterruptedCommitAndConcurrentEditRetainDefinition() throws {
        let old = try historical(), preview = try ProjectMigration.preview(data: old), dir = try temporary()
        defer { try? fm.removeItem(at: dir) }; let file = dir.appendingPathComponent("project.json"); try old.write(to: file)
        XCTAssertThrowsError(try preview.commit(to: dir) { throw CocoaError(.fileWriteUnknown) })
        XCTAssertEqual(try Data(contentsOf: file), old)
        let changed = old + Data(" ".utf8)
        XCTAssertThrowsError(try preview.commit(to: dir) { try changed.write(to: file, options: .atomic) })
        XCTAssertEqual(try Data(contentsOf: file), changed)
    }
    func testFutureMalformedAndSymlinkRefuseWithoutMutation() throws {
        for data in [Data("{\"schemaVersion\":999}".utf8), Data("{\"schemaVersion\":1}".utf8), Data("broken".utf8), Data("{\"schemaVersion\":true}".utf8)] { XCTAssertThrowsError(try ProjectMigration.preview(data: data)) }
        let dir = try temporary(); defer { try? fm.removeItem(at: dir) }
        let old = try historical(); try old.write(to: dir.appendingPathComponent("project.json"))
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("migrations").path, withDestinationPath: "/tmp")
        XCTAssertThrowsError(try ProjectMigration.preview(data: old).commit(to: dir))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("project.json")), old)
    }
    func testExportSelectionNoOverwriteAndEscapes() throws {
        let parent = try temporary(); defer { try? fm.removeItem(at: parent) }
        let source = parent.appendingPathComponent("source"), destination = parent.appendingPathComponent("copy")
        try ProjectBundleStore().save(ProjectMigration.preview(data: historical()).project, to: source)
        let resources = Data("{\"skills\":[],\"credentials\":[]}".utf8)
        try resources.write(to: source.appendingPathComponent("resources.json"))
        for name in ["one", "two"] { let run = source.appendingPathComponent("runs/" + name); try fm.createDirectory(at: run, withIntermediateDirectories: true); try Data(name.utf8).write(to: run.appendingPathComponent("evidence")) }
        try ProjectBundleStore().export(from: source, to: destination, runs: .selected(["two"]))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: destination.appendingPathComponent("runs").path), ["two"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("project.json")), try Data(contentsOf: source.appendingPathComponent("project.json")))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("resources.json")), resources)
        XCTAssertThrowsError(try ProjectBundleStore().export(from: source, to: destination, runs: .all))
        XCTAssertThrowsError(try ProjectBundleStore().export(from: source, to: parent.appendingPathComponent("bad"), runs: .selected(["../escape"])))
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("references/link").path, withDestinationPath: "/tmp")
        XCTAssertThrowsError(try ProjectBundleStore().export(from: source, to: parent.appendingPathComponent("bad"), runs: .all))
    }
    func testExportRejectsChangedSourceBeforeCommit() throws {
        let parent = try temporary(); defer { try? fm.removeItem(at: parent) }
        let source = parent.appendingPathComponent("source"), destination = parent.appendingPathComponent("copy")
        try ProjectBundleStore().save(ProjectMigration.preview(data: historical()).project, to: source)
        let ref = source.appendingPathComponent("references/input"); try Data("before".utf8).write(to: ref)
        XCTAssertThrowsError(try ProjectBundleStore().export(from: source, to: destination, runs: .none) { try Data("after".utf8).write(to: ref) })
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: ref), Data("after".utf8))
    }
    func testExportRejectsNewOptionalRootsDuringCopy() throws {
        for added in ["references", "migrations", "resources.json"] {
            let parent = try temporary(); defer { try? fm.removeItem(at: parent) }
            let source = parent.appendingPathComponent("source"), dest = parent.appendingPathComponent("copy")
            try ProjectBundleStore().save(ProjectMigration.preview(data: historical()).project, to: source)
            if fm.fileExists(atPath: source.appendingPathComponent(added).path) { try fm.removeItem(at: source.appendingPathComponent(added)) }
            XCTAssertThrowsError(try ProjectBundleStore().export(from: source, to: dest, runs: .none) {
                if added == "resources.json" { try Data("{}".utf8).write(to: source.appendingPathComponent(added)) }
                else { try self.fm.createDirectory(at: source.appendingPathComponent(added), withIntermediateDirectories: false) }
            })
            XCTAssertFalse(fm.fileExists(atPath: dest.path))
        }
    }
    func testCompanionExplicitCurrentInstallationAndRelativeResolution() throws {
        let base = try temporary(); defer { try? fm.removeItem(at: base) }
        let current = base.appendingPathComponent("Current.xcodeproj"); try fm.createDirectory(at: current, withIntermediateDirectories: false)
        let resolver = ProjectDependencies(base: base, bundledCompanion: current)
        let config = CompanionConfiguration(projectPath: "/stale/Old.xcodeproj", scheme: "C", testIdentifier: "T", runnerBundleIdentifier: "R", resourceLocation: .bundledCompanion)
        XCTAssertEqual(try resolver.companion(config), current)
        let external = CompanionConfiguration(projectPath: "Custom.xcodeproj", scheme: "C", testIdentifier: "T", runnerBundleIdentifier: "R")
        XCTAssertEqual(try resolver.companion(external), base.appendingPathComponent("Custom.xcodeproj"))
        XCTAssertThrowsError(try ProjectDependencies(base: base, bundledCompanion: nil).companion(config))
    }
}
