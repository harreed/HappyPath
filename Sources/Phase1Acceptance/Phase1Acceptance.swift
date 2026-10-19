import Foundation
import ProjectDomain
import RunnerCore
import SimulatorControl
import ArtifactStore

@main struct Phase1Acceptance {
    static func main() async {
        do { try await run() }
        catch { fputs("phase1-acceptance: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func argument(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        if let path = argument("--write-examples") {
            try writeAcceptanceProjects(at: URL(fileURLWithPath: path), repository: cwd)
            print("Wrote acceptance project bundles to \(path)"); return
        }
        guard let path = argument("--project"), let output = argument("--artifacts") else {
            throw NSError(domain: "Acceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: "Required --project and --artifacts"])
        }
        let bundle = URL(fileURLWithPath: path)
        let artifacts = URL(fileURLWithPath: output)
        guard !FileManager.default.fileExists(atPath: artifacts.path) else {
            throw NSError(domain: "Acceptance", code: 2, userInfo: [NSLocalizedDescriptionKey: "Artifacts directory must be new"])
        }
        let project = try ProjectBundleStore().load(from: bundle)
        let tests = try project.selectedTests(.all)
        guard let first = tests.first, let last = tests.last else {
            throw NSError(domain: "Acceptance", code: 3, userInfo: [NSLocalizedDescriptionKey: "Project must contain acceptance tests"])
        }
        let selection: RunSelection
        switch argument("--selection") ?? "all" {
        case "one": selection = .test(first.test.id)
        case "suite": selection = .suite(first.suite.id)
        case "category": selection = .category(first.categoryID)
        case "selection": selection = .selection(Set([first, last].map(\.test.id)))
        case "all": selection = .all
        default: throw NSError(domain: "Acceptance", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown selection mode"])
        }
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundle.appendingPathComponent("project.json"), to: artifacts.appendingPathComponent("project.json"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(selection).write(to: artifacts.appendingPathComponent("selection.json"))
        let eventsURL = artifacts.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        let file = try FileHandle(forWritingTo: eventsURL)
        defer { try? file.close() }
        let driver = XCTestRunnerDriver(baseDirectory: bundle, artifacts: artifacts)
        let handle = ExecutionEngine(driver: driver).start(project: project, selection: selection)
        if let delay = argument("--cancel-after"), let seconds = Double(delay) {
            Task { try? await Task.sleep(for: .seconds(seconds)); handle.cancel() }
        }
        struct Envelope: Encodable { let sequence: Int; let timestamp: Date; let event: ExecutionEvent }
        var sequence = 0
        var cancelAfterCapture = false
        do {
            for await event in handle.events {
                sequence += 1
                var data = try encoder.encode(Envelope(sequence: sequence, timestamp: Date(), event: event)); data.append(10)
                try file.write(contentsOf: data); try file.synchronize()
                if args.contains("--cancel-on-action") {
                    if case .action = event { cancelAfterCapture = true }
                    else if case .capture = event, cancelAfterCapture { handle.cancel(); cancelAfterCapture = false }
                }
            }
        } catch {
            handle.cancel(); _ = await handle.task.value
            throw error
        }
        let result = await handle.task.value
        try encoder.encode(result).write(to: artifacts.appendingPathComponent("run.json"), options: .atomic)
        try JUnitReport.write(in: artifacts, project: project, selection: selection, report: result)
        print("Outcome: \(result.outcome.rawValue); \(result.tests.count) tests; \(sequence) events; artifacts: \(artifacts.path)")
        if result.outcome != .passed { exit(2) }
    }
}
