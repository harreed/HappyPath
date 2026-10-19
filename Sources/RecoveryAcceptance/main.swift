import Foundation
import CryptoKit
import RunnerCore
import ProjectDomain
import SimulatorControl
import ArtifactStore
import PerceptionCore

actor DelayedRecognizer: TextRecognizing {
    let underlying = VisionTextRecognizer()
    var remaining: Int
    let seconds: Double
    init(count: Int, seconds: Double) { remaining = count; self.seconds = seconds }
    func prewarm() async throws { try await underlying.prewarm() }
    func recognize(imageData: Data, capture: ScreenCapture, geometry: PerceptionGeometry) async throws -> TextPerception {
        if remaining > 0 { remaining -= 1; try await Task.sleep(for: .seconds(seconds)) }
        return try await underlying.recognize(imageData: imageData, capture: capture, geometry: geometry)
    }
}
final class Trace: @unchecked Sendable {
    let lock = NSLock()
    var values: [[String: String]] = []
    func add(_ event: String) { lock.lock(); values.append(["event": event, "at": String(Date().timeIntervalSince1970)]); lock.unlock() }
    func contains(_ event: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values.contains { $0["event"] == event } }
    func data() throws -> Data { lock.lock(); defer { lock.unlock() }; return try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) }
}
actor ProbeDriver: RunnerDriving {
    let underlying: XCTestRunnerDriver
    let scenario: String
    let artifacts: URL
    var control: ExecutionControl?
    var firstCapture = true
    init(_ underlying: XCTestRunnerDriver, scenario: String, artifacts: URL) { self.underlying = underlying; self.scenario = scenario; self.artifacts = artifacts }
    func install(_ control: ExecutionControl) { self.control = control }
    func prepare(project: TestProject, deadline: Date) async throws { try await underlying.prepare(project: project, deadline: deadline) }
    func prepare(project: TestProject, deadline: Date, progress: @escaping @Sendable (ExecutionPhase) -> Void) async throws { try await underlying.prepare(project: project, deadline: deadline, progress: progress) }
    func capture(deadline: Date) async throws -> UISnapshot {
        if firstCapture && scenario == "system-permission" { try await Task.sleep(for: .seconds(1)) }
        let snapshot = try await underlying.capture(deadline: deadline)
        if firstCapture && scenario == "paused-alert" { await control?.pause() }
        firstCapture = false
        return snapshot
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws {
        if scenario == "replaced-alert", case .recoveryTap(let id, _) = action {
            struct Timing: Codable {
                let captureID: CaptureID
                let captureStartedAt: Date
                let hostPerformStartedAt: Date
                let hostPerformCompletedAt: Date
                let captureAgeAtCompletionUpperBound: Double
                let failure: String?
            }
            guard let capture = await underlying.provenance(for: id) else { throw DriverFailure.unavailable("Probe provenance missing") }
            try await Task.sleep(for: .seconds(4.2))
            let start = Date()
            func record(_ failure: String?) throws {
                let completed = Date()
                let timing = Timing(captureID: id, captureStartedAt: capture.snapshot.capturedAt,
                    hostPerformStartedAt: start, hostPerformCompletedAt: completed,
                    captureAgeAtCompletionUpperBound: completed.timeIntervalSince(capture.snapshot.capturedAt), failure: failure)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
                try encoder.encode(timing).write(to: artifacts.appendingPathComponent("replacement-dispatch-timing.json"))
            }
            do { try await underlying.perform(action, deadline: deadline); try record(nil) }
            catch { try record(String(describing: error)); throw error }
        } else { try await underlying.perform(action, deadline: deadline) }
    }
    func provenance(for id: CaptureID) async -> CompanionCapture? { await underlying.provenance(for: id) }
    func recognizeText(for id: CaptureID, deadline: Date) async throws -> TextPerception { try await underlying.recognizeText(for: id, deadline: deadline) }
    func warmupPerception(deadline: Date) async throws -> PerceptionWarmup { try await underlying.warmupPerception(deadline: deadline) }
    func stop() async { await underlying.stop() }
    func finish() async throws { try await underlying.finish() }
}
struct BusyDeterministicDriver: RunnerDriving {
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot { .init(captureID: .init(), elements: [.init(identifier: nil, role: "staticText", label: "Deterministic evidence", value: nil, frame: nil)]) }
    func perform(_ action: DrivenAction, deadline: Date) async throws { throw DriverFailure.unavailable("Read-only proof") }
    func stop() async {}
}
final class StopOnOCR: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var cancel: (@Sendable () -> Void)?
    func install(_ cancel: @escaping @Sendable () -> Void) { lock.lock(); self.cancel = cancel; lock.unlock() }
    func event(_ event: String) {
        lock.lock()
        if event == "requestStarted" { count += 1 }
        let cancel = event == "requestStarted" && count == 2 ? self.cancel : nil
        lock.unlock(); cancel?()
    }
}
@main struct Acceptance {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { fatalError("RecoveryAcceptance <scenario> <new-output-directory>") }
        let scenarios: [String]
        if args[1] == "batch-extra" {
            scenarios = ["full-onboarding", "paused-alert", "replaced-alert", "offline-expected", "loading", "transient-forever", "permission", "system-permission", "sheet", "keyboard", "crash", "stop-ocr"]
        } else if args[1] == "batch" {
            scenarios = ["ocr", "known-alert", "safe-inferred", "expected-alert", "expected-authored", "disabled", "destructive", "ambiguous", "budget", "slow-recapture", "stale-exhausted", "offline", "auth", "loading", "transient-forever", "permission", "system-permission", "sheet", "keyboard", "crash", "stop-ocr"]
        } else if args[1].contains(",") { scenarios = args[1].split(separator: ",").map(String.init) }
        else { try await run(scenario: args[1], output: URL(fileURLWithPath: args[2])); return }
        var results: [[String: String]] = []
        for scenario in scenarios {
            do {
                try await run(scenario: scenario, output: URL(fileURLWithPath: args[2]).appendingPathComponent(scenario))
                results.append(["scenario": scenario, "acceptance": "passed"])
            } catch {
                // run() has already awaited DurableExecution cleanup before an outcome check can throw.
                results.append(["scenario": scenario, "acceptance": "failed", "reason": String(describing: error)])
            }
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[2]).appendingPathComponent("scenario-results.json"), options: .atomic)
        }
        guard results.allSatisfy({ $0["acceptance"] == "passed" }) else { throw DriverFailure.unavailable("One or more independently retained acceptance scenarios failed") }
    }

    static func run(scenario: String, output: URL) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if scenario == "vision-cancellation" {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let trace = Trace()
            let recognizer = VisionTextRecognizer { trace.add($0) }
            let task = Task { try await recognizer.prewarm() }
            let until = Date().addingTimeInterval(10)
            while !trace.contains("requestStarted") && Date() < until { try await Task.sleep(for: .milliseconds(5)) }
            guard trace.contains("requestStarted") else { throw DriverFailure.unavailable("Vision worker did not begin") }
            trace.add("stopRequested"); let stopped = Date(); task.cancel()
            do { try await task.value; throw DriverFailure.unavailable("Cancelled Vision returned success") }
            catch is CancellationError { trace.add("callerCancelled") }
            guard Date().timeIntervalSince(stopped) < 2 else { throw DriverFailure.unavailable("Stop was not prompt") }
            for attempt in 1...3 {
                do { try await VisionTextRecognizer().prewarm(); throw DriverFailure.unavailable("Concurrent request admitted after cancellation") }
                catch PerceptionFailure.workerBusy { trace.add("repeat\(attempt)RejectedBusy") }
            }
            let busyTest = ProjectDomain.TestCase(name: "Read-only production engine", blocks: [.init(title: "Deterministic assertion", action: .assertion(.textVisible("Deterministic evidence")))])
            let busyProject = TestProject(name: "Deterministic while real Vision busy", app: .init(projectPath: "ReadOnly.xcodeproj", scheme: "ReadOnly", bundleIdentifier: "read.only"), simulator: .init(deviceID: "no-simulator-used"), categories: [.init(name: "c", suites: [.init(name: "s", tests: [busyTest])])])
            let busyStore = try ExecutionArtifactStore(directory: output.appendingPathComponent("deterministic-while-busy"), project: busyProject, selection: .all)
            let busyHandle = ExecutionEngine(driver: BusyDeterministicDriver()).start(project: busyProject)
            let busyResult = try await DurableExecution.consume(busyHandle, persistence: busyStore) { _ in }
            guard busyResult.outcome == .passed, !trace.contains("workerFinished") else { throw DriverFailure.unavailable("Deterministic while busy proof failed") }
            trace.add("deterministicEnginePassedWhileWorkerBusy")
            let cleanupDeadline = Date().addingTimeInterval(90)
            while !trace.contains("workerFinished") && Date() < cleanupDeadline { try await Task.sleep(for: .milliseconds(10)) }
            try trace.data().write(to: output.appendingPathComponent("vision-lifecycle.json"))
            guard trace.contains("workerFinished") else { throw DriverFailure.unavailable("Vision OS worker did not finish within 90 seconds") }
            let deadlineTrace = Trace()
            let deadlineDriver = XCTestRunnerDriver(baseDirectory: root, artifacts: output, recognizer: VisionTextRecognizer { deadlineTrace.add($0) })
            let deadlineStarted = Date()
            var deadlineFailed = false
            do { _ = try await deadlineDriver.warmupPerception(deadline: Date().addingTimeInterval(0.02)) }
            catch DriverFailure.unavailable { deadlineTrace.add("deadlineReturned"); deadlineFailed = true }
            guard deadlineFailed else { throw DriverFailure.unavailable("Deadline did not interrupt Vision") }
            guard Date().timeIntervalSince(deadlineStarted) < 2 else { throw DriverFailure.unavailable("Perception deadline was not prompt") }
            let deadlineCleanup = Date().addingTimeInterval(90)
            while !deadlineTrace.contains("workerFinished") && Date() < deadlineCleanup { try await Task.sleep(for: .milliseconds(10)) }
            try deadlineTrace.data().write(to: output.appendingPathComponent("deadline-lifecycle.json"))
            guard deadlineTrace.contains("requestStarted"), deadlineTrace.contains("cancelRequested"), deadlineTrace.contains("workerFinished") else { throw DriverFailure.unavailable("Deadline proof missing actual worker lifecycle") }
            let retainedRoot = root.appendingPathComponent("phase3-runs/recovery/batch-01/ocr/captures")
            let captureURL = try FileManager.default.contentsOfDirectory(at: retainedRoot, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.first!
            let bound = try JSONDecoder().decode(CompanionCapture.self, from: Data(contentsOf: captureURL))
            let savedCapture = ScreenCapture(id: bound.snapshot.captureID, createdAt: bound.snapshot.capturedAt, pixelSize: .init(width: bound.pixelWidth, height: bound.pixelHeight), screenshotRelativePath: bound.screenshotName)
            let released = try await recognizer.recognize(imageData: Data(contentsOf: retainedRoot.appendingPathComponent(bound.screenshotName)), capture: savedCapture, geometry: .init(pixels: savedCapture.pixelSize, screenFrame: bound.screenFrame))
            guard !released.regions.isEmpty else { throw DriverFailure.unavailable("Released lease did not recognize real retained pixels") }
            let releasedEncoder = JSONEncoder(); releasedEncoder.dateEncodingStrategy = .millisecondsSince1970
            try releasedEncoder.encode(released).write(to: output.appendingPathComponent("successful-ocr-after-release.json"))
            print("Verified prompt caller cancellation/deadline; single-flight rejection and eventual OS worker completion. OS worker cancellation is not prompt.")
            return
        }
        let companion = CompanionConfiguration(projectPath: root.appendingPathComponent("Fixtures/OnboardingFixture/OnboardingFixture.xcodeproj").path,
            scheme: "CompanionService", testIdentifier: "FixtureUITests/CompanionServiceTests/testServe", runnerBundleIdentifier: "dev.agentic.FixtureUITests.xctrunner")
        let policy = ReviewedAlertPolicy(id: "fixture.optional-reminder.v1", bundleIdentifier: "dev.agentic.OnboardingFixture", alertIdentifier: "alert:Try reminders?",
            exactContext: "Try reminders?\nThis optional interruption is injected by the fixture.\nNot Now\nEnable",
            buttons: [.init(identifier: scenario == "full-onboarding" ? "fixture.alert.notNow" : nil, label: "Not Now", risk: .nonDestructiveDismissal), .init(identifier: scenario == "full-onboarding" ? "fixture.alert.enable" : nil, label: "Enable", risk: .unknown)],
            automaticButtonIdentifier: scenario == "full-onboarding" ? "fixture.alert.notNow" : nil, automaticButtonLabel: scenario == "safe-inferred" ? nil : "Not Now")
        let noAlert = ["ocr", "slow-recapture", "stale-exhausted", "stop-ocr"].contains(scenario)
        var launch = ["--recovery-probe"] + (noAlert ? ["--no-alert"] : [])
        if scenario == "full-onboarding" { launch = [] }
        if scenario == "replaced-alert" { launch.append("--replace-alert") }
        if scenario == "destructive" { launch.append("--destructive-alert") }
        if scenario == "ambiguous" { launch.append("--ambiguous-alert") }
        if ["offline", "offline-expected", "auth", "loading", "transient-forever", "permission", "system-permission", "sheet", "keyboard", "crash"].contains(scenario) { launch = ["--library-probe", scenario] }
        func block(_ title: String, _ action: BlockAction) -> TestBlock { .init(title: title, action: action, retryPolicy: .init(maximumAttempts: 1, timeoutSeconds: 45)) }
        var blocks = [block("Finish configured hidden text", .tap(targets: [.identifier("onboarding.hiddenFinish"), .text("Finish setup")]))]
        var assertions: [AssertionDefinition] = [.exists(.identifier("onboarding.complete")), .textVisible("Welcome, Ada Recovery")]
        if scenario == "full-onboarding" {
            blocks = [block("Enter exact name", .typeText("Ada Recovery", targets: [.identifier("onboarding.name")])), block("Continue onboarding", .tap(targets: [.identifier("onboarding.continue")])), block("Recover and finish", .tap(targets: [.text("Finish setup")]))]
        }
        if scenario == "replaced-alert" { blocks = [block("Reject changed context at dispatch", .tap(targets: [.identifier("missing")]))]; assertions = [.textVisible("Changed context: delete account.")] }
        if scenario == "known-alert" || scenario == "safe-inferred" {
            blocks = [block("Resolve greeting after automatic reminder dismissal", .typeText("", targets: [.identifier("missing")]))]
            // Use an authored tap on a visible label as a non-mutating resolution probe is inappropriate;
            // finish the real workflow instead, with both recovery actions explicitly budgeted.
            blocks = [block("Dismiss reminder then finish", .tap(targets: [.text("Finish setup")]))]
        }
        if ["disabled", "destructive", "ambiguous", "budget", "stale-exhausted"].contains(scenario) { assertions = [] }
        if scenario == "expected-authored" {
            blocks = [block("Assert expected reminder", .assertion(.exists(.semantic(role: "button", label: "Not Now", value: nil)))), block("Authored reminder dismissal", .tap(targets: [.semantic(role: "button", label: "Not Now", value: nil)]))]
            assertions = [.doesNotExist(.semantic(role: "button", label: "Not Now", value: nil)), .textVisible("Hello, Ada Recovery")]
        }
        if scenario == "expected-alert" {
            blocks = [block("Assert expected reminder", .assertion(.exists(.semantic(role: "button", label: "Not Now", value: nil)))), block("Attempt unresolved target while retaining expected prompt", .tap(targets: [.text("Finish setup")]))]
            assertions = [.exists(.semantic(role: "button", label: "Not Now", value: nil))]
        }
        if ["offline", "offline-expected", "auth", "loading", "transient-forever", "permission", "system-permission", "sheet", "keyboard", "crash"].contains(scenario) {
            blocks = [block("Resolve continue", .tap(targets: [.identifier("library.continue")]))]; assertions = []
        }
        if scenario == "system-permission" { blocks = [block("Observe real OS permission without input", .tap(targets: [.identifier("unresolved.system.prompt")]))]; assertions = [] }
        if scenario == "keyboard" {
            blocks.insert(block("Explicitly focus and type to show keyboard", .typeText("probe", targets: [.semantic(role: "textField", label: nil, value: nil)])), at: 0)
        }
        if scenario == "crash" { blocks = [block("Observe process exit while waiting", .wait(.textVisible("Will never appear")))]; assertions = [] }
        if scenario == "offline-expected" {
            blocks.insert(block("Assert intentional offline state", .assertion(.textVisible("No internet connection"))), at: 0)
            assertions = [.textVisible("Offline action acknowledged")]
        }
        let recovery = RecoveryPolicy(maximumActions: scenario == "disabled" ? 0 : (scenario == "budget" ? 1 : 3), timeoutSeconds: 40,
            allowTextFallback: scenario != "replaced-alert" && !["offline", "offline-expected", "auth", "loading", "transient-forever", "permission", "system-permission", "sheet", "keyboard", "crash"].contains(scenario), knownInterruptionPolicies: [policy.id],
            maximumRecaptures: scenario == "stale-exhausted" ? 0 : scenario == "loading" ? 10 : 3, maximumCaptureAge: 8,
            mode: scenario == "safe-inferred" ? .safeInferred : .knownAutomatic)
        let test = ProjectDomain.TestCase(name: scenario, blocks: blocks, assertions: assertions, recoveryPolicy: recovery, timeoutSeconds: 60)
        let project = TestProject(name: "Phase 3B " + scenario,
            app: .init(projectPath: companion.projectPath, scheme: "OnboardingFixture", bundleIdentifier: "dev.agentic.OnboardingFixture",
                derivedDataPath: root.appendingPathComponent("phase3-runs/recovery/DerivedData").path, launchArguments: launch, companion: companion),
            simulator: .init(deviceID: "BAF8410A-432D-4BEF-BC0A-4F50B7A50C5A"),
            categories: [.init(name: "Recovery", suites: [.init(name: "Production fixture", tests: [test])])], reviewedAlertPolicies: [policy])
        let store = try ExecutionArtifactStore(directory: output, project: project, selection: .all)
        if let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil) {
            var hashes: [String: String] = [:]
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                hashes[String(file.path.dropFirst(root.path.count + 1))] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            }
            hashes["Package.swift"] = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent("Package.swift"))).map { String(format: "%02x", $0) }.joined()
            for name in ["FixtureApp.swift", "CompanionServiceTests.swift"] {
                let path = "Fixtures/OnboardingFixture/" + name
                hashes[path] = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(path))).map { String(format: "%02x", $0) }.joined()
            }
            hashes["executed-binary"] = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))).map { String(format: "%02x", $0) }.joined()
            for path in hashes.keys where path != "executed-binary" {
                let destination = output.appendingPathComponent("source-evidence/" + path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: root.appendingPathComponent(path), to: destination)
            }
            try JSONEncoder().encode(hashes).write(to: output.appendingPathComponent("source-hashes.json"))
        }
        let trace = Trace(); let stopper = StopOnOCR()
        let recognizer: any TextRecognizing = ["slow-recapture", "stale-exhausted"].contains(scenario) ? DelayedRecognizer(count: 1, seconds: 8.1) : VisionTextRecognizer { event in
            trace.add(event); if scenario == "stop-ocr" { stopper.event(event) }
        }
        let driver = XCTestRunnerDriver(baseDirectory: root, artifacts: output, recognizer: recognizer)
        let probe = ProbeDriver(driver, scenario: scenario, artifacts: output)
        let handle = ExecutionEngine(driver: probe).start(project: project)
        await probe.install(handle.control)
        stopper.install { handle.cancel() }
        let result = try await DurableExecution.consume(handle, persistence: store) { envelope in
            switch envelope.event {
            case .state(.paused):
                if scenario == "paused-alert" { try? await Task.sleep(for: .seconds(8.2)); await handle.control.resume() }
            case .diagnostic(let message): print(message)
            case .recovery(let value): print("Recovery \(value.status.rawValue): \(value.reason)")
            default: break
            }
        }
        try trace.data().write(to: output.appendingPathComponent("vision-lifecycle.json"))
        let expected: RunOutcome = scenario == "stop-ocr" ? .cancelled : scenario == "crash" ? .blocked : ["disabled", "destructive", "ambiguous", "budget", "expected-alert", "stale-exhausted", "offline", "auth", "transient-forever", "permission", "system-permission", "sheet", "keyboard", "replaced-alert"].contains(scenario) ? .needsReview : .passed
        print("Outcome \(result.outcome.rawValue); expected \(expected.rawValue)")
        guard result.outcome == expected else { throw DriverFailure.unavailable("Unexpected acceptance outcome") }
        let retainedEvents = try ExecutionArtifactStore.readEvents(in: output)
        let captures = retainedEvents.compactMap { if case .capture(let capture) = $0.event { return capture.captureID }; return nil }
        let provenances = retainedEvents.compactMap { if case .captureProvenance(let capture) = $0.event { return capture.snapshot.captureID }; return nil }
        if scenario == "system-permission" {
            let observed = retainedEvents.contains { envelope in
                if case .recovery(let evidence) = envelope.event {
                    return evidence.interruption.kind == .permissionPrompt && evidence.interruption.elements.contains { $0.originBundleIdentifier == "com.apple.springboard" } && evidence.status == .refused
                }; return false
            }
            let input = retainedEvents.contains { envelope in
                switch envelope.event { case .actionStarted, .action: return true; default: return false }
            }
            guard observed && !input else { throw DriverFailure.unavailable("Missing actual system-origin permission review or unexpected input") }
        }
        guard captures == provenances else { throw DriverFailure.unavailable("Capture provenance was dropped by driver forwarding") }
    }
}
