import Foundation
#if os(macOS)
import Darwin

public enum SupervisedProcessError: LocalizedError, Equatable, Sendable {
    case invalidInvocation
    case invalidTimeout
    case spawnFailed(Int32)
    case waitFailed(Int32)
    case timedOut(Double)
    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds): return String(format: "The process exceeded its %.1f second deadline", seconds)
        case .invalidInvocation: return "The process invocation is invalid"
        case .invalidTimeout: return "The process timeout is invalid"
        case .spawnFailed(let code): return "The process could not start (system error \(code))"
        case .waitFailed(let code): return "The process could not be reaped (system error \(code))"
        }
    }
}

public struct ProcessOutputSnapshot: Sendable {
    public let standardOutput: String
    public let standardError: String
    /// Observation time, not the time the child originally wrote these bytes.
    public let observedAt: Date
}

/// Owns a POSIX process group. Services launched through another daemon (such as
/// Simulator apps) still require explicit, device-scoped lifecycle cleanup.
public struct SupervisedProcessExecutor: Sendable {
    public init() {}

    public func run(_ invocation: ProcessInvocation, timeout: Double) async throws -> ProcessResult {
        guard timeout.isFinite, timeout > 0 else { throw SupervisedProcessError.invalidTimeout }
        try Task.checkCancellation()
        return try await start(invocation).wait(timeout: timeout)
    }

    /// Preserve bounded output for every exit path, including timeout and cancellation.
    public func run(_ invocation: ProcessInvocation, timeout: Double, retainingOutputAt log: URL) async throws -> ProcessResult {
        guard timeout.isFinite, timeout > 0 else { throw SupervisedProcessError.invalidTimeout }
        try Task.checkCancellation()
        let handle = try start(invocation)
        func persist(_ output: String, _ error: String, reason: String) throws {
            try Data(("Termination: \(reason)\n\nSTDOUT\n\(output)\n\nSTDERR\n\(error)").utf8).write(to: log, options: .atomic)
        }
        do {
            let result = try await handle.wait(timeout: timeout)
            try persist(result.standardOutput, result.standardError, reason: "Exit \(result.exitCode)")
            return result
        } catch {
            await handle.stop(grace: 0.2)
            let output = try handle.currentOutput()
            try persist(output.standardOutput, output.standardError, reason: String(describing: error))
            throw error
        }
    }

    public func start(_ invocation: ProcessInvocation) throws -> SupervisedProcessHandle {
        let environment = invocation.environment ?? ProcessInfo.processInfo.environment
        let strings = [invocation.executableURL.path] + invocation.arguments + environment.map { "\($0.key)=\($0.value)" }
        guard invocation.executableURL.isFileURL,
              strings.allSatisfy({ !$0.utf8.contains(0) }),
              environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }),
              invocation.currentDirectoryURL.map({ $0.isFileURL && !$0.path.utf8.contains(0) }) ?? true else {
            throw SupervisedProcessError.invalidInvocation
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("supervised-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var transferred = false
        defer { if !transferred { try? FileManager.default.removeItem(at: directory) } }
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        let outputFD = open(stdout.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(outputFD) }
        let errorFD = open(stderr.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard errorFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(errorFD) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ code: Int32) throws { if code != 0 { throw SupervisedProcessError.spawnFailed(code) } }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, outputFD, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, errorFD, STDERR_FILENO))
        if let cwd = invocation.currentDirectoryURL {
            try check(posix_spawn_file_actions_addchdir_np(&actions, cwd.path))
        }
        var argv = ([invocation.executableURL.path] + invocation.arguments).map { strdup($0) } + [nil]
        var envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw SupervisedProcessError.spawnFailed(ENOMEM)
        }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, invocation.executableURL.path, &actions, &attributes, &argv, &envp))
        let state = SupervisedProcessState(pid: pid, invocation: invocation, directory: directory)
        transferred = true
        DispatchQueue.global(qos: .utility).async { state.reap() }
        return SupervisedProcessHandle(state: state)
    }
}

public final class SupervisedProcessHandle: @unchecked Sendable {
    private let state: SupervisedProcessState
    fileprivate init(state: SupervisedProcessState) { self.state = state }
    deinit { state.signal(SIGKILL) }
    public var processID: Int32 { state.pid }
    public var isRunning: Bool { state.isRunning }

    /// Non-destructive cumulative output, independently capped at 16 MiB per stream.
    /// Each call owns its read handles, so concurrent readers do not share offsets.
    /// Poll for complete markers: a writer may have emitted only part of a line.
    public func currentOutput() throws -> ProcessOutputSnapshot {
        let output = try state.readOutput("stdout")
        let error = try state.readOutput("stderr")
        return ProcessOutputSnapshot(standardOutput: output, standardError: error, observedAt: Date())
    }

    /// Cancellation cannot cancel cleanup. Grace is capped to keep teardown bounded.
    public func stop(signal: Int32 = SIGTERM, grace: Double = 1) async {
        let state = state
        await Task.detached {
            state.signal(signal)
            let duration = grace.isFinite ? min(max(grace, 0), 10) : 0
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(duration))
            while state.isRunning && clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            state.signal(SIGKILL)
            // Reaping is local and does not await the cancelled parent task.
            while state.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        }.value
    }

    public func wait(timeout: Double) async throws -> ProcessResult {
        guard timeout.isFinite, timeout > 0 else { throw SupervisedProcessError.invalidTimeout }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        return try await withTaskCancellationHandler {
            while true {
                if Task.isCancelled {
                    await stop(grace: 0.2)
                    throw CancellationError()
                }
                if let outcome = state.outcome { return try outcome.get() }
                if clock.now >= deadline {
                    await stop(grace: 0.2)
                    throw SupervisedProcessError.timedOut(timeout)
                }
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch {
                    await stop(grace: 0.2)
                    throw CancellationError()
                }
            }
        } onCancel: {
            self.state.signal(SIGTERM)
        }
    }
}

private final class SupervisedProcessState: @unchecked Sendable {
    let pid: pid_t
    let invocation: ProcessInvocation
    let directory: URL
    private let lock = NSLock()
    private var reaped = false
    private var storedOutcome: Result<ProcessResult, Error>?
    init(pid: pid_t, invocation: ProcessInvocation, directory: URL) {
        self.pid = pid; self.invocation = invocation; self.directory = directory
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    var isRunning: Bool { lock.withLock { !reaped } }
    var outcome: Result<ProcessResult, Error>? { lock.withLock { storedOutcome } }
    func signal(_ signal: Int32) {
        lock.withLock { if !reaped { _ = kill(-pid, signal) } }
    }
    func reap() {
        // WNOWAIT keeps the leader's PID reserved until group cleanup. This
        // avoids ever signalling a recycled group ID after reaping the leader.
        var info = siginfo_t()
        var code: Int32
        repeat { code = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while code == -1 && errno == EINTR
        let observationError = code == -1 ? errno : 0
        var status: Int32 = 0
        lock.lock()
        // If observation itself fails, do not block waiting on a still-live
        // owned child. ECHILD is the exception: ownership is already gone.
        if observationError != ECHILD { _ = kill(-pid, SIGKILL) }
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
        let waitError = waited == -1 ? errno : 0
        reaped = true
        lock.unlock()
        let outcome: Result<ProcessResult, Error>
        if observationError != 0 || waitError != 0 {
            outcome = .failure(SupervisedProcessError.waitFailed(observationError != 0 ? observationError : waitError))
        } else {
            do {
                let signal = status & 0x7f
                let exitCode = signal == 0 ? ((status >> 8) & 0xff) : 128 + signal
                let result = ProcessResult(exitCode: exitCode, standardOutput: try readOutput("stdout"), standardError: try readOutput("stderr"))
                outcome = exitCode == 0 ? .success(result) : .failure(ProcessExecutionError(invocation: invocation, result: result))
            } catch { outcome = .failure(error) }
        }
        lock.withLock { storedOutcome = outcome }
    }
    func readOutput(_ name: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let limit: UInt64 = 16 * 1024 * 1024
        try handle.seek(toOffset: length > limit ? length - limit : 0)
        // Bound the read to the observed length even if a live child keeps writing.
        let text = String(decoding: try handle.read(upToCount: Int(min(length, limit))) ?? Data(), as: UTF8.self)
        return length > limit ? "[Output truncated to final 16 MiB]\n" + text : text
    }
}
#endif
