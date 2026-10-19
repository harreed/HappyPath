import Foundation
import CryptoKit
import Darwin
import ProjectDomain
import RunnerCore

public enum ArchiveRecoveryMode: String, Codable, Sendable { case nativePrefix, legacyISOImport }
public struct DateConversion: Codable, Sendable {
    public let line: Int
    public let path: String
    public let original: String
    public let millisecondsSince1970: Double
}
public struct ArchiveRecoveryManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let mode: ArchiveRecoveryMode
    public let sourceName: String
    public let incomplete: Bool
    public let originalManifest: [String: String]
    public let originalEventsSHA256: String
    public let committedPrefixBytes: Int
    public let omittedTailBytes: Int
    public let eventCount: Int
    public let diagnostics: [String]
    public let dateConversions: [DateConversion]
}
public struct ArchiveDiagnosis: Sendable {
    public let directory: URL
    public let mode: ArchiveRecoveryMode
    public let events: [ExecutionEnvelope]
    public let committedBytes: Data
    public let originalEvents: Data
    public let conversions: [DateConversion]
    public let diagnostics: [String]
    public let sourceComplete: Bool
    public let matchingLiveOwner: Bool
    public var summary: String { diagnostics.joined(separator: "\n") }
}

public enum ArchiveRecovery {
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func fail(_ message: String) -> ProjectValidationError { .invalid(message) }
    private static func checkedData(_ file: URL, maximum: Int = 64 * 1024 * 1024) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maximum,
              file.standardizedFileURL.path == file.resolvingSymlinksInPath().standardizedFileURL.path else { throw fail("Unsafe or oversized archive input: \(file.lastPathComponent)") }
        return try Data(contentsOf: file)
    }
    public static func diagnose(_ directory: URL, mode: ArchiveRecoveryMode = .nativePrefix, skipTreeCheck: Bool = false) throws -> ArchiveDiagnosis {
        if !skipTreeCheck { try PortableFiles.checkTree(directory) }
        let project = try ProjectMigration.preview(data: checkedData(directory.appendingPathComponent("project.json"))).project
        let selection = try JSONDecoder().decode(RunSelection.self, from: checkedData(directory.appendingPathComponent("selection.json")))
        _ = try project.selectedTests(selection)
        let format = directory.appendingPathComponent("artifact-format.json")
        switch mode {
        case .nativePrefix:
            let object = try JSONSerialization.jsonObject(with: checkedData(format)) as? [String: Any]
            guard object?["eventFormatVersion"] as? Int == 2, object?["dateEncoding"] as? String == "millisecondsSince1970" else { throw ExecutionArtifactError.unsupportedFormat }
        case .legacyISOImport:
            guard !FileManager.default.fileExists(atPath: format.path) else { throw fail("Legacy import requires an unmarked Phase1 ISO archive; mixed/versioned input is unsupported") }
        }
        let original = try checkedData(directory.appendingPathComponent("events.jsonl"))
        let end = original.lastIndex(of: 10).map { $0 + 1 } ?? 0
        let prefix = original.prefix(end)
        let rawLines = prefix.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        let decoder = JSONDecoder()
        if mode == .nativePrefix { decoder.dateDecodingStrategy = .millisecondsSince1970 }
        else { decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let standard = ISO8601DateFormatter(); standard.formatOptions = [.withInternetDateTime]
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let value = fractional.date(from: string) ?? standard.date(from: string) else { throw fail("Unsupported legacy date") }
            return value
        } }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var events: [ExecutionEnvelope] = [], conversions: [DateConversion] = [], converted = Data()
        var finished = false
        for (index, line) in rawLines.enumerated() {
            guard !line.isEmpty, line.count <= 8 * 1024 * 1024 else { throw fail("Invalid committed event line \(index + 1)") }
            let bytes = Data(line)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let event = object["event"] as? [String: Any], event.count == 1 else { throw fail("Ambiguous event at line \(index + 1)") }
            let envelope: ExecutionEnvelope
            do { envelope = try decoder.decode(ExecutionEnvelope.self, from: bytes) }
            catch { throw fail("Committed event \(index + 1) is invalid: \(error.localizedDescription). No middle records can be skipped.") }
            guard envelope.sequence == index + 1, envelope.timestamp.timeIntervalSince1970.isFinite,
                  envelope.timestamp >= (events.last?.timestamp ?? envelope.timestamp), !finished else { throw fail("Invalid event sequence, time or event after terminal at line \(index + 1)") }
            if case .finished = envelope.event { finished = true }
            if mode == .legacyISOImport {
                let encoded = try encoder.encode(envelope)
                let canonical = try JSONSerialization.jsonObject(with: encoded)
                try compareConversion(original: object, converted: canonical, path: "$", line: index + 1, changes: &conversions)
                converted.append(encoded); converted.append(10)
            }
            events.append(envelope)
        }
        let reportURL = directory.appendingPathComponent("run.json")
        var complete = false
        var diagnostics = ["Validated \(events.count) contiguous newline-committed events. Structural validation does not certify historical assertion truth."]
        if FileManager.default.fileExists(atPath: reportURL.path) {
            let report = try JSONDecoder().decode(ExecutionReport.self, from: checkedData(reportURL))
            if case .finished(let terminal) = events.last?.event,
               try encoder.encode(terminal) == encoder.encode(report), end == original.count { complete = true }
            else { diagnostics.append("Terminal result exists but does not match the committed prefix; it remains original evidence only.") }
        } else { diagnostics.append("Terminal commit run.json is missing; no completed run outcome can be inferred.") }
        if end != original.count { diagnostics.append("Uncommitted final fragment: \(original.count - end) bytes. Retained in original/events.jsonl; never replayed.") }
        for event in events {
            if case .capture(let snapshot) = event.event {
                for ext in ["png", "json"] where !FileManager.default.fileExists(atPath: directory.appendingPathComponent("captures/\(snapshot.captureID.description).\(ext)").path) {
                    diagnostics.append("Missing capture file: \(snapshot.captureID.description).\(ext)")
                }
            }
        }
        diagnostics.append("Video is retained if present; decoding/finalization and exact coverage may be uncertain after interruption.")
        let session = try? RunSession.read(in: directory)
        diagnostics.append(session?.diagnostic ?? "No supported session identity; resource ownership unresolved.")
        diagnostics.append("Archive metadata grants no cleanup authority. External Simulator apps and processes may remain; no signals or UI inputs are sent.")
        return .init(directory: directory, mode: mode, events: events, committedBytes: mode == .nativePrefix ? Data(prefix) : converted,
                     originalEvents: original, conversions: conversions, diagnostics: diagnostics, sourceComplete: complete,
                     matchingLiveOwner: session?.hasMatchingLiveOwner ?? false)
    }
    private static func compareConversion(original: Any, converted: Any, path: String, line: Int, changes: inout [DateConversion]) throws {
        if let a = original as? [String: Any], let b = converted as? [String: Any] {
            guard Set(a.keys) == Set(b.keys) else { throw fail("Legacy fields are unsupported at \(path)") }
            for key in a.keys.sorted() { try compareConversion(original: a[key]!, converted: b[key]!, path: path + "." + key, line: line, changes: &changes) }
        } else if let a = original as? [Any], let b = converted as? [Any] {
            guard a.count == b.count else { throw fail("Legacy array conversion changed values") }
            for i in a.indices { try compareConversion(original: a[i], converted: b[i], path: "\(path)[\(i)]", line: line, changes: &changes) }
        } else if let a = original as? String, let b = converted as? NSNumber {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter(); standard.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: a) ?? standard.date(from: a), abs(date.timeIntervalSince1970 * 1000 - b.doubleValue) < 0.01 else { throw fail("Ambiguous legacy date conversion at \(path)") }
            changes.append(.init(line: line, path: path, original: a, millisecondsSince1970: b.doubleValue))
        } else {
            guard NSDictionary(dictionary: ["value": original]).isEqual(to: ["value": converted]) else { throw fail("Legacy value changed at \(path)") }
        }
    }
    public static func recover(_ source: URL, to destination: URL, mode: ArchiveRecoveryMode = .nativePrefix, beforeCommit: () throws -> Void = {}) throws -> ArchiveRecoveryManifest {
        let fm = FileManager.default
        let source = source.standardizedFileURL, destination = destination.standardizedFileURL
        guard source != destination, !destination.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(destination.path + "/"),
              !fm.fileExists(atPath: destination.path), destination.deletingLastPathComponent().resolvingSymlinksInPath() == destination.deletingLastPathComponent() else { throw fail("Choose a new archive outside the source and without symlink parents") }
        let roots = try fm.contentsOfDirectory(atPath: source.path).sorted()
        let fingerprint = try PortableFiles.fingerprint(source, roots: roots)
        let diagnosis = try diagnose(source, mode: mode)
        guard !diagnosis.matchingLiveOwner else { throw fail("The recorded owner still matches a live process. Stop it normally before recovery.") }
        let incomplete = mode == .nativePrefix || !diagnosis.sourceComplete
        let originalPrefixLength = diagnosis.originalEvents.lastIndex(of: 10).map { $0 + 1 } ?? 0
        let manifest = ArchiveRecoveryManifest(schemaVersion: 1, mode: mode, sourceName: source.lastPathComponent, incomplete: incomplete,
            originalManifest: fingerprint, originalEventsSHA256: hash(diagnosis.originalEvents), committedPrefixBytes: originalPrefixLength,
            omittedTailBytes: diagnosis.originalEvents.count - originalPrefixLength, eventCount: diagnosis.events.count,
            diagnostics: diagnosis.diagnostics, dateConversions: diagnosis.conversions)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".recovery-\(UUID())")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: source, to: stage.appendingPathComponent("original"))
        for name in roots where !["events.jsonl", "run.json", "report.md", "artifact-format.json", "original", "recovery.json", "session.json"].contains(name) && !name.hasPrefix("resource-") {
            try fm.copyItem(at: source.appendingPathComponent(name), to: stage.appendingPathComponent(name))
        }
        try diagnosis.committedBytes.write(to: stage.appendingPathComponent("events.jsonl"))
        try Data("{\"eventFormatVersion\":2,\"dateEncoding\":\"millisecondsSince1970\"}".utf8).write(to: stage.appendingPathComponent("artifact-format.json"))
        if !incomplete { try fm.copyItem(at: source.appendingPathComponent("run.json"), to: stage.appendingPathComponent("run.json")) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("recovery.json"))
        let title = incomplete ? "Recovered / incomplete — no terminal result" : "Imported legacy completed evidence"
        try Data(("# \(title)\n\nNo execution resumed. Original bytes are in original/. Structural validation is not a new test result.\n\n" + diagnosis.summary).utf8).write(to: stage.appendingPathComponent("report.md"))
        try beforeCommit()
        guard roots == (try fm.contentsOfDirectory(atPath: source.path).sorted()), fingerprint == (try PortableFiles.fingerprint(source, roots: roots)), fingerprint == (try PortableFiles.fingerprint(stage.appendingPathComponent("original"), roots: roots)) else { throw fail("Source changed during recovery; no archive was published") }
        _ = try ExecutionArchive(directory: stage)
        guard renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw fail("Recovery destination appeared or publication failed") }
        return manifest
    }
}
