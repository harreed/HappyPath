import Foundation

public struct ProcessInvocation: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let currentDirectoryURL: URL?

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }
}

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct ProcessExecutionError: Error, CustomStringConvertible {
    public let invocation: ProcessInvocation
    public let result: ProcessResult

    public var description: String {
        "Process failed (\(result.exitCode)): \(invocation.executableURL.path) \(invocation.arguments.joined(separator: " "))\n\(result.standardError)"
    }
}

public protocol ProcessExecuting: Sendable {
    func run(_ invocation: ProcessInvocation) throws -> ProcessResult
}

/// Executes an executable directly. Arguments never pass through a shell.
public final class FoundationProcessExecutor: ProcessExecuting, @unchecked Sendable {
    public init() {}

    public func run(_ invocation: ProcessInvocation) throws -> ProcessResult {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentic-ui-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let stdoutURL = tempDirectory.appendingPathComponent("stdout")
        let stderrURL = tempDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.currentDirectoryURL
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        process.waitUntilExit()
        try stdoutHandle.synchronize()
        try stderrHandle.synchronize()

        let result = ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
        guard result.exitCode == 0 else {
            throw ProcessExecutionError(invocation: invocation, result: result)
        }
        return result
    }
}
