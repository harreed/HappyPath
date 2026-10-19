import Foundation
import CryptoKit
import ProjectDomain
import RunnerCore

public struct RetentionPolicyConfig: Codable, Sendable {
    public let maxRuns: Int?
    public let maxAgeDays: Int?
    public let maxSizeBytes: Int64?
    public let protectActive: Bool
    public let protectIncomplete: Bool
    public let protectPinned: Bool

    public init(maxRuns: Int? = nil, maxAgeDays: Int? = nil, maxSizeBytes: Int64? = nil,
                protectActive: Bool = true, protectIncomplete: Bool = true, protectPinned: Bool = true) {
        self.maxRuns = maxRuns
        self.maxAgeDays = maxAgeDays
        self.maxSizeBytes = maxSizeBytes
        self.protectActive = protectActive
        self.protectIncomplete = protectIncomplete
        self.protectPinned = protectPinned
    }

    public var isEnabled: Bool { maxRuns != nil || maxAgeDays != nil || maxSizeBytes != nil }

    public static let `default` = RetentionPolicyConfig()
}

public struct RetentionCandidate: Codable, Sendable {
    public let runDirectory: String
    public let runID: String
    public let projectID: UUID
    public let projectName: String
    public let createdAt: Date
    public let sizeBytes: Int64
    public let outcomeRawValue: String?
    public let isActive: Bool
    public let isIncomplete: Bool
    public let isPinned: Bool
    public let reason: String

    public var outcome: RunOutcome? { outcomeRawValue.flatMap(RunOutcome.init(rawValue:)) }

    public init(runDirectory: URL, runID: String, projectID: UUID, projectName: String,
                createdAt: Date, sizeBytes: Int64, outcome: RunOutcome?,
                isActive: Bool, isIncomplete: Bool, isPinned: Bool, reason: String) {
        self.runDirectory = runDirectory.path
        self.runID = runID
        self.projectID = projectID
        self.projectName = projectName
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
        self.outcomeRawValue = outcome?.rawValue
        self.isActive = isActive
        self.isIncomplete = isIncomplete
        self.isPinned = isPinned
        self.reason = reason
    }
}

public struct RetentionPreview: Codable, Sendable {
    public let candidates: [RetentionCandidate]
    public let totalBytes: Int64
    public let totalRuns: Int
    public let policy: RetentionPolicyConfig
    public let timestamp: Date

    public init(candidates: [RetentionCandidate], policy: RetentionPolicyConfig) {
        self.candidates = candidates
        self.totalBytes = candidates.reduce(0) { $0 + $1.sizeBytes }
        self.totalRuns = candidates.count
        self.policy = policy
        self.timestamp = Date()
    }
}

public struct RetentionResult: Codable, Sendable {
    public let movedToQuarantine: [RetentionCandidate]
    public let freedBytes: Int64
    public let quarantineManifest: QuarantineManifest
    public let timestamp: Date

    public init(movedToQuarantine: [RetentionCandidate], freedBytes: Int64, quarantineManifest: QuarantineManifest) {
        self.movedToQuarantine = movedToQuarantine
        self.freedBytes = freedBytes
        self.quarantineManifest = quarantineManifest
        self.timestamp = Date()
    }
}

public struct QuarantineManifest: Codable, Sendable {
    public let schemaVersion: Int
    public var items: [QuarantineItem]
    public let createdAt: Date

    public init(items: [QuarantineItem]) {
        self.schemaVersion = 1
        self.items = items
        self.createdAt = Date()
    }
}

public struct QuarantineItem: Codable, Sendable {
    public let originalPath: String
    public let runID: String
    public let projectID: UUID
    public let projectName: String
    public let sizeBytes: Int64
    public let movedAt: Date
    public let originalHashes: [String: String]

    public init(originalPath: String, runID: String, projectID: UUID, projectName: String,
                sizeBytes: Int64, originalHashes: [String: String]) {
        self.originalPath = originalPath
        self.runID = runID
        self.projectID = projectID
        self.projectName = projectName
        self.sizeBytes = sizeBytes
        self.movedAt = Date()
        self.originalHashes = originalHashes
    }
}

public struct RetentionEngine {
    public static func generatePreview(projectURL: URL, policy: RetentionPolicyConfig) throws -> RetentionPreview {
        let runsDir = projectURL.appendingPathComponent("runs")
        guard FileManager.default.fileExists(atPath: runsDir.path) else { return RetentionPreview(candidates: [], policy: policy) }

        let fm = FileManager.default
        let runDirs = try fm.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
        var candidates: [RetentionCandidate] = []

        for dir in runDirs {
            let runID = dir.lastPathComponent
            let eventsURL = dir.appendingPathComponent("events.jsonl")
            guard fm.fileExists(atPath: eventsURL.path) else { continue }

            let sizeBytes = try computeDirectorySize(dir)
            let project = try ProjectBundleStore().load(from: dir)
            _ = try JSONDecoder().decode(RunSelection.self, from: Data(contentsOf: dir.appendingPathComponent("selection.json")))

            let reportURL = dir.appendingPathComponent("run.json")
            var outcome: RunOutcome? = nil
            var isIncomplete = false
            if fm.fileExists(atPath: reportURL.path) {
                let report = try JSONDecoder().decode(ExecutionReport.self, from: Data(contentsOf: reportURL))
                outcome = report.outcome
            } else {
                isIncomplete = true
            }

            let createdAt = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()

            var reason = ""
            if isIncomplete { reason += "incomplete; " }
            if outcome == .blocked { reason += "blocked; " }
            if outcome == .cancelled { reason += "cancelled; " }

            let candidate = RetentionCandidate(
                runDirectory: dir,
                runID: runID,
                projectID: project.id,
                projectName: project.name,
                createdAt: createdAt,
                sizeBytes: sizeBytes,
                outcome: outcome,
                isActive: false,
                isIncomplete: isIncomplete,
                isPinned: false,
                reason: reason.trimmingCharacters(in: CharacterSet(charactersIn: "; "))
            )
            candidates.append(candidate)
        }

        candidates.sort { $0.createdAt < $1.createdAt }

        var filtered: [RetentionCandidate] = []
        for candidate in candidates {
            if policy.protectActive && candidate.isActive { continue }
            if policy.protectIncomplete && candidate.isIncomplete { continue }
            if policy.protectPinned && candidate.isPinned { continue }
            filtered.append(candidate)
        }

        if let maxRuns = policy.maxRuns, filtered.count > maxRuns {
            filtered = Array(filtered.prefix(filtered.count - maxRuns))
        }

        if let maxAgeDays = policy.maxAgeDays {
            let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)
            filtered = filtered.filter { $0.createdAt < cutoff }
        }

        if let maxSizeBytes = policy.maxSizeBytes {
            var totalSize: Int64 = 0
            var final: [RetentionCandidate] = []
            for candidate in filtered {
                totalSize += candidate.sizeBytes
                if totalSize > maxSizeBytes { break }
                final.append(candidate)
            }
            filtered = final
        }

        return RetentionPreview(candidates: filtered, policy: policy)
    }

    public static func applyPreview(projectURL: URL, preview: RetentionPreview, dryRun: Bool = false) throws -> RetentionResult {
        let quarantineDir = projectURL.appendingPathComponent("quarantine")
        let fm = FileManager.default

        if !dryRun {
            try fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        }

        var quarantineItems: [QuarantineItem] = []
        var totalFreed: Int64 = 0

        for candidate in preview.candidates {
            let source = URL(fileURLWithPath: candidate.runDirectory)
            let quarantineSubdir = quarantineDir.appendingPathComponent(candidate.runID)
            let originalHashes = try computeDirectoryHashes(source)

            if !dryRun {
                try fm.moveItem(at: source, to: quarantineSubdir)
            }

            totalFreed += candidate.sizeBytes

            quarantineItems.append(QuarantineItem(
                originalPath: candidate.runDirectory,
                runID: candidate.runID,
                projectID: candidate.projectID,
                projectName: candidate.projectName,
                sizeBytes: candidate.sizeBytes,
                originalHashes: originalHashes
            ))
        }

        let manifest = QuarantineManifest(items: quarantineItems)
        if !dryRun {
            let manifestURL = quarantineDir.appendingPathComponent("manifest.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        }

        return RetentionResult(movedToQuarantine: preview.candidates, freedBytes: totalFreed, quarantineManifest: manifest)
    }

    public static func restoreFromQuarantine(projectURL: URL, runID: String) throws {
        let fm = FileManager.default
        let quarantineDir = projectURL.appendingPathComponent("quarantine")
        let source = quarantineDir.appendingPathComponent(runID)
        let destination = projectURL.appendingPathComponent("runs").appendingPathComponent(runID)

        guard fm.fileExists(atPath: source.path) else { throw RetentionError.notFound(runID) }
        guard !fm.fileExists(atPath: destination.path) else { throw RetentionError.collision(runID) }

        try fm.moveItem(at: source, to: destination)

        let manifestURL = quarantineDir.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: manifestURL.path) {
            var manifest = try JSONDecoder().decode(QuarantineManifest.self, from: Data(contentsOf: manifestURL))
            manifest.items.removeAll { $0.runID == runID }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        }
    }

    public static func listQuarantine(projectURL: URL) throws -> [QuarantineItem] {
        let manifestURL = projectURL.appendingPathComponent("quarantine/manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let manifest = try JSONDecoder().decode(QuarantineManifest.self, from: Data(contentsOf: manifestURL))
        return manifest.items
    }

    private static func computeDirectorySize(_ url: URL) throws -> Int64 {
        var size: Int64 = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            size += Int64(values.fileSize ?? 0)
        }
        return size
    }

    private static func computeDirectoryHashes(_ url: URL) throws -> [String: String] {
        var hashes: [String: String] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return hashes }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = String(file.path.dropFirst(url.path.count + 1))
            let data = try Data(contentsOf: file)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            hashes[relativePath] = hash
        }
        return hashes
    }
}

public enum RetentionError: Error, LocalizedError {
    case notFound(String)
    case collision(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "Quarantine item not found: \(id)"
        case .collision(let id): return "Cannot restore: run \(id) already exists in runs directory"
        }
    }
}