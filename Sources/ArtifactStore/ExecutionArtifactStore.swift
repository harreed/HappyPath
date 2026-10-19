import Foundation
import ProjectDomain
import RunnerCore

public struct ExecutionEnvelope: Codable, Sendable {
    public let sequence: Int
    public let timestamp: Date
    public let event: ExecutionEvent
}

public enum ExecutionArtifactError: Error, LocalizedError {
    case directoryAlreadyExists
    case finalized
    case invalidSequence
    case unsupportedFormat
    case invalidTerminalResult

    public var errorDescription: String? {
        switch self {
        case .directoryAlreadyExists: return "This run folder already exists. Create a new run folder to preserve its evidence."
        case .finalized: return "The run's event log is closed and cannot accept more events."
        case .invalidSequence: return "The run event log is out of order or incomplete. Its results cannot be trusted."
        case .unsupportedFormat: return "This run uses an unsupported event format. Open a run created with this version of HappyPath."
        case .invalidTerminalResult: return "The saved run result disagrees with its final event. The archive cannot be displayed as a completed result."
        }
    }
}

/// Persist an event before delivering the returned envelope to presentation.
/// The immutable definition and selection are retained even if preparation fails.
public actor ExecutionArtifactStore {
    public nonisolated let directory: URL
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private var sequence = 0
    private var closed = false
    private var session = RunSession()

    public init(directory: URL, project: TestProject, selection: RunSelection) throws {
        try project.validate()
        _ = try project.selectedTests(selection)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw ExecutionArtifactError.directoryAlreadyExists }
        self.directory = directory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Millisecond precision matters for synchronized timeline/video seeking.
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let definitionEncoder = JSONEncoder()
        definitionEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try definitionEncoder.encode(project).write(to: directory.appendingPathComponent("project.json"), options: .atomic)
        try encoder.encode(selection).write(to: directory.appendingPathComponent("selection.json"), options: .atomic)
        try Data("{\"eventFormatVersion\":2,\"dateEncoding\":\"millisecondsSince1970\"}".utf8).write(to: directory.appendingPathComponent("artifact-format.json"), options: .atomic)
        let eventURL = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath: eventURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: eventURL)
        try session.write(in: directory)
    }

    deinit { try? handle.close() }

    @discardableResult
    public func append(_ event: ExecutionEvent, timestamp: Date = Date()) throws -> ExecutionEnvelope {
        guard !closed else { throw ExecutionArtifactError.finalized }
        let envelope = ExecutionEnvelope(sequence: sequence + 1, timestamp: timestamp, event: event)
        var bytes = try encoder.encode(envelope)
        bytes.append(10)
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        sequence += 1
        return envelope
    }

    public func finish(_ report: ExecutionReport) throws {
        guard !closed else { throw ExecutionArtifactError.finalized }
        try handle.synchronize()
        try Self.writeReadableReport(in: directory, report: report)
        try handle.close()
        closed = true
        // Terminal metadata is the commit record: an earlier report/flush/close
        // failure must remain an unfinished archive when reopened.
        try encoder.encode(report).write(to: directory.appendingPathComponent("run.json"), options: .atomic)
        session.closed = true
        try session.write(in: directory)
        // CI output is a derived projection. Its failure must not turn a committed
        // run into a persistence failure or conceal the canonical terminal result.
        try? JUnitReport.write(in: directory, report: report)
    }

    /// Releases the writer after a persistence failure without inventing a terminal result.
    /// The caller must also cancel and await the runner's resource cleanup.
    public func closeAfterFailure() {
        guard !closed else { return }
        closed = true
        try? handle.synchronize()
        try? handle.close()
        session.closed = true
        try? session.write(in: directory)
    }

    public static func readEvents(in directory: URL) throws -> [ExecutionEnvelope] {
        return try readEventsDirectly(in: directory)
    }

    private static func readEventsDirectly(in directory: URL) throws -> [ExecutionEnvelope] {
        let formatURL = directory.appendingPathComponent("artifact-format.json")
        guard FileManager.default.fileExists(atPath: formatURL.path) else { throw ExecutionArtifactError.unsupportedFormat }
        let formatData = try Data(contentsOf: formatURL)
        let formatObject = try JSONSerialization.jsonObject(with: formatData) as? [String: Any]
        guard formatObject?["eventFormatVersion"] as? Int == 2, formatObject?["dateEncoding"] as? String == "millisecondsSince1970" else { throw ExecutionArtifactError.unsupportedFormat }

        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let data = try Data(contentsOf: eventsURL)
        guard data.last == 10 || data.isEmpty else { throw ExecutionArtifactError.invalidSequence }
        let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var events: [ExecutionEnvelope] = []
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else { throw ExecutionArtifactError.invalidSequence }
            let envelope = try decoder.decode(ExecutionEnvelope.self, from: Data(line))
            guard envelope.sequence == index + 1 else { throw ExecutionArtifactError.invalidSequence }
            events.append(envelope)
        }
        return events
    }

    /// Exports the complete evidence directory. Never overwrites an existing destination.
    public static func export(directory: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: directory, to: destination)
    }

    private static func writeReadableReport(in directory: URL, report: ExecutionReport) throws {
        let project = try ProjectBundleStore().load(from: directory)
        let tests = try project.selectedTests(.all)
        let names = Dictionary(uniqueKeysWithValues: tests.map { ($0.test.id, $0.test.name) })
        let blocks = project.categories.flatMap(\.suites).flatMap { $0.setup + $0.tests.flatMap(\.blocks) + $0.teardown }
        let blockNames = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.title) })
        let events = try readEvents(in: directory)
        let selection = try JSONDecoder().decode(RunSelection.self, from: Data(contentsOf: directory.appendingPathComponent("selection.json")))
        let selected = try project.selectedTests(selection)
        let review = try ExecutionReview(project: project, selection: selection, events: events)
        func safe(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        var text = "# \(safe(project.name)) — Run report\n\nOutcome: **\(report.outcome.rawValue)**\n\n"
        if let first = events.first, let last = events.last {
            text += String(format: "Elapsed: %.2f seconds\n\n", last.timestamp.timeIntervalSince(first.timestamp))
        }
        text += "Selected tests: \(selected.count). Completed results: \(report.tests.count).\n\n"
        text += "| Category / Suite / Test | Outcome | Duration |\n| --- | --- | --- |\n"
        for item in selected {
            let outcome = report.tests.first { $0.testID == item.test.id }?.outcome.rawValue ?? "Pending"
            let duration = review.tests.first { $0.id == item.test.id }?.duration.map { String(format: "%.2fs", $0) } ?? "—"
            let category = project.categories.first { $0.id == item.categoryID }?.name ?? item.categoryID.uuidString
            text += "| \(safe(category)) / \(safe(item.suite.name)) / \(safe(item.test.name)) | \(outcome) | \(duration) |\n"
        }
        text += "\n## Timeline\n\n| Event | Elapsed | Detail |\n| --- | --- | --- |\n"
        for envelope in events {
            let detail: String
            switch envelope.event {
            case .candidateDecision(let evidence): detail = "Candidate provider \(evidence.provider): \(evidence.reason)"
            case .providerFallback(let evidence): detail = "Provider fallback (\(evidence.provider) → \(evidence.fallback)): \(evidence.reason)"
            case .goalAssessment(let evidence): detail = "Goal \(evidence.outcome.rawValue), \(evidence.request?.mode.rawValue ?? "unavailable"), provider \(evidence.provider): \(evidence.reason)"
            case .failureSummary(let evidence): detail = "Summary (\(evidence.provider)): \(evidence.text)"
            case .recovery(let evidence): detail = "Recovery \(evidence.status.rawValue): \(evidence.reason); capture \(evidence.captureID), choice \(evidence.choice?.candidateID.uuidString ?? "none"), confidence \(evidence.choice?.confidence.description ?? "none"), actions \(evidence.actionCount)/\(evidence.maximumActions)"
            case .locatorSuggestion(let suggestion): detail = "Review locator suggestion for \(blockNames[suggestion.blockID] ?? suggestion.blockID.uuidString): \(describe(suggestion.proposedTarget)); saved test unchanged"
            case .perception(let perception): detail = "OCR \(perception.provider): \(perception.regions.count) regions, capture \(perception.captureID)"
            case .visualComparison(let evidence): detail = "Visual reference \(evidence.matchesReference ? "matched" : "differed"): \(String(format: "%.2f%%", evidence.changedPixelFraction * 100)) changed pixels, capture \(evidence.captureID), reference SHA-256 \(evidence.referenceImageSHA256)"
            case .diagnostic(let message): detail = message
            case .blockFinished(let id, let outcome, let duration, let reason): detail = "\(blockNames[id] ?? id.uuidString): \(outcome.rawValue), \(String(format: "%.2fs", duration))\(reason.map { " — " + $0 } ?? "")"
            case .testFinished(let id, let outcome): detail = "\(names[id] ?? id.uuidString): \(outcome.rawValue)"
            case .assertion(let assertion, let passed): detail = "\(describe(assertion)): \(passed ? "passed" : "failed")"
            default: continue
            }
            let elapsed = envelope.timestamp.timeIntervalSince(events.first?.timestamp ?? envelope.timestamp)
            text += "| \(envelope.sequence) | \(String(format: "%.2fs", elapsed)) | \(safe(detail)) |\n"
        }
        text += "\n## Evidence\n\nThe full export includes the immutable [project definition](project.json), [selection](selection.json), [ordered event log](events.jsonl) and [terminal result](run.json). Screenshots, snapshots, video and runtime diagnostics remain in this directory.\n"
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("video.mp4").path) { text += "\n[Watch the run video](video.mp4)\n" }
        let diagnostics = [("App build log", "app-build.log"), ("Companion build log", "companion-build.log"), ("Recording log", "recording.log"), ("Recording timing", "recording-anchor.json")]
        for (label, path) in diagnostics where FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) {
            text += "\n[\(label)](\(path))\n"
        }
        // Every capture between blockStarted and blockFinished belongs to that block.
        // Only label before/after when a successful action event binds the pair.
        var activeBlock: UUID?
        var lastCapture: CaptureID?
        var pendingAfter: UUID?
        for envelope in events {
            switch envelope.event {
            case .blockStarted(let id): activeBlock = id; lastCapture = nil; pendingAfter = nil
            case .action(let id, _):
                if let lastCapture { text += evidenceLink(lastCapture, label: "\(blockNames[id] ?? id.uuidString) — before", directory: directory) }
                pendingAfter = id
            case .capture(let snapshot):
                if let id = pendingAfter {
                    text += evidenceLink(snapshot.captureID, label: "\(blockNames[id] ?? id.uuidString) — after", directory: directory)
                    pendingAfter = nil
                } else {
                    text += evidenceLink(snapshot.captureID, label: "\(activeBlock.flatMap { blockNames[$0] } ?? "Assertion or setup") — observation (event \(envelope.sequence))", directory: directory)
                }
                lastCapture = snapshot.captureID
            case .blockFinished: activeBlock = nil; lastCapture = nil; pendingAfter = nil
            default: break
            }
        }
        text += "\n## Recovery, perception and goal evidence\n\nReview is read-only. Explanatory summaries cannot change established outcomes.\n"
        for envelope in events {
            guard let detail = EvidencePresentation.detail(envelope.event) else { continue }
            text += "\n### Event \(envelope.sequence)\n\n"
            if let id = EvidencePresentation.sourceCapture(for: envelope, events: events) { text += evidenceLink(id, label: "Exact source capture", directory: directory) }
            if case .recovery(let value) = envelope.event, let id = value.verificationCaptureID { text += evidenceLink(id, label: "Separate verification capture", directory: directory) }
            if case .locatorSuggestion(let value) = envelope.event { text += evidenceLink(value.postActionCaptureID, label: "Post-action capture", directory: directory) }
            text += "\n" + detail.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") + "\n"
        }
        try Data(text.utf8).write(to: directory.appendingPathComponent("report.md"), options: .atomic)
    }

    private static func evidenceLink(_ id: CaptureID, label: String, directory: URL) -> String {
        let path = "captures/\(id.description).png"
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) else { return "\n- \(label): screenshot unavailable\n" }
        let safeLabel = label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
        return "\n- [\(safeLabel)](\(path)) · [raw snapshot](captures/\(id.description).json)\n"
    }
    private static func describe(_ target: TargetStrategy) -> String {
        switch target {
        case .identifier(let value): return "identifier ‘\(value)’"
        case .text(let value): return "text ‘\(value)’"
        case .semantic(let role, let label, let value): return [role.map { "role ‘\($0)’" }, label.map { "label ‘\($0)’" }, value.map { "value ‘\($0)’" }].compactMap { $0 }.joined(separator: ", ")
        }
    }
    private static func describe(_ assertion: AssertionDefinition) -> String {
        switch assertion {
        case .exists(let target): return "Element exists: \(describe(target))"
        case .doesNotExist(let target): return "Element is absent: \(describe(target))"
        case .valueEquals(let target, let value): return "\(describe(target)) equals ‘\(value)’"
        case .valueContains(let target, let value): return "\(describe(target)) contains ‘\(value)’"
        case .textVisible(let text): return "Text is visible: ‘\(text)’"
        case .imageMatches(let id, _, _, _): return "Screenshot matches approved reference \(id.uuidString)"
        }
    }
}
