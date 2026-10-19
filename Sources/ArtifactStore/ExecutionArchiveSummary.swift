import Foundation
import ProjectDomain
import RunnerCore

/// Metadata for a history row. Reading it never decodes the archive's event payloads.
public struct ExecutionArchiveSummary: Sendable {
    public let directory: URL
    public let title: String
    public let outcome: String
    public let resultCounts: String?
    public let date: Date
    public let duration: TimeInterval

    public init(directory: URL) throws {
        let project = try ProjectMigration.preview(data: Data(contentsOf: directory.appendingPathComponent("project.json"))).project
        let selection = try JSONDecoder().decode(RunSelection.self, from: Data(contentsOf: directory.appendingPathComponent("selection.json")))
        let selected = try project.selectedTests(selection)
        // A mapped event log lets us inspect its endpoints without decoding every
        // capture and event in a run. The full archive is loaded only when opened.
        let data = try Data(contentsOf: directory.appendingPathComponent("events.jsonl"), options: .mappedIfSafe)
        let first = data.firstIndex(of: 10).flatMap { newline in
            Self.timestamp(in: Data(data[..<newline]))
        }
        let lastLine = data.lastIndex(of: 10).flatMap { newline -> Data? in
            guard newline == data.count - 1 else { return nil }
            let start = data[..<newline].lastIndex(of: 10).map { $0 + 1 } ?? 0
            return Data(data[start..<newline])
        }
        let reportURL = directory.appendingPathComponent("run.json")
        let report: ExecutionReport?
        if FileManager.default.fileExists(atPath: reportURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let terminal = try decoder.decode(ExecutionReport.self, from: Data(contentsOf: reportURL))
            guard let lastLine,
                  let finalEvent = try? decoder.decode(ExecutionEnvelope.self, from: lastLine),
                  case .finished(let recorded) = finalEvent.event,
                  recorded.outcome == terminal.outcome,
                  recorded.tests.count == terminal.tests.count,
                  zip(recorded.tests, terminal.tests).allSatisfy({ $0.testID == $1.testID && $0.outcome == $1.outcome }) else {
                throw ExecutionArtifactError.invalidTerminalResult
            }
            report = terminal
        } else {
            report = nil
        }

        self.directory = directory
        switch selection {
        case .test:
            title = selected.first?.test.name ?? "Test run"
        case .suite(let id):
            title = project.categories.flatMap(\.suites).first(where: { $0.id == id })?.name ?? "Suite run"
        case .category(let id):
            title = project.categories.first(where: { $0.id == id })?.name ?? "Folder run"
        case .all:
            title = "All tests"
        case .selection:
            title = selected.count == 1 ? selected[0].test.name : "Selected tests"
        }
        outcome = report?.outcome.displayName ?? "Incomplete"
        if let report {
            let passed = report.tests.filter { $0.outcome == .passed }.count
            let failed = report.tests.filter { $0.outcome == .failed }.count
            let review = report.tests.filter { $0.outcome == .needsReview }.count
            let other = report.tests.count - passed - failed - review
            resultCounts = "\(passed) passed · \(failed) failed · \(review) need review" +
                (other > 0 ? " · \(other) other" : "")
        } else {
            resultCounts = nil
        }
        date = first ?? (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        duration = max(0, (lastLine.flatMap(Self.timestamp(in:)) ?? date).timeIntervalSince(date))
    }

    private static func timestamp(in data: Data) -> Date? {
        struct Header: Decodable { let timestamp: Date }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(Header.self, from: data).timestamp
    }
}
