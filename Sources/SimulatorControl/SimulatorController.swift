import Foundation
import RunnerCore

public struct SimulatorDevice: Codable, Equatable, Sendable {
    public let name: String
    public let udid: String
    public let state: String
    public let runtimeIdentifier: String

    public init(name: String, udid: String, state: String, runtimeIdentifier: String) {
        self.name = name
        self.udid = udid
        self.state = state
        self.runtimeIdentifier = runtimeIdentifier
    }
}

public protocol VideoRecordingSession: AnyObject, Sendable {
    var outputURL: URL { get }
    func stop() throws
}

public protocol SimulatorControlling: Sendable {
    func availableDevices() throws -> [SimulatorDevice]
    func boot(udid: String) throws
    func install(app: URL, udid: String) throws
    func launch(bundleIdentifier: String, udid: String, arguments: [String]) throws
    func terminate(bundleIdentifier: String, udid: String) throws
    func captureScreenshot(to output: URL, udid: String) throws
    func startVideoRecording(to output: URL, udid: String) throws -> any VideoRecordingSession
}

public enum SimulatorControllerError: Error {
    case unsupportedPlatform
    case malformedDeviceList
}

private struct SimctlDeviceList: Decodable {
    struct Device: Decodable {
        let name: String
        let udid: String
        let state: String
        let isAvailable: Bool?
    }

    let devices: [String: [Device]]
}

#if os(macOS)
public final class MacSimulatorController: SimulatorControlling, @unchecked Sendable {
    private let executor: any ProcessExecuting

    public init(executor: any ProcessExecuting = FoundationProcessExecutor()) {
        self.executor = executor
    }

    public func availableDevices() throws -> [SimulatorDevice] {
        let output = try executor.run(AppleToolCommands.listAvailableDevices()).standardOutput
        guard let data = output.data(using: .utf8) else {
            throw SimulatorControllerError.malformedDeviceList
        }
        let list = try JSONDecoder().decode(SimctlDeviceList.self, from: data)
        return list.devices.flatMap { runtime, devices in
            devices.compactMap { device in
                guard device.isAvailable != false else { return nil }
                return SimulatorDevice(
                    name: device.name,
                    udid: device.udid,
                    state: device.state,
                    runtimeIdentifier: runtime
                )
            }
        }.sorted { ($0.runtimeIdentifier, $0.name) < ($1.runtimeIdentifier, $1.name) }
    }

    public func boot(udid: String) throws {
        do {
            _ = try executor.run(AppleToolCommands.boot(udid: udid))
        } catch let error as ProcessExecutionError where error.result.standardError.contains("Unable to boot device in current state: Booted") {
            // Idempotent boot: proceed to bootstatus for an already-running device.
        }
        _ = try executor.run(AppleToolCommands.waitUntilBooted(udid: udid))
    }

    public func install(app: URL, udid: String) throws {
        _ = try executor.run(AppleToolCommands.install(app: app, udid: udid))
    }

    public func launch(bundleIdentifier: String, udid: String, arguments: [String]) throws {
        _ = try executor.run(
            AppleToolCommands.launch(bundleIdentifier: bundleIdentifier, udid: udid, arguments: arguments)
        )
    }

    public func terminate(bundleIdentifier: String, udid: String) throws {
        _ = try executor.run(AppleToolCommands.terminate(bundleIdentifier: bundleIdentifier, udid: udid))
    }

    public func captureScreenshot(to output: URL, udid: String) throws {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try executor.run(AppleToolCommands.screenshot(to: output, udid: udid))
    }

    public func startVideoRecording(to output: URL, udid: String) throws -> any VideoRecordingSession {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try MacVideoRecordingSession(outputURL: output, udid: udid)
    }
}

private final class MacVideoRecordingSession: VideoRecordingSession, @unchecked Sendable {
    let outputURL: URL
    private let process: Process
    private let lock = NSLock()
    private var stopped = false

    init(outputURL: URL, udid: String) throws {
        self.outputURL = outputURL
        process = Process()
        process.executableURL = AppleToolCommands.xcrun
        process.arguments = ["simctl", "io", udid, "recordVideo", "--codec=h264", "--force", outputURL.path]
        try process.run()
    }

    func stop() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        if process.isRunning {
            process.interrupt()
            process.waitUntilExit()
        }
        stopped = true
    }

    deinit {
        try? stop()
    }
}
#else
public final class MacSimulatorController: SimulatorControlling, @unchecked Sendable {
    public init(executor: any ProcessExecuting = FoundationProcessExecutor()) {}

    public func availableDevices() throws -> [SimulatorDevice] { throw SimulatorControllerError.unsupportedPlatform }
    public func boot(udid: String) throws { throw SimulatorControllerError.unsupportedPlatform }
    public func install(app: URL, udid: String) throws { throw SimulatorControllerError.unsupportedPlatform }
    public func launch(bundleIdentifier: String, udid: String, arguments: [String]) throws { throw SimulatorControllerError.unsupportedPlatform }
    public func terminate(bundleIdentifier: String, udid: String) throws { throw SimulatorControllerError.unsupportedPlatform }
    public func captureScreenshot(to output: URL, udid: String) throws { throw SimulatorControllerError.unsupportedPlatform }
    public func startVideoRecording(to output: URL, udid: String) throws -> any VideoRecordingSession {
        throw SimulatorControllerError.unsupportedPlatform
    }
}
#endif

public final class XcodeBuilder: @unchecked Sendable {
    private let executor: any ProcessExecuting

    public init(executor: any ProcessExecuting = FoundationProcessExecutor()) {
        self.executor = executor
    }

    public func build(_ request: XcodeBuildRequest) throws -> ProcessResult {
        #if os(macOS)
        return try executor.run(AppleToolCommands.build(request))
        #else
        throw SimulatorControllerError.unsupportedPlatform
        #endif
    }
}
