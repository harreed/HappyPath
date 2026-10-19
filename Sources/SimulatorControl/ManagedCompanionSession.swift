import Foundation
import RunnerCore
import AVFoundation

public enum CompanionRecordingError: LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }
}

/// Owns one XCTest service and its simulator runner. Configuration contains no target-specific identifiers.
public actor ManagedCompanionSession {
    private let executor = SupervisedProcessExecutor()
    private var service: SupervisedProcessHandle?
    private var recording: SupervisedProcessHandle?
    private var bridge: CompanionBridge?
    private var simulatorID: String?
    private var runnerBundleID: String?
    private var artifacts: URL?
    private var recordingURL: URL?
    private var recordingFailure: String?

    public init() {}

    public func start(xctestrun: URL, testIdentifier: String, runnerBundleID: String,
                      mailboxRelativePath: String, targetBundleID: String, simulatorID: String,
                      artifacts: URL, timeout: Double = 60) async throws -> CompanionBridge {
        guard service == nil else { throw CompanionConfigurationError.missingTestBundle }
        self.simulatorID = simulatorID; self.runnerBundleID = runnerBundleID
        self.artifacts = artifacts
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let configured = artifacts.appendingPathComponent("companion.xctestrun")
        try CompanionTestConfiguration.write(source: xctestrun, destination: configured, targetBundleID: targetBundleID)
        let start = Date()
        do {
            service = try executor.start(ProcessInvocation(executableURL: AppleToolCommands.xcodebuild,
                arguments: ["test-without-building", "-xctestrun", configured.path,
                            "-destination", "platform=iOS Simulator,id=\(simulatorID)",
                            "-only-testing:\(testIdentifier)", "-parallel-testing-enabled", "NO",
                            "-resultBundlePath", artifacts.appendingPathComponent("companion.xcresult").path]))
            try RunResourceRecord.record(in: artifacts, role: "companion host and external Simulator runner", pid: service?.processID, simulatorID: simulatorID, bundleIdentifier: runnerBundleID)
            let deadline = start.addingTimeInterval(timeout)
            while Date() < deadline {
                try Task.checkCancellation()
                guard service?.isRunning == true else { throw CompanionConfigurationError.missingTestBundle }
                if let result = try? await executor.run(ProcessInvocation(executableURL: AppleToolCommands.xcrun,
                    arguments: ["simctl", "get_app_container", simulatorID, runnerBundleID, "data"]), timeout: min(5, max(0.1, deadline.timeIntervalSinceNow))) {
                    let directory = URL(fileURLWithPath: result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
                        .appendingPathComponent(mailboxRelativePath)
                    let candidate = CompanionBridge(directory: directory, bundleID: targetBundleID)
                    do {
                        try await candidate.connect(timeout: min(1, max(0.1, deadline.timeIntervalSinceNow)), startedAfter: start)
                        bridge = candidate
                        return candidate
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* Runner installed but the new service is not ready yet. */ }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CompanionFailure.timeout
        } catch {
            await stop()
            throw error
        }
    }

    public func startRecording(to url: URL) async throws {
        guard let simulatorID, recording == nil else { throw CompanionFailure.lostSession }
        let spawned = Date()
        recording = try executor.start(ProcessInvocation(executableURL: AppleToolCommands.xcrun,
            arguments: ["simctl", "io", simulatorID, "recordVideo", "--codec=h264", "--force", url.path]))
        try RunResourceRecord.record(in: url.deletingLastPathComponent(), role: "video recorder", pid: recording?.processID, simulatorID: simulatorID)
        recordingURL = url
        let deadline = spawned.addingTimeInterval(15)
        while Date() < deadline {
            try Task.checkCancellation()
            try checkRecording()
            if let output = try recording?.currentOutput(), output.standardError.contains("Recording started") {
                let anchor = RecordingAnchor(processStartedAt: spawned, markerObservedAt: output.observedAt)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
                try encoder.encode(anchor).write(to: url.deletingLastPathComponent().appendingPathComponent("recording-anchor.json"), options: .atomic)
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        recordingFailure = "Recording did not acknowledge startup within 15 seconds"
        throw CompanionRecordingError.failed(recordingFailure!)
    }

    public func checkRecording() throws {
        guard recording?.isRunning == true else {
            let output = try? recording?.currentOutput()
            if output?.standardError.contains("Host recording is already in progress") == true {
                recordingFailure = "Simulator video recording is busy. Stop the other recording or restart the selected Simulator, then retry."
            } else {
                recordingFailure = "Simulator video recording stopped unexpectedly. See recording.log in the run artifacts."
            }
            throw CompanionRecordingError.failed(recordingFailure!)
        }
    }

    public func finish() async throws {
        await stop()
        if let recordingFailure { throw CompanionRecordingError.failed(recordingFailure) }
        guard let recordingURL else { return }
        let asset = AVURLAsset(url: recordingURL)
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite && duration > 0 else { throw CompanionRecordingError.failed("Recording has no valid duration") }
            let frame = try await AVAssetImageGenerator(asset: asset).image(at: .zero)
            guard frame.image.width > 0 && frame.image.height > 0 else { throw CompanionRecordingError.failed("Recording has no decodable frame") }
        } catch {
            throw CompanionRecordingError.failed("Required video could not be finalized: \(error)")
        }
    }

    public func stop() async {
        await Task.detached { await self.finishStop() }.value
    }

    private func finishStop() async {
        await bridge?.invalidate()
        bridge = nil
        if let recording {
            await recording.stop(signal: 2, grace: 5)
            var result: ProcessResult?
            do { result = try await recording.wait(timeout: 3) }
            catch let error as ProcessExecutionError {
                result = error.result
                if recordingFailure == nil { recordingFailure = "Recording exited with code \(error.result.exitCode)" }
            }
            catch { if recordingFailure == nil { recordingFailure = "Recording finalization failed: \(error)" } }
            if let result, let artifacts {
                try? Data(("Exit code: \(result.exitCode)\n" + result.standardOutput + "\n" + result.standardError).utf8)
                    .write(to: artifacts.appendingPathComponent("recording.log"), options: .atomic)
            }
        }
        recording = nil
        // XCTest is hosted by CoreSimulator, outside xcodebuild's process group.
        // Stop the exact runner bundle we own before stopping the parent process.
        if service != nil, let simulatorID, let runnerBundleID {
            do {
                _ = try await executor.run(AppleToolCommands.terminate(bundleIdentifier: runnerBundleID, udid: simulatorID), timeout: 5)
                if let artifacts { try? Data("Runner termination succeeded\n".utf8).write(to: artifacts.appendingPathComponent("cleanup.log")) }
            } catch {
                if let artifacts { try? Data("Runner termination returned: \(error)\n".utf8).write(to: artifacts.appendingPathComponent("cleanup.log")) }
            }
        }
        if let service {
            await service.stop(signal: 15, grace: 2)
            var result: ProcessResult?
            do { result = try await service.wait(timeout: 3) }
            catch let error as ProcessExecutionError { result = error.result }
            catch {}
            if let result, let artifacts,
               !FileManager.default.fileExists(atPath: artifacts.appendingPathComponent("secure-input-used").path) {
                try? Data((result.standardOutput + "\n" + result.standardError).utf8)
                    .write(to: artifacts.appendingPathComponent("companion.log"), options: .atomic)
            }
        }
        if let artifacts,
           FileManager.default.fileExists(atPath: artifacts.appendingPathComponent("secure-input-used").path) {
            // XCTest activity records can include the typeText argument. Never
            // preserve that archive or raw host log after secure input.
            try? FileManager.default.removeItem(at: artifacts.appendingPathComponent("companion.xcresult"))
            try? FileManager.default.removeItem(at: artifacts.appendingPathComponent("companion.log"))
        }
        service = nil
    }
}
