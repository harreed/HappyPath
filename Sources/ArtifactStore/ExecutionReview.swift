import Foundation
import ProjectDomain
import RunnerCore

public struct ReviewedBlock: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public var outcome: RunOutcome?
    public var duration: Double?
    public var reason: String?
    public var before: CaptureID?
    public var after: CaptureID?
    public var captures: [CaptureID] = []
    public var firstSequence: Int?
    public var skipped = false
}

public struct ReviewedTest: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let categoryID: UUID
    public let categoryName: String
    public let suiteID: UUID
    public let suiteName: String
    public var outcome: RunOutcome?
    public var startedAt: Date?
    public var endedAt: Date?
    public var blocks: [ReviewedBlock]
    public var duration: Double? { guard let startedAt, let endedAt else { return nil }; return endedAt.timeIntervalSince(startedAt) }
}

/// A deterministic projection of durable events. A pending block is never inferred to have passed.
public struct ExecutionReview: Sendable {
    public let tests: [ReviewedTest]
    public let events: [ExecutionEnvelope]
    public let diagnostics: [String]
    public var completedCount: Int { tests.filter { $0.outcome != nil }.count }
    public func count(_ outcome: RunOutcome) -> Int { tests.filter { $0.outcome == outcome }.count }

    public init(project: TestProject, selection: RunSelection, events: [ExecutionEnvelope]) throws {
        let selected = try project.selectedTests(selection)
        let categoryNames = Dictionary(uniqueKeysWithValues: project.categories.map { ($0.id, $0.name) })
        var tests = selected.map { value in
            ReviewedTest(id: value.test.id, name: value.test.name, categoryID: value.categoryID,
                         categoryName: categoryNames[value.categoryID] ?? "Category", suiteID: value.suite.id,
                         suiteName: value.suite.name, blocks: value.test.blocks.map { ReviewedBlock(id: $0.id, title: $0.title) })
        }
        var currentTest: Int?
        var currentBlock: Int?
        var latestCapture: CaptureID?
        var pendingAfter = false
        var diagnostics: [String] = []
        for envelope in events {
            switch envelope.event {
            case .testStarted(let id):
                currentTest = tests.firstIndex { $0.id == id }; currentBlock = nil; latestCapture = nil; pendingAfter = false
                if let index = currentTest { tests[index].startedAt = envelope.timestamp }
            case .blockStarted(let id):
                currentBlock = currentTest.flatMap { index in tests[index].blocks.firstIndex { $0.id == id } }
                latestCapture = nil; pendingAfter = false
                if let t = currentTest, let b = currentBlock { tests[t].blocks[b].firstSequence = envelope.sequence }
            case .capture(let snapshot):
                if let t = currentTest, let b = currentBlock {
                    tests[t].blocks[b].captures.append(snapshot.captureID)
                    if pendingAfter { tests[t].blocks[b].after = snapshot.captureID; pendingAfter = false }
                }
                latestCapture = snapshot.captureID
            case .action(let id, _):
                if let t = currentTest, let b = currentBlock, tests[t].blocks[b].id == id {
                    tests[t].blocks[b].before = latestCapture
                    tests[t].blocks[b].after = nil
                    pendingAfter = true
                }
            case .blockFinished(let id, let outcome, let duration, let reason):
                if let t = currentTest, let b = tests[t].blocks.firstIndex(where: { $0.id == id }) {
                    tests[t].blocks[b].outcome = outcome; tests[t].blocks[b].duration = duration; tests[t].blocks[b].reason = reason
                }
                currentBlock = nil; latestCapture = nil; pendingAfter = false
            case .blockSkipped(let id):
                if let t = currentTest, let b = tests[t].blocks.firstIndex(where: { $0.id == id }) { tests[t].blocks[b].skipped = true }
            case .testFinished(let id, let outcome):
                if let index = tests.firstIndex(where: { $0.id == id }) { tests[index].outcome = outcome; tests[index].endedAt = envelope.timestamp }
                currentTest = nil; currentBlock = nil; latestCapture = nil; pendingAfter = false
            case .diagnostic(let reason): diagnostics.append(reason)
            default: break
            }
        }
        self.tests = tests; self.events = events; self.diagnostics = diagnostics
    }
}
