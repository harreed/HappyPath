import Foundation
import ImageIO
import ModelProviders
import RunnerCore

private struct TrialCase {
    let name: String
    let target: String
    let expected: String
}

private let cases = [
    TrialCase(name: "accessible", target: "Apply name", expected: "Apply name"),
    TrialCase(name: "hidden", target: "Finish setup", expected: "Finish setup"),
    TrialCase(name: "off-center", target: "Create scenario", expected: "Create scenario"),
    TrialCase(name: "heading", target: "Create scenario", expected: "blocked"),
    TrialCase(name: "complete", target: "Scenario created", expected: "complete"),
    TrialCase(name: "no-progress", target: "Create scenario", expected: "Create scenario"),
    TrialCase(name: "moving", target: "Create scenario", expected: "Create scenario"),
]

private struct TrialOutput: Encodable {
    let caseName: String
    let expected: String
    let selected: String?
    let kind: String?
    let correct: Bool
    let elapsedMilliseconds: Int
    let candidates: [String]
    let reason: String?
    let error: String?
}

private struct ImageTrialOutput: Encodable {
    let caseName: String
    let question: String
    let providerID: String?
    let verdict: String?
    let confidence: Double?
    let imageSHA256: String?
    let elapsedMilliseconds: Int
    let error: String?
}

@main
struct ProviderTrials {
    static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "clef-live" {
            try await runLiveImage(path: CommandLine.arguments[2], question: CommandLine.arguments[3])
            return
        }
        guard CommandLine.arguments.count == 3, ["laya", "apple", "clef", "clef-narrow", "claude", "claude-narrow", "routed"].contains(CommandLine.arguments[1]) else {
            fputs("Usage: provider-trials <laya|apple|clef|clef-narrow|claude|claude-narrow|routed> <ocr-targeting-evidence/live directory> | clef-live PNG QUESTION\n", stderr)
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        if ["clef", "clef-narrow", "claude", "claude-narrow", "routed"].contains(CommandLine.arguments[1]) {
            try await runImages(root: root, providerName: CommandLine.arguments[1])
            return
        }
        var outputs: [TrialOutput] = []
        for trial in cases {
            let started = Date()
            do {
                let (request, labels, _) = try makeRequest(root: root, trial: trial)
                let result = try await (CommandLine.arguments[1] == "apple"
                    ? AppleGoalNavigator().decide(request)
                    : LayaGoalNavigator().decide(request))
                let kind: String
                let selected: String
                switch result.kind {
                case .act:
                    kind = "act"
                    selected = labels[result.candidateID ?? ""] ?? "unknown"
                case .complete: kind = "complete"; selected = "complete"
                case .blocked: kind = "blocked"; selected = "blocked"
                }
                outputs.append(.init(caseName: trial.name, expected: trial.expected,
                    selected: selected, kind: kind, correct: selected == trial.expected,
                    elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                    candidates: Array(labels.values).sorted(), reason: result.reason, error: nil))
            } catch {
                outputs.append(.init(caseName: trial.name, expected: trial.expected,
                    selected: nil, kind: nil, correct: false,
                    elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                    candidates: [], reason: nil, error: String(describing: error)))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(outputs), as: UTF8.self))
    }

    private static func runLiveImage(path: String, question: String) async throws {
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            throw TrialError.invalidImage
        }
        let capture = ScreenCapture(id: CaptureID(), createdAt: Date(),
            pixelSize: .init(width: width, height: height), screenshotRelativePath: path)
        let request = ImageAssessmentRequest(capture: capture, imageData: image,
            question: question, deadline: Date().addingTimeInterval(30), purpose: .archivedReadOnly)
        let started = Date()
        let result = try await ImageAssessmentGate().assess(request, with: ClefVisionProvider(),
            choice: .allowRemoteForThisRun, minimumConfidence: 0)
        let output = ImageTrialOutput(caseName: "live-simulator", question: question,
            providerID: result.providerID,
            verdict: result.verdict.rawValue, confidence: result.confidence,
            imageSHA256: result.imageSHA256,
            elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000), error: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
    }

    private static func runImages(root: URL, providerName: String) async throws {
        var outputs: [ImageTrialOutput] = []
        for trial in cases {
            let started = Date()
            do {
                let (navigation, _, snapshot) = try makeRequest(root: root, trial: trial)
                let criteria = navigation.successCriteria.isEmpty ? navigation.goal : navigation.successCriteria
                let question: String
                if providerName.hasSuffix("-narrow"), criteria.hasSuffix(" is visible") {
                    let exactText = String(criteria.dropLast(" is visible".count))
                    question = "Does this single screenshot visibly contain the exact completion text \"\(exactText)\"? Count only those words rendered on screen. A button or heading describing an action does not prove its result. If the text is absent, choose notSatisfied."
                } else {
                    question = criteria
                }
                let directory = root.appendingPathComponent(trial.name, isDirectory: true)
                let filename = snapshot.captureID.rawValue.uuidString.lowercased()
                let metadata = try object(at: directory.appendingPathComponent("captures/\(filename).json"))
                guard let width = metadata["pixelWidth"] as? Int,
                      let height = metadata["pixelHeight"] as? Int else { throw TrialError.invalidJSON }
                let image = try Data(contentsOf: directory.appendingPathComponent("captures/\(filename).png"))
                let capture = ScreenCapture(id: snapshot.captureID, createdAt: snapshot.capturedAt,
                    pixelSize: .init(width: width, height: height),
                    screenshotRelativePath: "captures/\(filename).png")
                let request = ImageAssessmentRequest(capture: capture, imageData: image,
                    question: question, deadline: Date().addingTimeInterval(30), purpose: .archivedReadOnly)
                let provider: any ImageAssessing = providerName.hasPrefix("claude")
                    ? ClaudeVisionProvider() : ClefVisionProvider()
                let result: ImageAssessment
                if providerName == "routed" {
                    result = try await ImageAssessmentRouter(primary: ClefVisionProvider(),
                        fallback: ClaudeVisionProvider(), primaryMinimumConfidence: 0.4,
                        fallbackMinimumConfidence: 0.8)
                        .assess(request, choice: .allowRemoteForThisRun)
                } else {
                    result = try await ImageAssessmentGate().assess(request,
                        with: provider, choice: .allowRemoteForThisRun, minimumConfidence: 0)
                }
                outputs.append(.init(caseName: trial.name, question: question,
                    providerID: result.providerID,
                    verdict: result.verdict.rawValue, confidence: result.confidence,
                    imageSHA256: result.imageSHA256,
                    elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000), error: nil))
            } catch {
                outputs.append(.init(caseName: trial.name, question: trial.target,
                    providerID: nil, verdict: nil, confidence: nil, imageSHA256: nil,
                    elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                    error: String(describing: error)))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(outputs), as: UTF8.self))
    }

    private static func makeRequest(root: URL, trial: TrialCase) throws -> (GoalNavigationRequest, [String: String], UISnapshot) {
        let directory = root.appendingPathComponent(trial.name, isDirectory: true)
        let project = try object(at: directory.appendingPathComponent("project.json"))
        guard let app = project["app"] as? [String: Any], let bundleID = app["bundleIdentifier"] as? String,
              let categories = project["categories"] as? [[String: Any]],
              let tests = categories.flatMap({ ($0["suites"] as? [[String: Any]] ?? []).flatMap({ $0["tests"] as? [[String: Any]] ?? [] }) }) as [[String: Any]]?,
              let test = tests.first(where: { !((($0["goal"] as? String) ?? "").isEmpty) }),
              let goal = test["goal"] as? String,
              let criteria = test["successCriteria"] as? String else {
            throw TrialError.missingProject
        }
        var perceptions: [String: TextPerception] = [:]
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        if let lines = try? String(contentsOf: eventsURL, encoding: .utf8).split(separator: "\n") {
            for line in lines {
                guard let wrapper = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let event = wrapper["event"] as? [String: Any],
                      let perception = event["perception"] as? [String: Any],
                      let value = perception["_0"],
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let decoded = try? JSONDecoder().decode(TextPerception.self, from: data) else { continue }
                perceptions[decoded.captureID.rawValue.uuidString] = decoded
            }
        }
        let capturesURL = directory.appendingPathComponent("captures", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: capturesURL.path).filter { $0.hasSuffix(".json") }
        var matches: [(UISnapshot, TextPerception?)] = []
        for name in names {
            let capture = try object(at: capturesURL.appendingPathComponent(name))
            guard let snapshotObject = capture["snapshot"],
                  let data = try? JSONSerialization.data(withJSONObject: snapshotObject),
                  let snapshot = try? JSONDecoder().decode(UISnapshot.self, from: data) else { continue }
            let perception = perceptions[snapshot.captureID.rawValue.uuidString]
            let visible = snapshot.elements.contains { ($0.label ?? "").localizedCaseInsensitiveContains(trial.target) } ||
                (perception?.regions.contains { $0.text.localizedCaseInsensitiveContains(trial.target) } ?? false)
            if visible { matches.append((snapshot, perception)) }
        }
        guard let (snapshot, perception) = matches.sorted(by: { $0.0.capturedAt < $1.0.capturedAt }).first else {
            throw TrialError.missingCapture
        }
        let candidates = GoalNavigationSafety.candidates(in: snapshot, appBundleID: bundleID) +
            (perception.map { GoalNavigationSafety.ocrCandidates($0, snapshot: snapshot, appBundleID: bundleID) } ?? [])
        let recognized = perception?.regions.map(\.text) ?? []
        let request = GoalNavigationRequest(goal: goal, successCriteria: criteria, snapshot: snapshot,
            candidates: candidates, recentActions: [], recognizedText: recognized)
        return (request, Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.label) }), snapshot)
    }

    private static func object(at url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw TrialError.invalidJSON
        }
        return value
    }

    private enum TrialError: Error { case missingProject, missingCapture, invalidJSON, invalidImage }
}
