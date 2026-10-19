import Foundation
import Darwin

/// Diagnostic identity only. Reading an archive never grants process ownership.
public struct ProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public static func observe(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return .init(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
    public var status: String {
        if let current = Self.observe(pid) { return current == self ? "Matching live process; no cleanup authority" : "PID reused; must not signal" }
        if kill(pid, 0) == -1 && errno == ESRCH { return "Process ended" }
        return "Process identity unresolved; must not signal"
    }
}

public struct RunSession: Codable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let owner: ProcessIdentity?
    public let createdAt: Date
    public var closed: Bool
    public init() { schemaVersion = 1; sessionID = UUID(); owner = .observe(getpid()); createdAt = Date(); closed = false }
    public static func read(in directory: URL) throws -> Self {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        guard value.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    public func write(in directory: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
    public var hasMatchingLiveOwner: Bool { !closed && owner.map { ProcessIdentity.observe($0.pid) == $0 } == true }
    public var diagnostic: String { closed ? "Session closed; retained resource records are historical observations" : "Unclosed session: \(owner?.status ?? "owner identity unavailable; unresolved")" }
}

public struct RunResourceRecord: Codable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID?
    public let role: String
    public let process: ProcessIdentity?
    public let observedAt: Date
    public let simulatorID: String?
    public let bundleIdentifier: String?
    public static func record(in directory: URL, role: String, pid: Int32?, simulatorID: String? = nil, bundleIdentifier: String? = nil) throws {
        let record = Self(schemaVersion: 1, sessionID: (try? RunSession.read(in: directory))?.sessionID,
                          role: role, process: pid.flatMap(ProcessIdentity.observe), observedAt: Date(), simulatorID: simulatorID, bundleIdentifier: bundleIdentifier)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: directory.appendingPathComponent("resource-\(UUID()).json"), options: .withoutOverwriting)
    }
}
