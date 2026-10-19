import Foundation
import ProjectDomain
import RunnerCore

public enum ProjectLifecycleError: LocalizedError {
    case companionRequired, missingTestConfiguration
    case buildFailed(String, String)
    public var errorDescription: String? {
        switch self {
        case .companionRequired: return "Configure an automation companion before running."
        case .missingTestConfiguration: return "The companion build did not produce exactly one test configuration."
        case .buildFailed(let phase, let reason): return "\(phase) failed: \(reason). Inspect the retained build log in this run."
        }
    }
}

/// Generic app and companion build/install lifecycle. All paths are resolved from the project bundle.
public actor ProjectSimulatorLifecycle {
    private let executor = SupervisedProcessExecutor()
    private let session = ManagedCompanionSession()
    public init() {}

    public func prepare(project: TestProject, baseDirectory: URL, artifacts: URL, deadline: Date, progress: @escaping @Sendable (ExecutionPhase) -> Void = { _ in }) async throws -> CompanionBridge {
        try project.validate()
        let environment = ProcessInfo.processInfo.environment
        let companionOverride = (environment["HAPPYPATH_COMPANION_PROJECT"] ?? environment["TEST_WORKBENCH_COMPANION_PROJECT"])
            .map { URL(fileURLWithPath: $0) }
        let dependencies = ProjectDependencies(base: baseDirectory,
            bundledCompanion: companionOverride ?? Bundle.main.resourceURL?.appendingPathComponent("Companion/Fixtures/OnboardingFixture/OnboardingFixture.xcodeproj"))
        try dependencies.validate(project)
        guard let companion = project.app.companion else { throw ProjectLifecycleError.companionRequired }
        let app = project.app
        let udid = project.simulator.deviceID
        func resolve(_ path: String) -> URL {
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDirectory.appendingPathComponent(path).standardizedFileURL
        }
        func buildArguments(path: String, scheme: String, derived: URL, operation: String) -> [String] {
            [path.hasSuffix(".xcworkspace") ? "-workspace" : "-project", resolve(path).path,
             "-scheme", scheme, "-configuration", app.configuration,
             "-destination", "platform=iOS Simulator,id=\(udid)", "-derivedDataPath", derived.path, operation]
        }
        let derived = resolve(app.derivedDataPath)
        let companionDerived = derived.appendingPathComponent("Companion")
        var xcodeEnvironment = ProcessInfo.processInfo.environment
        // SwiftPM probes local package paths with `git describe`. If a path is
        // not its own repository, climbing into the parent project repository
        // can stall an app-launched build under macOS file access mediation.
        // Local packages remain discoverable; only the parent search stops.
        let projectRoot = resolve(app.projectPath).deletingLastPathComponent().path
        let ceilings = xcodeEnvironment["GIT_CEILING_DIRECTORIES"].flatMap { $0.isEmpty ? nil : $0 }
        xcodeEnvironment["GIT_CEILING_DIRECTORIES"] = [ceilings, projectRoot].compactMap { $0 }.joined(separator: ":")
        func remaining(_ limit: Double) throws -> Double {
            try Task.checkCancellation()
            let time = deadline.timeIntervalSinceNow
            guard time > 0 else { throw SupervisedProcessError.timedOut(0) }
            return min(time, limit)
        }
        func build(_ invocation: ProcessInvocation, logName: String) async throws {
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            do { _ = try await executor.run(invocation, timeout: remaining(600), retainingOutputAt: artifacts.appendingPathComponent(logName)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ProjectLifecycleError.buildFailed(logName == "app-build.log" ? "Target app build" : "Automation companion build", error.localizedDescription) }
        }
        do {
            progress(.preparingSimulator)
            let devices = try await executor.run(AppleToolCommands.listAvailableDevices(), timeout: remaining(15))
            struct List: Decodable { struct Device: Decodable { let udid: String; let state: String }; let devices: [String: [Device]] }
            let list = try JSONDecoder().decode(List.self, from: Data(devices.standardOutput.utf8))
            guard list.devices.values.flatMap({ $0 }).contains(where: { $0.udid == udid }) else { throw ProjectValidationError.invalid("Selected Simulator is unavailable. Relink device in Project Dependencies.") }
            if list.devices.values.flatMap({ $0 }).first(where: { $0.udid == udid })?.state != "Booted" {
                _ = try await executor.run(AppleToolCommands.boot(udid: udid), timeout: remaining(30))
            }
            _ = try await executor.run(AppleToolCommands.waitUntilBooted(udid: udid), timeout: remaining(90))
            progress(.building)
            try await build(ProcessInvocation(executableURL: AppleToolCommands.xcodebuild,
                arguments: buildArguments(path: app.projectPath, scheme: app.scheme, derived: derived, operation: "build"),
                environment: xcodeEnvironment), logName: "app-build.log")
            let name = app.productName.hasSuffix(".app") ? app.productName : app.productName + ".app"
            let product = derived.appendingPathComponent("Build/Products/\(app.configuration)-iphonesimulator/\(name)")
            progress(.installing)
            _ = try await executor.run(AppleToolCommands.install(app: product, udid: udid), timeout: remaining(60))
            progress(.building)
            let companionBuildStartedAt = Date().addingTimeInterval(-1)
            try await build(ProcessInvocation(executableURL: AppleToolCommands.xcodebuild,
                arguments: buildArguments(path: try dependencies.companion(companion).path, scheme: companion.scheme, derived: companionDerived, operation: "build-for-testing")), logName: "companion-build.log")
            let products = companionDerived.appendingPathComponent("Build/Products")
            let configurations = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { url in
                    guard url.pathExtension == "xctestrun" else { return false }
                    let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    return modified.map { $0 >= companionBuildStartedAt } ?? false
                }
            guard configurations.count == 1, let xctestrun = configurations.first else { throw ProjectLifecycleError.missingTestConfiguration }
            progress(.startingCompanion)
            let bridge = try await session.start(xctestrun: xctestrun, testIdentifier: companion.testIdentifier,
                runnerBundleID: companion.runnerBundleIdentifier, mailboxRelativePath: companion.mailboxRelativePath,
                targetBundleID: app.bundleIdentifier, simulatorID: udid, artifacts: artifacts, timeout: remaining(60))
            progress(.recording)
            try await session.startRecording(to: artifacts.appendingPathComponent("video.mp4"))
            return bridge
        } catch { await session.stop(); throw error }
    }

    public func stop() async { await session.stop() }
    /// Applies a typed Simulator action to the project's selected device.
    public func performDeviceAction(_ action: DeviceAction, project: TestProject, deadline: Date) async throws {
        try Task.checkCancellation()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw SupervisedProcessError.timedOut(0) }
        let invocation = try DeviceCommands.invocation(action, udid: project.simulator.deviceID,
                                                       bundleIdentifier: project.app.bundleIdentifier)
        _ = try await executor.run(invocation, timeout: min(remaining, 30))
    }
    /// The requested changes are applied to the selected Simulator before a test.
    /// A failure stops execution rather than silently using an unknown state.
    public func applyStartingState(_ state: TestStartingState, project: TestProject, baseDirectory: URL, deadline: Date) async throws {
        guard !state.isDefault else { return }
        let udid = project.simulator.deviceID
        func run(_ arguments: [String]) async throws {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SupervisedProcessError.timedOut(0) }
            _ = try await executor.run(ProcessInvocation(executableURL: AppleToolCommands.xcrun, arguments: ["simctl"] + arguments), timeout: min(remaining, 60))
        }
        if state.keychain == .resetSimulator { try await run(["keychain", udid, "reset"]) }
        if state.appData == .reinstall {
            let app = project.app
            let derived = app.derivedDataPath.hasPrefix("/") ? URL(fileURLWithPath: app.derivedDataPath) : baseDirectory.appendingPathComponent(app.derivedDataPath).standardizedFileURL
            let name = app.productName.hasSuffix(".app") ? app.productName : app.productName + ".app"
            let product = derived.appendingPathComponent("Build/Products/\(app.configuration)-iphonesimulator/\(name)")
            try await run(["uninstall", udid, app.bundleIdentifier])
            try await run(["install", udid, product.path])
        }
        if state.permissions == .reset { try await run(["privacy", udid, "reset", "all", project.app.bundleIdentifier]) }
        switch state.appearance {
        case .unchanged: break
        case .light: try await run(["ui", udid, "appearance", "light"])
        case .dark: try await run(["ui", udid, "appearance", "dark"])
        }
        switch state.location {
        case .unchanged: break
        case .clear: try await run(["location", udid, "clear"])
        case .coordinate(let latitude, let longitude):
            try await run(["location", udid, "set", DeviceCommands.coordinate(latitude: latitude, longitude: longitude)])
        }
    }
    public func checkRecording() async throws { try await session.checkRecording() }
    public func finish() async throws { try await session.finish() }
}
