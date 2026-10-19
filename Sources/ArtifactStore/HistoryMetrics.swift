import Foundation
import CryptoKit
import ProjectDomain
import RunnerCore

public struct TestFingerprint: Codable, Hashable, Sendable {
    public let testID: UUID
    public let testName: String
    public let goal: String?
    public let successCriteria: String?
    public let executionMode: TestExecutionMode?
    public let blockTitles: [String]
    public let blockActions: [String]
    public let assertionHashes: [String]
    public let recoveryPolicyHash: String
    public let goalAssessmentPolicyHash: String
    public let timeoutSeconds: Int
    public let appBundleIdentifier: String
    public let simulatorDeviceID: String

    public init(project: TestProject, test: ProjectDomain.TestCase, categoryName: String, suiteName: String) {
        self.testID = test.id
        self.testName = test.name
        self.goal = test.goal
        self.successCriteria = test.successCriteria
        self.executionMode = test.effectiveExecutionMode
        self.blockTitles = test.effectiveExecutionMode == .scripted ? test.blocks.map(\.title) : []
        self.blockActions = test.effectiveExecutionMode == .scripted ? test.blocks.map { String(describing: $0.action) } : []
        self.assertionHashes = test.effectiveExecutionMode == .scripted ? test.assertions.map { Self.hashAssertion($0) } : []
        self.recoveryPolicyHash = Self.hashPolicy(test.effectiveExecutionMode == .goal ? project.defaultRecoveryPolicy : test.recoveryPolicy)
        self.goalAssessmentPolicyHash = Self.hashPolicy(test.goalAssessmentPolicy)
        self.timeoutSeconds = Int(test.timeoutSeconds)
        self.appBundleIdentifier = project.app.bundleIdentifier
        self.simulatorDeviceID = project.simulator.deviceID
    }

    private static func hashPolicy<P: Codable>(_ policy: P?) -> String {
        guard let policy else { return "none" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try? encoder.encode(policy)
        return data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "none"
    }

    private static func hashAssertion(_ assertion: AssertionDefinition) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try? encoder.encode(assertion)
        return data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "none"
    }

    public var compositeKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try? encoder.encode(self)
        return data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
    }
}

public struct TestMetrics: Codable, Sendable {
    public let fingerprint: TestFingerprint
    public let runCount: Int
    public let passedCount: Int
    public let failedCount: Int
    public let blockedCount: Int
    public let needsReviewCount: Int
    public let cancelledCount: Int
    public let incompleteCount: Int
    public let totalDurationSeconds: Double
    public let averageDurationSeconds: Double
    public let minDurationSeconds: Double
    public let maxDurationSeconds: Double
    public let lastRunDate: Date
    public let contributingRunIDs: [String]

    public var completedCount: Int { passedCount + failedCount + blockedCount + needsReviewCount }
    public var passRate: Double {
        guard completedCount > 0 else { return 0 }
        return Double(passedCount) / Double(completedCount)
    }
    public var flakinessScore: Double {
        guard completedCount >= 2 else { return 0 }
        let hasPassed = passedCount > 0
        let hasFailedOrReview = failedCount > 0 || needsReviewCount > 0
        return (hasPassed && hasFailedOrReview) ? 1.0 : 0.0
    }
}

public struct BlockMetrics: Codable, Sendable {
    public let blockID: UUID
    public let blockTitle: String
    public let testFingerprint: TestFingerprint
    public let runCount: Int
    public let totalDurationSeconds: Double
    public let averageDurationSeconds: Double
    public let outcomes: [String: Int]
}

public struct DateRange: Codable, Sendable {
    public let start: Date
    public let end: Date
    public init(_ start: Date, _ end: Date) { self.start = start; self.end = end }
}

public struct ProjectHistoryMetrics: Codable, Sendable {
    public let projectID: UUID
    public let projectName: String
    public let testMetrics: [TestMetrics]
    public let blockMetrics: [BlockMetrics]
    public let generatedAt: Date
    public let totalRunsAnalyzed: Int
    public let dateRange: DateRange?
}

public enum HistoryMetrics {
    public static func computeFingerprint(project: TestProject, test: ProjectDomain.TestCase, categoryName: String, suiteName: String) -> TestFingerprint {
        TestFingerprint(project: project, test: test, categoryName: categoryName, suiteName: suiteName)
    }

    public static func computeMetrics(from archives: [ExecutionArchive]) throws -> ProjectHistoryMetrics {
        var testMetricsMap: [String: TestMetricsBuilder] = [:]
        var blockMetricsMap: [String: BlockMetricsBuilder] = [:]
        var allRunDates: [Date] = []
        var allRunIDs: [String] = []

        for archive in archives {
            let review = try ExecutionReview(project: archive.project, selection: archive.selection, events: archive.events)
            let runDate = archive.events.first?.timestamp ?? Date()
            allRunDates.append(runDate)
            allRunIDs.append(archive.directory.lastPathComponent)

            for testReview in review.tests {
                let test = archive.project.categories.flatMap(\.suites).flatMap { $0.tests }.first { $0.id == testReview.id }
                let fingerprint = computeFingerprint(project: archive.project, test: test ?? ProjectDomain.TestCase(name: testReview.name, blocks: []), categoryName: testReview.categoryName, suiteName: testReview.suiteName)
                let key = fingerprint.compositeKey

                if testMetricsMap[key] == nil {
                    testMetricsMap[key] = TestMetricsBuilder(fingerprint: fingerprint)
                }
                testMetricsMap[key]!.add(testReview: testReview, runID: archive.directory.lastPathComponent, runDate: runDate)

                for blockReview in testReview.blocks {
                    let blockKey = "\(key)-\(blockReview.id)"
                    if blockMetricsMap[blockKey] == nil {
                        blockMetricsMap[blockKey] = BlockMetricsBuilder(blockID: blockReview.id, blockTitle: blockReview.title, testFingerprint: fingerprint)
                    }
                    blockMetricsMap[blockKey]!.add(blockReview: blockReview)
                }
            }
        }

        let testMetrics = testMetricsMap.values.map { $0.build() }
        let blockMetrics = blockMetricsMap.values.map { $0.build() }

        return ProjectHistoryMetrics(
            projectID: archives.first?.project.id ?? UUID(),
            projectName: archives.first?.project.name ?? "Unknown",
            testMetrics: testMetrics,
            blockMetrics: blockMetrics,
            generatedAt: Date(),
            totalRunsAnalyzed: archives.count,
            dateRange: allRunDates.isEmpty ? nil : DateRange(allRunDates.min()!, allRunDates.max()!)
        )
    }
}

private struct TestMetricsBuilder {
    let fingerprint: TestFingerprint
    var runCount = 0
    var passedCount = 0
    var failedCount = 0
    var blockedCount = 0
    var needsReviewCount = 0
    var cancelledCount = 0
    var incompleteCount = 0
    var durations: [Double] = []
    var contributingRunIDs: [String] = []

    mutating func add(testReview: ReviewedTest, runID: String, runDate: Date) {
        runCount += 1
        contributingRunIDs.append(runID)

        switch testReview.outcome {
        case .passed: passedCount += 1
        case .failed: failedCount += 1
        case .blocked: blockedCount += 1
        case .needsReview: needsReviewCount += 1
        case .cancelled: cancelledCount += 1
        case .none: incompleteCount += 1
        }

        if let duration = testReview.duration {
            durations.append(duration)
        }
    }

    func build() -> TestMetrics {
        let avg = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        let variance = durations.isEmpty ? 0 : durations.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(durations.count)
        let _ = sqrt(variance)
        let min = durations.min() ?? 0
        let max = durations.max() ?? 0

        return TestMetrics(
            fingerprint: fingerprint,
            runCount: runCount,
            passedCount: passedCount,
            failedCount: failedCount,
            blockedCount: blockedCount,
            needsReviewCount: needsReviewCount,
            cancelledCount: cancelledCount,
            incompleteCount: incompleteCount,
            totalDurationSeconds: durations.reduce(0, +),
            averageDurationSeconds: avg,
            minDurationSeconds: min,
            maxDurationSeconds: max,
            lastRunDate: contributingRunIDs.isEmpty ? Date() : Date(),
            contributingRunIDs: contributingRunIDs
        )
    }
}

private struct BlockMetricsBuilder {
    let blockID: UUID
    let blockTitle: String
    let testFingerprint: TestFingerprint
    var runCount = 0
    var durations: [Double] = []
    var outcomes: [String: Int] = [:]

    mutating func add(blockReview: ReviewedBlock) {
        runCount += 1
        if let duration = blockReview.duration { durations.append(duration) }
        let outcomeKey = blockReview.outcome.map { $0.rawValue } ?? "pending"
        outcomes[outcomeKey, default: 0] += 1
    }

    func build() -> BlockMetrics {
        let avg = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        return BlockMetrics(
            blockID: blockID,
            blockTitle: blockTitle,
            testFingerprint: testFingerprint,
            runCount: runCount,
            totalDurationSeconds: durations.reduce(0, +),
            averageDurationSeconds: avg,
            outcomes: outcomes
        )
    }
}
