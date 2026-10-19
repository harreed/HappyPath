import ArtifactStore
import Foundation
import RunnerCore
import SimulatorControl
#if os(macOS)
import Darwin
#else
import Glibc
#endif

private struct Arguments {
    let container: XcodeContainer
    let scheme: String
    let udid: String
    let productName: String
    let bundleIdentifier: String
    let artifacts: URL
    let derivedData: URL?
    let scriptedOnboarding: Bool

    init(_ raw: [String]) throws {
        func value(_ flag: String) throws -> String {
            guard let index = raw.firstIndex(of: flag), raw.indices.contains(index + 1) else {
                throw HarnessError.usage("Missing \(flag)")
            }
            return raw[index + 1]
        }

        let containerPath = try value("--container")
        switch try value("--container-kind") {
        case "project": container = .project(URL(fileURLWithPath: containerPath))
        case "workspace": container = .workspace(URL(fileURLWithPath: containerPath))
        default: throw HarnessError.usage("--container-kind must be project or workspace")
        }
        scheme = try value("--scheme")
        udid = try value("--udid")
        productName = try value("--product-name")
        bundleIdentifier = try value("--bundle-id")
        artifacts = URL(fileURLWithPath: try value("--artifacts"), isDirectory: true)
        derivedData = raw.contains("--derived-data")
            ? URL(fileURLWithPath: try value("--derived-data"), isDirectory: true)
            : nil
        scriptedOnboarding = raw.contains("--scripted-onboarding")
    }
}

private enum HarnessError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let detail):
            return """
            \(detail)

            Usage:
              phase0-harness \\
                --container-kind project|workspace \\
                --container /path/to/App.xcodeproj \\
                --scheme App \\
                --udid SIMULATOR-UDID \\
                --product-name App.app \\
                --bundle-id com.example.app \\
                --artifacts /path/to/runs [--derived-data /path/to/DerivedData] [--scripted-onboarding]
            """
        }
    }
}

@main
private struct Phase0Harness {
    static func main() async {
        do {
            #if os(macOS)
            try await run()
            #else
            throw SimulatorControllerError.unsupportedPlatform
            #endif
        } catch {
            FileHandle.standardError.write(Data("phase0-harness: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    #if os(macOS)
    private static func run() async throws {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        let store = try RunArtifactStore(baseDirectory: arguments.artifacts)
        let runID = await store.runID
        let layout = await store.layout
        var sequence: UInt64 = 1

        func log(_ kind: RunEventKind, _ message: String, captureID: CaptureID? = nil, path: String? = nil) async throws {
            try await store.append(RunEvent(
                sequence: sequence,
                runID: runID,
                kind: kind,
                message: message,
                captureID: captureID,
                artifactRelativePath: path
            ))
            sequence += 1
        }

        try await log(.runStarted, "Phase 0 lifecycle harness started")
        let derivedData = arguments.derivedData
            ?? layout.root.appendingPathComponent("DerivedData", isDirectory: true)
        try await log(.buildStarted, "Building \(arguments.scheme)")
        _ = try XcodeBuilder().build(XcodeBuildRequest(
            container: arguments.container,
            scheme: arguments.scheme,
            simulatorUDID: arguments.udid,
            derivedDataPath: derivedData
        ))
        try await log(.buildFinished, "Build succeeded")

        let app = derivedData
            .appendingPathComponent("Build/Products/Debug-iphonesimulator", isDirectory: true)
            .appendingPathComponent(arguments.productName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw HarnessError.usage("Built app not found at \(app.path); check --product-name")
        }

        let simulator = MacSimulatorController()
        try simulator.boot(udid: arguments.udid)
        try simulator.install(app: app, udid: arguments.udid)
        try await log(.appInstalled, "Installed \(app.lastPathComponent)")

        let recording = try simulator.startVideoRecording(to: layout.video, udid: arguments.udid)
        try await log(.recordingStarted, "Simulator recording started", path: "video.mp4")
        defer { try? recording.stop() }

        try simulator.launch(
            bundleIdentifier: arguments.bundleIdentifier,
            udid: arguments.udid,
            arguments: []
        )
        try await log(.appLaunched, "Launched \(arguments.bundleIdentifier)")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let captureID = CaptureID()
        let screenshot = layout.screenshotURL(stepIndex: 0, captureID: captureID)
        try simulator.captureScreenshot(to: screenshot, udid: arguments.udid)
        try await log(
            .captureCreated,
            "Captured launch state",
            captureID: captureID,
            path: "screenshots/\(screenshot.lastPathComponent)"
        )
        if arguments.scriptedOnboarding {
            var invocation = AppleToolCommands.build(XcodeBuildRequest(
                container: arguments.container, scheme: arguments.scheme,
                simulatorUDID: arguments.udid, derivedDataPath: derivedData
            )).arguments
            invocation.removeLast()
            invocation += ["test", "-only-testing:FixtureUITests/FixtureUITests/testOnboarding", "-parallel-testing-enabled", "NO", "-resultBundlePath",
                           layout.root.appendingPathComponent("onboarding.xcresult").path]
            let result = try FoundationProcessExecutor().run(ProcessInvocation(
                executableURL: AppleToolCommands.xcodebuild, arguments: invocation))
            try result.standardOutput.write(to: layout.root.appendingPathComponent("onboarding.log"),
                                          atomically: true, encoding: .utf8)
            try await log(.captureCreated, "Scripted onboarding passed: semantic actions, safe alert recovery, OCR fallback and final assertion. Step screenshots and event attachments retained in xcresult.", path: "onboarding.xcresult")
        }
        try recording.stop()
        try await log(.recordingStopped, "Simulator recording stopped", path: "video.mp4")
        try await log(.runFinished, "Lifecycle harness passed")

        print(layout.root.path)
    }
    #endif
}
