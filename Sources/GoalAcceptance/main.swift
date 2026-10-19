import Foundation
import ProjectDomain
import RunnerCore
import SimulatorControl
import ArtifactStore
import ModelProviders
import CryptoKit
import Security

private struct SavedResources: Decodable {
    struct Credential: Decodable { let id: UUID; let name: String; let kind: String }
    let credentials: [Credential]
}

@main struct GoalAcceptance {
    static func main() async {
        do { try await run() }
        catch {
            fputs("Goal acceptance: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 4 ||
              (CommandLine.arguments.count == 5 && CommandLine.arguments[3] == "--test-id") else {
            throw NSError(domain: "GoalAcceptance", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: goal-acceptance PROJECT_DIRECTORY OUTPUT_DIRECTORY GOAL | --test-id UUID"])
        }
        let projectDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let source = try ProjectMigration.preview(data: Data(contentsOf: projectDirectory.appendingPathComponent("project.json"))).project
        let project: TestProject
        let selection: RunSelection
        if CommandLine.arguments[3] == "--test-id" {
            guard let id = UUID(uuidString: CommandLine.arguments[4]),
                  try source.selectedTests(.test(id)).first?.test.effectiveExecutionMode == .goal else {
                throw NSError(domain: "GoalAcceptance", code: 2, userInfo: [NSLocalizedDescriptionKey: "Choose an existing goal test UUID."])
            }
            project = source
            selection = .test(id)
        } else {
            let goal = CommandLine.arguments[3].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !goal.isEmpty, goal.count <= 8000 else { throw NSError(domain: "GoalAcceptance", code: 2, userInfo: [NSLocalizedDescriptionKey: "The goal must contain 1–8,000 characters."]) }
            let test = TestCase(name: goal, goal: goal, blocks: [], timeoutSeconds: 600)
            project = TestProject(id: source.id, name: source.name, app: source.app, simulator: source.simulator,
                categories: [.init(name: "Goal run", suites: [.init(name: "Live navigation", tests: [test])])],
                reviewedAlertPolicies: source.reviewedAlertPolicies, defaultRecoveryPolicy: source.defaultRecoveryPolicy)
            selection = .all
        }
        try project.validate()
        let store = try ExecutionArtifactStore(directory: outputDirectory, project: project, selection: selection)
        let inputs = CommandLine.arguments[3] == "--test-id" ? loadSavedInputs(projectDirectory: projectDirectory, projectID: project.id) : []
        print("Loaded \(inputs.count) saved input(s)")
        let engine = ExecutionEngine(driver: XCTestRunnerDriver(baseDirectory: projectDirectory, artifacts: outputDirectory),
            assertionEvaluator: AppleAssertionEvaluator(), failureSummariser: AppleFailureSummariser(),
            candidateChooser: JevCandidateChooser(transport: JevHTTPTransport.fromEnvironment()),
            goalNavigator: LayaGoalNavigator(), imageAssessor: ClefVisionProvider(),
            savedInputs: inputs)
        let handle = CommandLine.arguments[3] == "--test-id" ? engine.start(project: project, selection: selection) : engine.startGoal(project: project)
        let report = try await DurableExecution.consume(handle, persistence: store) { envelope in
            switch envelope.event {
            case .diagnostic(let message): print("\(envelope.sequence): \(message)")
            case .action(_, let action): print("\(envelope.sequence): action \(action)")
            case .recovery(let evidence): print("\(envelope.sequence): recovery \(evidence.status.rawValue): \(evidence.reason)")
            case .finished(let result): print("\(envelope.sequence): \(result.outcome.rawValue)")
            default: break
            }
        }
        print("Artifact directory: \(outputDirectory.path)")
        if report.outcome != .passed { throw NSError(domain: "GoalAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: "Goal run ended \(report.outcome.rawValue)"]) }
    }

    private static func loadSavedInputs(projectDirectory: URL, projectID: UUID) -> [GoalSavedInput] {
        guard let data = try? Data(contentsOf: projectDirectory.appendingPathComponent("resources.json")),
              let resources = try? JSONDecoder().decode(SavedResources.self, from: data) else { return [] }
        let scope = SHA256.hash(data: Data(projectDirectory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return resources.credentials.compactMap { credential in
            guard credential.kind == "Input" else { return nil }
            let account = "\(projectID.uuidString).\(scope).\(credential.id.uuidString).value"
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.agentic.TestWorkbench.resources",
                kSecAttrAccount as String: account, kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let value = result as? Data, let text = String(data: value, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return GoalSavedInput(name: credential.name, value: text)
        }
    }
}
