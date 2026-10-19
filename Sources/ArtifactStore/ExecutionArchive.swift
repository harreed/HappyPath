import Foundation
import ProjectDomain
import RunnerCore

/// A file-backed view of a run, usable after the entire directory is moved.
/// Evidence resolves only inside this archive; historical absolute paths are never used.
public struct ExecutionArchive: Sendable {
    public let directory: URL
    public let sourceProjectSchemaVersion: Int
    public let project: TestProject
    public let selection: RunSelection
    public let events: [ExecutionEnvelope]
    public let report: ExecutionReport?
    public let recovery: ArchiveRecoveryManifest?

    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        let recoveryURL = directory.appendingPathComponent("recovery.json")
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            recovery = try JSONDecoder().decode(ArchiveRecoveryManifest.self, from: Data(contentsOf: recoveryURL))
            guard recovery?.schemaVersion == 1 else { throw ExecutionArtifactError.unsupportedFormat }
        } else { recovery = nil }
        let definition = try ProjectMigration.preview(data: Data(contentsOf: directory.appendingPathComponent("project.json")))
        sourceProjectSchemaVersion = definition.sourceVersion
        project = definition.project
        selection = try JSONDecoder().decode(RunSelection.self, from: Data(contentsOf: directory.appendingPathComponent("selection.json")))
        _ = try project.selectedTests(selection)
        events = try ExecutionArtifactStore.readEvents(in: directory)
        let reportURL = directory.appendingPathComponent("run.json")
        if recovery?.incomplete == true {
            guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw ExecutionArtifactError.invalidTerminalResult }
            report = nil
        } else if FileManager.default.fileExists(atPath: reportURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let terminal = try decoder.decode(ExecutionReport.self, from: Data(contentsOf: reportURL))
            guard case .finished(let recorded) = events.last?.event,
                  recorded.outcome == terminal.outcome,
                  recorded.tests.count == terminal.tests.count,
                  zip(recorded.tests, terminal.tests).allSatisfy({ $0.testID == $1.testID && $0.outcome == $1.outcome }) else {
                throw ExecutionArtifactError.invalidTerminalResult
            }
            report = terminal
        } else {
            // An unfinished run is inspectable but must not be inferred to have passed.
            report = nil
        }
    }

    public var review: ExecutionReview { get throws { try ExecutionReview(project: project, selection: selection, events: events) } }
    public var videoURL: URL? { evidenceURL(relativePath: "video.mp4") }
    public var readableReportURL: URL? { evidenceURL(relativePath: "report.md") }
    public func screenshotURL(for id: CaptureID) -> URL? { evidenceURL(relativePath: "captures/\(id.description).png") }
    public func rawSnapshotURL(for id: CaptureID) -> URL? { evidenceURL(relativePath: "captures/\(id.description).json") }
    public func snapshot(for id: CaptureID) -> UISnapshot? {
        events.lazy.compactMap { envelope in
            if case .capture(let snapshot) = envelope.event, snapshot.captureID == id { return snapshot }
            return nil
        }.first
    }

    /// Returns an existing regular file whose resolved path stays inside this archive.
    public func evidenceURL(relativePath: String) -> URL? {
        guard !relativePath.hasPrefix("/") else { return nil }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return candidate
    }
}
