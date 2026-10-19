import Foundation
import RunnerCore

/// A single serial client owns a bounded mailbox session. Responses never authorize another request.
public actor CompanionBridge: AccessibilityBridging {
    public let directory: URL
    public let bundleID: String
    private var sessionID: UUID?
    public private(set) var secretPublicKey: Data?
    private var pending = false
    private var poisoned = Set<UUID>()
    private func poison(_ id: UUID) {
        poisoned.insert(id); sessionID = nil; secretPublicKey = nil
        try? Data("stop".utf8).write(to: directory.appendingPathComponent("poison-" + id.uuidString), options: .atomic)
    }
    private func fresh(_ heartbeat: Double, maximumAge: Double) -> Bool {
        let age = Date().timeIntervalSince1970 - heartbeat
        return age.isFinite && age >= 0 && age < maximumAge
    }
    private static func readOnly(_ operation: CompanionOperation) -> Bool { operation == .snapshot || operation == .wait }
    public init(directory: URL, bundleID: String) { self.directory = directory; self.bundleID = bundleID }
    public func connect(timeout: Double = 30, startedAfter: Date? = nil) async throws {
        guard !pending else { throw CompanionFailure.invalidRequest }
        let end = Date().addingTimeInterval(min(max(timeout, 0), 60))
        while Date() < end {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
               let state = try? JSONDecoder().decode(CompanionSession.self, from: data), state.version == 1,
                state.state == "ready", startedAfter.map({ state.startedAt >= $0.timeIntervalSince1970 }) ?? true,
                !poisoned.contains(state.sessionID),
               !FileManager.default.fileExists(atPath: directory.appendingPathComponent("poison-" + state.sessionID.uuidString).path),
               fresh(state.heartbeat, maximumAge: 5) {
                sessionID = state.sessionID
                secretPublicKey = state.secretPublicKey
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CompanionFailure.timeout
    }
    public func request(_ operation: CompanionOperation, configure: @Sendable (inout CompanionRequest) -> Void = { _ in }) async throws -> CompanionResponse {
        guard !pending else { throw CompanionFailure.invalidRequest }
        pending = true
        defer { pending = false }
        guard let sessionID else { throw CompanionFailure.lostSession }
        var request = CompanionRequest(sessionID: sessionID, operation: operation, bundleID: bundleID)
        configure(&request)
        try request.validate()
        let requests = directory.appendingPathComponent("requests")
        let responses = directory.appendingPathComponent("responses")
        let name = request.requestID.uuidString + ".json"
        do {
        try JSONEncoder().encode(request).write(to: requests.appendingPathComponent(name), options: .atomic)
        while Date().timeIntervalSince1970 < request.deadline {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: responses.appendingPathComponent(name)) {
                let response = try JSONDecoder().decode(CompanionResponse.self, from: data)
                guard response.version == 1, response.requestID == request.requestID, response.sessionID == sessionID else { throw CompanionFailure.lostSession }
                if let failure = response.failure {
                    if [.timeout, .lostSession, .appCrashed].contains(failure), !(failure == .timeout && Self.readOnly(operation)) { poison(sessionID) }
                    throw failure
                }
                if operation == .snapshot {
                    guard let capture = response.capture, capture.snapshot.captureID == request.captureID,
                          capture.screenshotName == capture.snapshot.captureID.description + ".png",
                          capture.pixelWidth > 0, capture.pixelHeight > 0,
                          (try? capture.screenPoint(for: PixelPoint(x: 0, y: 0))) != nil else {
                        throw CompanionFailure.lostSession
                    }
                }
                return response
            }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                  let state = try? JSONDecoder().decode(CompanionSession.self, from: data),
                  state.sessionID == sessionID, state.state == "ready",
                  fresh(state.heartbeat, maximumAge: 30) else { throw CompanionFailure.lostSession }
            try await Task.sleep(for: .milliseconds(50))
        }
        // A timed-out command's completion is uncertain: invalidate the client rather than retry it.
        throw CompanionFailure.timeout
        } catch {
            // A timed-out read leaves the session healthy and safely retryable.
            let readTimeout = (error as? CompanionFailure) == .timeout && Self.readOnly(operation)
            let knownRejection = (error as? CompanionFailure).map { ![.timeout, .lostSession, .appCrashed].contains($0) } ?? false
            if !knownRejection && !readTimeout { poison(sessionID) }
            throw error
        }
    }
    public func snapshot(boundTo captureID: CaptureID) async throws -> UISnapshot {
        guard let capture = try await request(.snapshot, configure: { $0.captureID = captureID }).capture,
              capture.snapshot.captureID == captureID else { throw CompanionFailure.invalidRequest }
        return capture.snapshot
    }
    public func tap(identifier: String) async throws { _ = try await request(.tap) { $0.identifier = identifier } }
    public func enterText(_ text: String, intoIdentifier identifier: String) async throws {
        _ = try await request(.type) { $0.identifier = identifier; $0.text = text }
    }
    public func shutdown() async throws { _ = try await request(.shutdown); sessionID = nil }
    /// Invalidate before stopping the service, so an uncertain in-flight mutation cannot be retried.
    public func invalidate() { if let sessionID { poison(sessionID) } }
}
