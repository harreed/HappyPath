import Foundation

/// Shared wire types compiled into both the Mac client and XCTest companion.
public enum CompanionOperation: String, Codable, Sendable {
    case launch, snapshot, tap, type, swipe, wait, pointTap, pointTypeSecret, background, shutdown
}
public struct EncryptedSecret: Codable, Sendable {
    public let senderPublicKey: Data
    public let sealedBox: Data
    public init(senderPublicKey: Data, sealedBox: Data) {
        self.senderPublicKey = senderPublicKey; self.sealedBox = sealedBox
    }
}
public enum CompanionFailure: String, Codable, Error, Sendable {
    case unsupportedVersion, invalidRequest, expired, absentTarget, ambiguousTarget
    case unavailableTarget, staleCapture, contextChanged, invalidPoint, timeout, lostSession, appCrashed
}
public struct CompanionSemanticTarget: Codable, Sendable, Equatable {
    public let role: String
    public let label: String?
    public let value: String?
    public let frame: CGRectValue?
    public init(role: String, label: String?, value: String?, frame: CGRectValue? = nil) {
        self.role = role; self.label = label; self.value = value; self.frame = frame
    }
}
public struct CompanionRequest: Codable, Sendable {
    public var version = 1
    public var requestID = UUID()
    public var sessionID: UUID
    public var operation: CompanionOperation
    public var deadline: Double
    public var bundleID: String
    public var captureID: CaptureID?
    public var identifier: String?
    public var semanticTarget: CompanionSemanticTarget?
    public var recoveryTarget: UIElement?
    public var text: String?
    public var direction: String?
    public var point: PixelPoint?
    public var encryptedSecret: EncryptedSecret?
    public var timeout: Double?
    public var disappear: Bool?
    public var launchArguments: [String]?
    public init(sessionID: UUID, operation: CompanionOperation, bundleID: String, timeout: Double = 15) {
        self.sessionID = sessionID; self.operation = operation; self.bundleID = bundleID
        self.deadline = Date().timeIntervalSince1970 + timeout
    }
    public func validate(now: Double = Date().timeIntervalSince1970) throws {
        guard version == 1 else { throw CompanionFailure.unsupportedVersion }
        guard deadline.isFinite, deadline > now else { throw CompanionFailure.expired }
        guard deadline - now <= 60, !bundleID.isEmpty, bundleID.count < 256 else { throw CompanionFailure.invalidRequest }
        if let launchArguments {
            guard operation == .launch, launchArguments.count <= 32,
                  launchArguments.allSatisfy({ $0.utf8.count <= 1024 && !$0.contains("\0") }),
                  launchArguments.reduce(0, { $0 + $1.utf8.count }) <= 4096 else { throw CompanionFailure.invalidRequest }
        }
        if let recoveryTarget {
            guard operation == .tap, semanticTarget == nil, identifier == nil, captureID != nil,
                  recoveryTarget.label?.isEmpty == false, recoveryTarget.role == "button",
                  recoveryTarget.containingAlertIdentifier != nil, recoveryTarget.containingAlertContext != nil else { throw CompanionFailure.invalidRequest }
        } else if let semanticTarget {
            guard [.tap, .type, .swipe, .pointTap].contains(operation), identifier == nil, captureID != nil,
                  !semanticTarget.role.isEmpty, semanticTarget.role.count < 100,
                  (semanticTarget.label?.count ?? 0) <= 4096, (semanticTarget.value?.count ?? 0) <= 4096 else { throw CompanionFailure.invalidRequest }
            if operation == .pointTap {
                guard semanticTarget.frame != nil,
                      ["other", "button", "cell", "link"].contains(semanticTarget.role),
                      (semanticTarget.label ?? "").isEmpty else { throw CompanionFailure.invalidRequest }
            }
        } else if [.tap, .type, .swipe, .wait].contains(operation) {
            guard let identifier, !identifier.isEmpty, identifier.count < 512 else { throw CompanionFailure.invalidRequest }
        }
        if operation == .type { guard let text, text.count <= 4096 else { throw CompanionFailure.invalidRequest }; }
        if operation == .swipe { guard ["up", "down", "left", "right"].contains(direction) else { throw CompanionFailure.invalidRequest }; }
        if operation == .wait { guard let timeout, timeout.isFinite, (0...10).contains(timeout) else { throw CompanionFailure.invalidRequest }; }
        if operation == .background { guard let timeout, timeout.isFinite, (0...20).contains(timeout) else { throw CompanionFailure.invalidRequest }; }
        if operation == .snapshot || operation == .pointTap || operation == .pointTypeSecret { guard captureID != nil else { throw CompanionFailure.invalidRequest }; }
        if operation == .pointTap || operation == .pointTypeSecret { guard let point, point.x.isFinite, point.y.isFinite else { throw CompanionFailure.invalidPoint }; }
        if operation == .pointTypeSecret {
            guard text == nil, let encryptedSecret,
                  encryptedSecret.senderPublicKey.count == 32,
                  (28...8192).contains(encryptedSecret.sealedBox.count) else { throw CompanionFailure.invalidRequest }
        } else if encryptedSecret != nil { throw CompanionFailure.invalidRequest }
    }
}
public struct CompanionCapture: Codable, Sendable {
    public let snapshot: UISnapshot
    public let screenshotName: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let screenFrame: CGRectValue
    public let screenshotCompletedAt: Date?
    public let semanticStartedAt: Date?
    public let semanticTreeCompletedAt: Date?
    public let semanticCompletedAt: Date?
    public init(snapshot: UISnapshot, screenshotName: String, pixelWidth: Int, pixelHeight: Int, screenFrame: CGRectValue, screenshotCompletedAt: Date? = nil, semanticStartedAt: Date? = nil, semanticTreeCompletedAt: Date? = nil, semanticCompletedAt: Date? = nil) {
        self.snapshot = snapshot; self.screenshotName = screenshotName
        self.screenshotCompletedAt = screenshotCompletedAt; self.semanticStartedAt = semanticStartedAt
        self.semanticTreeCompletedAt = semanticTreeCompletedAt; self.semanticCompletedAt = semanticCompletedAt
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.screenFrame = screenFrame
    }
    public func screenPoint(for point: PixelPoint) throws -> PixelPoint {
        guard pixelWidth > 0, pixelHeight > 0, point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x < Double(pixelWidth), point.y < Double(pixelHeight),
              screenFrame.x.isFinite, screenFrame.y.isFinite, screenFrame.width.isFinite, screenFrame.height.isFinite,
              screenFrame.width > 0, screenFrame.height > 0,
              (screenFrame.x + screenFrame.width).isFinite, (screenFrame.y + screenFrame.height).isFinite else { throw CompanionFailure.invalidPoint }
        return PixelPoint(x: screenFrame.x + (point.x / Double(pixelWidth)) * screenFrame.width,
                          y: screenFrame.y + (point.y / Double(pixelHeight)) * screenFrame.height)
    }
}
public struct CompanionResponse: Codable, Sendable {
    public var version = 1
    public var requestID: UUID
    public var sessionID: UUID
    public var elapsedSeconds: Double
    public var failure: CompanionFailure?
    public var capture: CompanionCapture?
    public init(request: CompanionRequest, elapsedSeconds: Double, failure: CompanionFailure? = nil, capture: CompanionCapture? = nil) {
        requestID = request.requestID; sessionID = request.sessionID
        self.elapsedSeconds = elapsedSeconds; self.failure = failure; self.capture = capture
    }
}
public struct CompanionSession: Codable, Sendable {
    public let version: Int
    public let sessionID: UUID
    public let startedAt: Double
    public var heartbeat: Double
    public var state: String
    public let secretPublicKey: Data?
    public init(sessionID: UUID, state: String = "ready", secretPublicKey: Data? = nil) {
        version = 1; self.sessionID = sessionID; startedAt = Date().timeIntervalSince1970
        heartbeat = startedAt; self.state = state; self.secretPublicKey = secretPublicKey
    }
}

/// Recover only the correlation envelope; never dispatch a partially decoded command.
public extension CompanionResponse {
    static func malformedRequest(_ data: Data) -> CompanionResponse? {
        struct Envelope: Decodable { let version: Int; let requestID: UUID; let sessionID: UUID }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        var placeholder = CompanionRequest(sessionID: envelope.sessionID, operation: .shutdown, bundleID: "")
        placeholder.requestID = envelope.requestID
        return CompanionResponse(request: placeholder, elapsedSeconds: 0,
            failure: envelope.version == 1 ? .invalidRequest : .unsupportedVersion)
    }
}
