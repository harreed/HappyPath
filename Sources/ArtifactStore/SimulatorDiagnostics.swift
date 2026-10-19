import Foundation
import ProjectDomain

public struct SimulatorDiagnosticsManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let startedAt: Date
    public let endedAt: Date
    public let deviceLogStatus: String
    public let crashReports: [String]
    public let suspectedCause: String?

    public static func read(in directory: URL) -> Self? {
        let url = directory.appendingPathComponent("diagnostics.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let value = try? decoder.decode(Self.self, from: Data(contentsOf: url)), value.schemaVersion == 1 else { return nil }
        return value
    }
}

/// Supplemental evidence only. A failure here cannot change the execution result.
public struct SimulatorDiagnosticsCollector: Sendable {
    public typealias LogFetcher = @Sendable (_ deviceID: String, _ bundleID: String, _ processName: String, _ start: Date, _ end: Date) -> String?
    private let fetchLog: LogFetcher
    private let crashDirectory: URL

    public init(crashDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                fetchLog: @escaping LogFetcher = { deviceID, bundleID, processName, start, end in
                    Self.fetchDeviceLog(deviceID: deviceID, bundleID: bundleID, processName: processName, start: start, end: end)
                }) {
        self.crashDirectory = crashDirectory
        self.fetchLog = fetchLog
    }

    @discardableResult
    public func collect(in directory: URL, project: TestProject, startedAt: Date, endedAt: Date) throws -> SimulatorDiagnosticsManifest {
        let log = fetchLog(project.simulator.deviceID, project.app.bundleIdentifier, project.app.productName, startedAt, endedAt)
        let logStatus: String
        if let log, !log.isEmpty {
            try Data(log.prefix(2_000_000).utf8).write(to: directory.appendingPathComponent("device.log"), options: .atomic)
            logStatus = log.utf8.count > 2_000_000 ? "Captured; truncated to 2 MB" : "Captured"
        } else {
            logStatus = "Unavailable from Simulator unified logging"
        }

        var reports: [String] = []
        let candidates = (try? FileManager.default.contentsOfDirectory(at: crashDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey])) ?? []
        for source in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard reports.count < 5, ["ips", "crash"].contains(source.pathExtension.lowercased()),
                  source.lastPathComponent.hasPrefix(project.app.productName + "-") || source.lastPathComponent.hasPrefix(project.app.bundleIdentifier + "-") else { continue }
            guard let values = try? source.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= startedAt.addingTimeInterval(-30), modified <= endedAt.addingTimeInterval(30),
                  (values.fileSize ?? Int.max) <= 2_000_000,
                  let data = try? Data(contentsOf: source), data.count <= 2_000_000,
                  let body = String(data: data, encoding: .utf8), body.contains(project.app.bundleIdentifier) else { continue }
            let relative = "crashes/\(source.lastPathComponent)"
            let destination = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            reports.append(relative)
        }
        let cause = reports.isEmpty ? nil : "A crash report for \(project.app.bundleIdentifier) was recorded during this run. Inspect the crash report before attributing the test failure to the app."
        let manifest = SimulatorDiagnosticsManifest(schemaVersion: 1, startedAt: startedAt, endedAt: endedAt,
                                                    deviceLogStatus: logStatus, crashReports: reports, suspectedCause: cause)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)
        let reportURL = directory.appendingPathComponent("report.md")
        if var report = try? String(contentsOf: reportURL, encoding: .utf8) {
            report += "\n## Device diagnostics\n\n"
            report += "Collection window: \(startedAt.formatted()) to \(endedAt.formatted()). [Manifest](diagnostics.json).\n\n"
            report += "Simulator log: \(logStatus)"
            if let log, !log.isEmpty { report += " · [View log](device.log)" }
            report += "\n\n"
            if let cause { report += "Suspected cause: \(cause)\n\n" }
            for path in reports { report += "- [Crash report](\(path))\n" }
            try? Data(report.utf8).write(to: reportURL, options: .atomic)
        }
        return manifest
    }

    public static func fetchDeviceLog(deviceID: String, bundleID: String, processName: String, start: Date, end: Date) -> String? {
        // simctl arguments are passed directly to Process, never interpreted by a shell.
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let predicate = "subsystem == \"\(bundleID.replacingOccurrences(of: "\"", with: ""))\" OR process == \"\(processName.replacingOccurrences(of: "\"", with: ""))\""
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-device-log-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil), let output = try? FileHandle(forWritingTo: temporary) else { return nil }
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", deviceID, "log", "show", "--style", "compact", "--start", format.string(from: start), "--end", format.string(from: end), "--predicate", predicate]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        if finished.wait(timeout: .now() + 20) == .timedOut { process.terminate(); process.waitUntilExit(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        try? output.synchronize()
        return try? String(contentsOf: temporary, encoding: .utf8)
    }
}
