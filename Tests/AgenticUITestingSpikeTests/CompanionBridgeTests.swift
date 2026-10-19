import XCTest
@testable import RunnerCore
@testable import SimulatorControl

final class CompanionBridgeTests: XCTestCase {
    func testBoundVisualPointRequestValidates() throws {
        var request = CompanionRequest(sessionID: UUID(), operation: .pointTap, bundleID: "dev.fixture")
        request.captureID = CaptureID()
        request.point = PixelPoint(x: 600, y: 1500)
        request.semanticTarget = CompanionSemanticTarget(role: "other", label: "", value: nil,
            frame: CGRectValue(x: 30, y: 456, width: 380, height: 92))
        try request.validate()
        let decoded = try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request))
        try decoded.validate()
    }
    func testSemanticTargetPreservesFrameForDuplicateLabels() throws {
        let frame = CGRectValue(x: 133, y: 427, width: 136, height: 48)
        let target = CompanionSemanticTarget(role: "button", label: "Continue", value: nil, frame: frame)
        let decoded = try JSONDecoder().decode(CompanionSemanticTarget.self, from: JSONEncoder().encode(target))
        XCTAssertEqual(decoded.frame, frame)
    }
    func testRejectsMalformedRequests() throws {
        var r = CompanionRequest(sessionID: UUID(), operation: .pointTap, bundleID: "test")
        r.captureID = CaptureID(); r.point = PixelPoint(x: .nan, y: 0)
        XCTAssertThrowsError(try r.validate()) { XCTAssertEqual($0 as? CompanionFailure, .invalidPoint) }
        r.version = 7
        XCTAssertThrowsError(try r.validate()) { XCTAssertEqual($0 as? CompanionFailure, .unsupportedVersion) }
        r.version = 1; r.deadline = 0
        XCTAssertThrowsError(try r.validate()) { XCTAssertEqual($0 as? CompanionFailure, .expired) }
        r = CompanionRequest(sessionID: UUID(), operation: .wait, bundleID: "test")
        r.identifier = "target"; r.timeout = 11
        XCTAssertThrowsError(try r.validate())
        r = CompanionRequest(sessionID: UUID(), operation: .swipe, bundleID: "test")
        r.identifier = "target"; r.direction = "arbitrary"
        XCTAssertThrowsError(try r.validate())
    }
    func testPointTransformAndBounds() throws {
        let c = CompanionCapture(snapshot: UISnapshot(captureID: CaptureID(), elements: []), screenshotName: "capture.png",
            pixelWidth: 1200, pixelHeight: 2400, screenFrame: CGRectValue(x: 0, y: 0, width: 400, height: 800))
        XCTAssertEqual(try c.screenPoint(for: PixelPoint(x: 600, y: 1200)), PixelPoint(x: 200, y: 400))
        for point in [PixelPoint(x: -1, y: 2), PixelPoint(x: 1200, y: 2), PixelPoint(x: 2, y: .infinity)] {
            XCTAssertThrowsError(try c.screenPoint(for: point))
        }
    }
    func testMailboxMatchesSessionAndRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["requests", "responses"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let state = CompanionSession(sessionID: UUID())
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("session.json"))
        let bridge = CompanionBridge(directory: root, bundleID: "test")
        try await bridge.connect(timeout: 1)
        let server = Task {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("requests"), includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
                if let file = files.first {
                    let r = try JSONDecoder().decode(CompanionRequest.self, from: Data(contentsOf: file))
                    var response = CompanionResponse(request: r, elapsedSeconds: 0)
                    response.requestID = UUID()
                    try JSONEncoder().encode(response).write(to: root.appendingPathComponent("responses").appendingPathComponent(file.lastPathComponent), options: .atomic)
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CompanionFailure.timeout
        }
        defer { server.cancel() }
        do { _ = try await bridge.request(.launch); XCTFail("Mismatched response accepted") }
        catch { XCTAssertEqual(error as? CompanionFailure, .lostSession) }
        try await server.value
    }
    func testCancellationPoisonsBothSidesAndCannotReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["requests", "responses"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let state = CompanionSession(sessionID: UUID())
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("session.json"))
        let bridge = CompanionBridge(directory: root, bundleID: "test")
        try await bridge.connect(timeout: 1)
        let pending = Task { try await bridge.request(.launch) }
        let deadline = Date().addingTimeInterval(5)
        while try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("requests"), includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }).isEmpty {
            guard Date() < deadline else { pending.cancel(); throw CompanionFailure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancellation ignored") } catch is CancellationError { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("poison-" + state.sessionID.uuidString).path))
        do { try await bridge.connect(timeout: 0.05); XCTFail("Poisoned session reconnected") }
        catch { XCTAssertEqual(error as? CompanionFailure, .timeout) }
        do { _ = try await bridge.request(.launch); XCTFail("Poisoned session reused") }
        catch { XCTAssertEqual(error as? CompanionFailure, .lostSession) }
    }
    func testReadTimeoutCanRetryButMutationTimeoutPoisonsSession() async throws {
        func session() throws -> (URL, CompanionSession, CompanionBridge) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            for name in ["requests", "responses"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            let state = CompanionSession(sessionID: UUID())
            try JSONEncoder().encode(state).write(to: root.appendingPathComponent("session.json"))
            return (root, state, CompanionBridge(directory: root, bundleID: "test"))
        }
        let (readRoot, readState, readBridge) = try session()
        defer { try? FileManager.default.removeItem(at: readRoot) }
        try await readBridge.connect(timeout: 1)
        do {
            _ = try await readBridge.request(.snapshot) {
                $0.captureID = CaptureID(); $0.deadline = Date().timeIntervalSince1970 + 0.3
            }
            XCTFail("Unanswered read succeeded")
        } catch { XCTAssertEqual(error as? CompanionFailure, .timeout) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            readRoot.appendingPathComponent("poison-" + readState.sessionID.uuidString).path))
        do {
            _ = try await readBridge.request(.wait) {
                $0.identifier = "target"; $0.timeout = 0.1; $0.deadline = Date().timeIntervalSince1970 + 0.3
            }
            XCTFail("Unanswered retry succeeded")
        } catch { XCTAssertEqual(error as? CompanionFailure, .timeout) }

        let (writeRoot, writeState, writeBridge) = try session()
        defer { try? FileManager.default.removeItem(at: writeRoot) }
        try await writeBridge.connect(timeout: 1)
        do {
            _ = try await writeBridge.request(.tap) {
                $0.identifier = "target"; $0.deadline = Date().timeIntervalSince1970 + 0.3
            }
            XCTFail("Unanswered mutation succeeded")
        } catch { XCTAssertEqual(error as? CompanionFailure, .timeout) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            writeRoot.appendingPathComponent("poison-" + writeState.sessionID.uuidString).path))
        do { _ = try await writeBridge.request(.wait); XCTFail("Poisoned session was reused") }
        catch { XCTAssertEqual(error as? CompanionFailure, .lostSession) }
    }
    func testFutureHeartbeatIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = CompanionSession(sessionID: UUID()); state.heartbeat += 3600
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("session.json"))
        let bridge = CompanionBridge(directory: root, bundleID: "test")
        do { try await bridge.connect(timeout: 0.05); XCTFail("Future heartbeat accepted") }
        catch { XCTAssertEqual(error as? CompanionFailure, .timeout) }
    }

    func testLaunchArgumentsAreBoundedAndOnlyForLaunch() throws {
        var request = CompanionRequest(sessionID: UUID(), operation: .launch, bundleID: "test")
        request.launchArguments = ["--scroll-probe"]
        XCTAssertNoThrow(try request.validate())
        request.launchArguments = Array(repeating: "x", count: 33)
        XCTAssertThrowsError(try request.validate())
        request.launchArguments = [String(repeating: "x", count: 1025)]
        XCTAssertThrowsError(try request.validate())
        request.launchArguments = Array(repeating: String(repeating: "x", count: 1024), count: 5)
        XCTAssertThrowsError(try request.validate())
        request.launchArguments = ["argument"]
        request.operation = .shutdown
        XCTAssertThrowsError(try request.validate())
    }
    func testUnknownOperationHasTypedCorrelatedRejection() throws {
        let request = CompanionRequest(sessionID: UUID(), operation: .launch, bundleID: "test")
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        dictionary["operation"] = "execute-shell"
        let malformed = try JSONSerialization.data(withJSONObject: dictionary)
        XCTAssertThrowsError(try JSONDecoder().decode(CompanionRequest.self, from: malformed))
        let response = try XCTUnwrap(CompanionResponse.malformedRequest(malformed))
        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.sessionID, request.sessionID)
        XCTAssertEqual(response.failure, .invalidRequest)
        dictionary["version"] = 99
        XCTAssertEqual(CompanionResponse.malformedRequest(try JSONSerialization.data(withJSONObject: dictionary))?.failure, .unsupportedVersion)
        XCTAssertNil(CompanionResponse.malformedRequest(Data("invalid".utf8)))
    }

}
