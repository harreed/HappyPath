import Foundation
import CryptoKit
import ProjectDomain
import RunnerCore
import SimulatorControl
import ModelProviders
import ArtifactStore

@main struct ProviderAcceptance {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent(CommandLine.arguments.dropFirst().first ?? "phase3-runs/providers/live-01")
        let baseline = try JSONDecoder().decode(TestProject.self, from: Data(contentsOf: root.appendingPathComponent("phase3-runs/recovery/known-alert-system-regression-03/project.json")))
        let base = baseline.categories[0].suites[0].tests[0]
        let jevUnavailable = CommandLine.arguments.dropFirst(2).first == "jev-unavailable"
        let tests: [ProjectDomain.TestCase] = jevUnavailable ? [base.replacing(name: "jev-unavailable", goal: "", assertions: [], recoveryPolicy: base.recoveryPolicy.replacing(allowTextFallback: false, candidateProvider: .jev))] : [
            base.replacing(name: "supported-semantic", goal: "The screen shows Welcome, Ada Recovery and onboarding is complete.", timeoutSeconds: 100, goalAssessmentPolicy: .init(timeoutSeconds: 60)),
            .init(name: "insufficient-semantic", goal: "Ada's account has been permanently saved to the remote server database.", blocks: [], timeoutSeconds: 80, goalAssessmentPolicy: .init(timeoutSeconds: 60)),
            .init(name: "explicit-image", goal: "The completion illustration is blue and visually centered.", blocks: [], goalAssessmentPolicy: .init(requirement: .image)),
            .init(name: "inferred-image", goal: "The completion illustration is blue and visually centered.", blocks: [], timeoutSeconds: 80, goalAssessmentPolicy: .init(timeoutSeconds: 60)),
            .init(name: "supported-ocr", goal: "The text Welcome, Ada Recovery is visible.", blocks: [], timeoutSeconds: 80, goalAssessmentPolicy: .init(requirement: .ocr, timeoutSeconds: 60)),
            .init(name: "deterministic-failure", goal: "The screen shows Welcome, Ada Recovery.", blocks: [], assertions: [.exists(.identifier("deliberately.absent"))], timeoutSeconds: 30)
        ]
        let project = baseline.replacing(name: "Gate 3C actual Apple assessment", categories: [.init(name: "Provider acceptance", suites: [.init(name: "Final evidence", tests: tests)])])
        let store = try ExecutionArtifactStore(directory: output, project: project, selection: .all)
        try retainSources(root: root, output: output)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(["appleTextAvailable": AppleAssertionEvaluator().availability == .available, "appleImageAvailable": false, "jevCredentialPresent": JevHTTPTransport.fromEnvironment().credentialsAvailable]).write(to: output.appendingPathComponent("availability.json"))
        let driver = XCTestRunnerDriver(baseDirectory: root, artifacts: output)
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: AppleAssertionEvaluator(), failureSummariser: AppleFailureSummariser(), candidateChooser: JevCandidateChooser(transport: JevHTTPTransport.fromEnvironment())).start(project: project)
        let report = try await DurableExecution.consume(handle, persistence: store) { envelope in
            switch envelope.event {
            case .diagnostic(let message): print(message)
            case .goalAssessment(let evidence): print("GOAL \(evidence.outcome.rawValue): \(evidence.reason)")
            case .failureSummary(let evidence): print("SUMMARY \(evidence.provider): \(evidence.text)")
            default: break
            }
        }
        // Jev-unavailable now falls back to the local reviewed policy and records
        // a providerFallback event, so the bounded dismissal still completes.
        let expectations: [RunOutcome] = jevUnavailable ? [.passed] : [.passed, .needsReview, .needsReview, .needsReview, .passed, .failed]
        let evidence = try ExecutionArtifactStore.readEvents(in: output)
        let captureIDs = evidence.compactMap { if case .capture(let s) = $0.event { return s.captureID }; return nil }
        let provenanceIDs = evidence.compactMap { if case .captureProvenance(let s) = $0.event { return s.snapshot.captureID }; return nil }
        guard captureIDs == provenanceIDs else { throw DriverFailure.unavailable("Capture provenance sequence mismatch") }
        let results = zip(tests, report.tests).map { ["test": $0.0.name, "outcome": $0.1.outcome.rawValue] }
        try encoder.encode(results).write(to: output.appendingPathComponent("acceptance-results.json"))
        print("TERMINAL \(report.outcome.rawValue): \(results)")
        guard report.tests.map(\.outcome) == expectations else { throw DriverFailure.unavailable("Unexpected provider acceptance outcome; retained for review") }
    }
    static func retainSources(root: URL, output: URL) throws {
        var paths = ["Package.swift", "Fixtures/OnboardingFixture/FixtureApp.swift", "Fixtures/OnboardingFixture/CompanionServiceTests.swift", "Fixtures/OnboardingFixture/OnboardingFixture.xcodeproj/project.pbxproj"]
        for folder in ["Sources", "Tests"] {
            if let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator where url.pathExtension == "swift" { paths.append(String(url.path.dropFirst(root.path.count + 1))) }
            }
        }
        var hashes: [String: String] = [:]
        for path in paths {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            hashes[path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let target = output.appendingPathComponent("source-evidence/" + path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        hashes["executed-binary"] = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(hashes).write(to: output.appendingPathComponent("source-hashes.json"))
    }
}
