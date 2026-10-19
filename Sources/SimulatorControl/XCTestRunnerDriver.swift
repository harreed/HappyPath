import Foundation
import CryptoKit
import RunnerCore
import ProjectDomain
import PerceptionCore

/// Production deterministic driver; target app, simulator and companion are supplied by the project.
public actor XCTestRunnerDriver: RunnerDriving {
    private let baseDirectory: URL
    private let artifacts: URL
    private let lifecycle = ProjectSimulatorLifecycle()
    private var bridge: CompanionBridge?
    private var launchArguments: [String] = []
    private var stopped = false
    private var latestCapture: CaptureID?
    private var latestApplication: UIElement?
    private var projectID: UUID?
    private var configuredProject: TestProject?
    private var captures: [CaptureID: CompanionCapture] = [:]
    private var imageFingerprints: [CaptureID: String] = [:]
    private let recognizer: any TextRecognizing

    public init(baseDirectory: URL, artifacts: URL, recognizer: any TextRecognizing = VisionTextRecognizer()) {
        self.recognizer = recognizer
        self.baseDirectory = baseDirectory; self.artifacts = artifacts
    }

    public func prepare(project: TestProject, deadline: Date) async throws {
        try await prepare(project: project, deadline: deadline, progress: { _ in })
    }
    public func prepare(project: TestProject, deadline: Date, progress: @escaping @Sendable (ExecutionPhase) -> Void) async throws {
        projectID = project.id
        configuredProject = project
        launchArguments = project.app.launchArguments
        do {
            try FileManager.default.createDirectory(at: artifacts.appendingPathComponent("captures"), withIntermediateDirectories: true)
            bridge = try await lifecycle.prepare(project: project, baseDirectory: baseDirectory, artifacts: artifacts, deadline: deadline, progress: progress)
            stopped = false
            progress(.launching)
            _ = try await command(.launch, deadline: deadline) { $0.launchArguments = project.app.launchArguments }
        } catch {
            await stop()
            if error is CancellationError { throw error }
            throw DriverFailure.unavailable(error.localizedDescription)
        }
    }

    public func applyStartingState(_ state: TestStartingState, deadline: Date) async throws {
        guard let project = configuredProject, !stopped else { throw DriverFailure.unavailable("The Simulator is not prepared for this test") }
        guard !state.isDefault else { return }
        do {
            try await lifecycle.applyStartingState(state, project: project, baseDirectory: baseDirectory, deadline: deadline)
            latestCapture = nil
            latestApplication = nil
            _ = try await command(.launch, deadline: deadline) { $0.launchArguments = project.app.launchArguments }
        } catch {
            await stop()
            if error is CancellationError { throw error }
            throw DriverFailure.unavailable("Could not apply test starting state: \(error.localizedDescription)")
        }
    }

    public func performDeviceAction(_ action: DeviceAction, deadline: Date) async throws {
        guard let project = configuredProject, !stopped else {
            throw DriverFailure.unavailable("The Simulator is not prepared for this test")
        }
        do {
            try action.validate()
            switch action {
            case .background(let seconds):
                _ = try await command(.background, deadline: deadline) { $0.timeout = seconds }
            case .permission:
                try await lifecycle.performDeviceAction(action, project: project, deadline: deadline)
                _ = try await command(.launch, deadline: deadline) { $0.launchArguments = project.app.launchArguments }
            default:
                try await lifecycle.performDeviceAction(action, project: project, deadline: deadline)
            }
            latestCapture = nil
            latestApplication = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DriverFailure.unavailable("Could not apply device action: \(error.localizedDescription)")
        }
    }

    public func capture(deadline: Date) async throws -> UISnapshot {
        do { try await lifecycle.checkRecording() }
        catch { await stop(); throw DriverFailure.unavailable(String(describing: error)) }
        let id = CaptureID()
        let response = try await command(.snapshot, deadline: deadline) { $0.captureID = id }
        guard let capture = response.capture, let bridge,
              capture.snapshot.captureID == id, capture.screenshotName == id.description + ".png",
              capture.pixelWidth > 0, capture.pixelHeight > 0,
              (try? capture.screenPoint(for: PixelPoint(x: 0, y: 0))) != nil else {
            await stop()
            throw DriverFailure.uncertain("Companion returned invalid capture identity or geometry")
        }
        let directory = artifacts.appendingPathComponent("captures")
        guard (try? capture.validatedTiming()) == true else { throw DriverFailure.uncertain("Capture lacks valid timing provenance") }
        retainProvenance(capture)
        latestCapture = id
        latestApplication = capture.snapshot.elements.first { $0.role == "application" }
        let png = directory.appendingPathComponent(id.description + ".png")
        do {
            try FileManager.default.copyItem(at: bridge.directory.appendingPathComponent(capture.screenshotName), to: png)
            let pngData = try Data(contentsOf: png)
            imageFingerprints[id] = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(capture).write(to: directory.appendingPathComponent(id.description + ".json"), options: .withoutOverwriting)
        } catch {
            await stop()
            throw DriverFailure.unavailable("Could not preserve required capture: \(error)")
        }
        // XCTest includes off-screen scroll descendants. Assertions consume only
        // nodes whose measured frames intersect the captured application viewport.
        let viewport = capture.screenFrame
        let visible = capture.snapshot.elements.filter { element in
            guard let frame = element.frame else { return false }
            return frame.width > 0 && frame.height > 0 && frame.x < viewport.x + viewport.width &&
                frame.y < viewport.y + viewport.height && frame.x + frame.width > viewport.x &&
                frame.y + frame.height > viewport.y
        }
        return UISnapshot(captureID: capture.snapshot.captureID, capturedAt: capture.snapshot.capturedAt, elements: visible)
    }

    public func imageFingerprint(for id: CaptureID) -> String? { imageFingerprints[id] }

    public func perform(_ action: DrivenAction, deadline: Date) async throws {
        if let id = latestCapture, captures[id]?.snapshot.elements.contains(where: { $0.originBundleIdentifier == "com.apple.springboard" && ($0.role == "alert" || $0.containingAlertContext != nil) }) == true {
            // A system prompt can be handled only through its fresh, uniquely
            // selected alert button. All other input stays blocked.
            let allowed: Bool = {
                guard case .recoveryTap(let tapID, let element) = action else { return false }
                guard tapID == id,
                      captures[id]?.snapshot.elements.filter({ $0 == element }).count == 1,
                      InterruptionLibrary.systemPromptChoice(InterruptionLibrary.recognize(captures[id]!.snapshot)) == element else { return false }
                return true
            }()
            if !allowed {
                throw DriverFailure.notDispatched("System alert target is not the selected prompt button")
            }
        }
        switch action {
        case .recoveryTap(let id, let element):
            guard latestCapture == id, let capture = captures[id],
                  capture.snapshot.elements.filter({ $0 == element }).count == 1,
                  Date().timeIntervalSince(capture.snapshot.capturedAt) >= 0,
                  Date().timeIntervalSince(capture.snapshot.capturedAt) < 8 else { throw DriverFailure.notDispatched("Invalid bound recovery target") }
            _ = try await command(.tap, deadline: deadline) { $0.captureID = id; $0.recoveryTarget = element }
        case .textTap(let capture, let perception, let text, let threshold, let maximumAge):
            guard latestCapture == capture.id, let bound = captures[capture.id],
                  bound.snapshot.capturedAt == capture.createdAt,
                  perception.geometry == PerceptionGeometry(pixels: PixelSize(width: bound.pixelWidth, height: bound.pixelHeight), screenFrame: bound.screenFrame) else { throw DriverFailure.notDispatched("Mismatched OCR capture or transform") }
            let match = try perception.uniqueMatch(text: text, minimumConfidence: threshold, capture: capture, maximumAge: maximumAge)
            _ = try await command(.pointTap, deadline: deadline) { $0.captureID = capture.id; $0.point = match.center }
        case .visualTextTap(let capture, let perception, let text, let control, let threshold, let maximumAge):
            guard latestCapture == capture.id, let bound = captures[capture.id],
                  bound.snapshot.capturedAt == capture.createdAt,
                  perception.geometry == PerceptionGeometry(pixels: PixelSize(width: bound.pixelWidth, height: bound.pixelHeight), screenFrame: bound.screenFrame),
                  bound.snapshot.elements.filter({ $0 == control }).count == 1,
                  let appBundleID = configuredProject?.app.bundleIdentifier else {
                throw DriverFailure.notDispatched("Mismatched visual control capture")
            }
            let match = try perception.uniqueMatch(text: text, minimumConfidence: threshold, capture: capture, maximumAge: maximumAge)
            guard GoalNavigationSafety.enclosingVisualControl(match, perception: perception,
                snapshot: bound.snapshot, appBundleID: appBundleID) == control,
                let frame = control.frame else {
                throw DriverFailure.notDispatched("Visual control moved or became ambiguous")
            }
            let point = PixelPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            let pixels = PixelPoint(x: (point.x - bound.screenFrame.x) / bound.screenFrame.width * Double(bound.pixelWidth),
                                    y: (point.y - bound.screenFrame.y) / bound.screenFrame.height * Double(bound.pixelHeight))
            guard (try? perception.geometry.screenPoint(for: pixels)) != nil else {
                throw DriverFailure.notDispatched("Visual control is outside the app viewport")
            }
            _ = try await command(.pointTap, deadline: deadline) {
                $0.captureID = capture.id
                $0.point = pixels
                $0.semanticTarget = CompanionSemanticTarget(role: control.role,
                    label: control.label, value: control.value, frame: frame)
            }
        case .secureTextTap(let capture, let perception, let text, let secret):
            guard latestCapture == capture.id, let bound = captures[capture.id],
                  bound.snapshot.capturedAt == capture.createdAt,
                  perception.geometry == PerceptionGeometry(pixels: PixelSize(width: bound.pixelWidth, height: bound.pixelHeight), screenFrame: bound.screenFrame) else {
                throw DriverFailure.notDispatched("Mismatched secure-input capture")
            }
            let match = try perception.uniqueMatch(text: text, minimumConfidence: 0.4,
                capture: capture, maximumAge: 8)
            guard case .appleAccountPassword(let account) = secret else {
                throw DriverFailure.notDispatched("Unsupported stored secret")
            }
            guard let projectID else { throw DriverFailure.missingSecret(secret) }
            let password: String?
            do {
                let directory = baseDirectory
                password = try await boundedProviderCall(deadline: min(deadline, Date().addingTimeInterval(15))) {
                    try AppleAccountSecretStore().password(for: account,
                        projectID: projectID, projectDirectory: directory)
                }
            } catch ProviderFailure.deadline {
                // Keychain can wait indefinitely for a macOS authorization dialog.
                // This is a real human blocker, not a stale screenshot.
                throw DriverFailure.credentialAccessRequired(secret)
            }
            guard let password else {
                throw DriverFailure.missingSecret(secret)
            }
            guard let publicData = await bridge?.secretPublicKey else {
                throw DriverFailure.unavailable("Companion secure-input key is unavailable")
            }
            let envelope = try SecureInputCrypto.seal(Data(password.utf8),
                for: capture.id, recipientPublicKey: publicData)
            // XCTest may include typed input in its activity archive. Mark the run
            // before dispatch so cleanup discards raw XCTest output even on failure.
            try Data().write(to: artifacts.appendingPathComponent("secure-input-used"), options: .atomic)
            do {
                _ = try await command(.pointTypeSecret, deadline: deadline) {
                    $0.captureID = capture.id; $0.point = match.center; $0.encryptedSecret = envelope
                }
            } catch DriverFailure.notDispatched(let reason) where reason == "unavailableTarget" {
                // AuthKit can draw a password field that XCTest does not expose.
                // Repeating the same capture and target cannot enter a secret.
                throw DriverFailure.secureInputUnavailable(secret)
            } catch DriverFailure.uncertain(let reason) where
                ["timeout", "lostSession"].contains(reason.split(separator: " ").first.map(String.init) ?? "") {
                // The companion did not acknowledge the secure action. Do not
                // retry a password that might already have been entered.
                throw DriverFailure.secureInputUnverified(secret)
            }
        case .tap(let identifier):
            _ = try await command(.tap, deadline: deadline) { $0.identifier = identifier }
        case .typeText(let text, let identifier):
            _ = try await command(.type, deadline: deadline) { $0.identifier = identifier; $0.text = text }
        case .swipe(let direction, let identifier):
            if let identifier {
                _ = try await command(.swipe, deadline: deadline) { $0.identifier = identifier; $0.direction = direction.rawValue }
            } else {
                guard let application = latestApplication else { throw DriverFailure.unavailable("Capture has no application viewport") }
                try await semantic(.swipe, element: application, direction: direction.rawValue, deadline: deadline)
            }
        case .relaunch:
            let arguments = launchArguments
            _ = try await command(.launch, deadline: deadline) { $0.launchArguments = arguments }
        case .device(let deviceAction):
            try await performDeviceAction(deviceAction, deadline: deadline)
        case .tapElement(let element):
            try await semantic(.tap, element: element, deadline: deadline)
        case .typeTextElement(let text, let element):
            try await semantic(.type, element: element, text: text, deadline: deadline)
        case .swipeElement(let direction, let element):
            try await semantic(.swipe, element: element, direction: direction.rawValue, deadline: deadline)
        }
        latestCapture = nil
    }

    // Explicit async matches the protocol requirement; otherwise concrete forwarding
    // can select the protocol extension's async default instead of this actor method.
    public func provenance(for id: CaptureID) async -> CompanionCapture? { captures[id] }
    public func visualImageData(for id: CaptureID) async throws -> Data {
        guard latestCapture == id, let capture = captures[id],
              capture.snapshot.captureID == id,
              capture.screenshotName == "\(id.description).png" else { throw PerceptionFailure.captureMismatch }
        let url = artifacts.appendingPathComponent("captures/\(capture.screenshotName)")
        return try boundedVisualData(at: url, root: artifacts.appendingPathComponent("captures"))
    }
    public func referenceImageData(for id: UUID) async throws -> Data {
        let references = baseDirectory.appendingPathComponent("references")
        let url = references.appendingPathComponent("\(id.uuidString.lowercased()).png")
        let data = try boundedVisualData(at: url, root: references)
        let archiveReferences = artifacts.appendingPathComponent("references")
        try FileManager.default.createDirectory(at: archiveReferences, withIntermediateDirectories: true)
        try data.write(to: archiveReferences.appendingPathComponent("\(id.uuidString.lowercased()).png"), options: .atomic)
        return data
    }
    private func boundedVisualData(at url: URL, root: URL) throws -> Data {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedURL.deletingLastPathComponent() == resolvedRoot,
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= 100_000_000 else {
            throw DriverFailure.unavailable("Visual image evidence is missing or invalid")
        }
        return try Data(contentsOf: resolvedURL)
    }
    func retainProvenance(_ capture: CompanionCapture) { captures[capture.snapshot.captureID] = capture }
    public func warmupPerception(deadline: Date) async throws -> PerceptionWarmup {
        let start = Date(); let tick = DispatchTime.now().uptimeNanoseconds
        let recognizer = self.recognizer
        try await boundedPerception(deadline: deadline) { try await recognizer.prewarm() }
        return .init(startedAt: start, completedAt: Date(), milliseconds: Double(DispatchTime.now().uptimeNanoseconds - tick) / 1_000_000)
    }
    public func warmupPerceptionFast(deadline: Date) async throws -> PerceptionWarmup {
        let start = Date(); let tick = DispatchTime.now().uptimeNanoseconds
        let recognizer = self.recognizer
        try await boundedPerception(deadline: deadline) { try await recognizer.prewarmFast() }
        return .init(startedAt: start, completedAt: Date(), milliseconds: Double(DispatchTime.now().uptimeNanoseconds - tick) / 1_000_000)
    }
    public func recognizeText(for id: CaptureID, deadline: Date) async throws -> TextPerception {
        try await recognizeText(for: id, deadline: deadline, fast: false)
    }
    public func recognizeTextFast(for id: CaptureID, deadline: Date) async throws -> TextPerception {
        try await recognizeText(for: id, deadline: deadline, fast: true)
    }
    private func recognizeText(for id: CaptureID, deadline: Date, fast: Bool) async throws -> TextPerception {
        guard latestCapture == id, let bound = captures[id] else { throw PerceptionFailure.captureMismatch }
        let data = try Data(contentsOf: artifacts.appendingPathComponent("captures/" + bound.screenshotName))
        let capture = ScreenCapture(id: id, createdAt: bound.snapshot.capturedAt,
            pixelSize: PixelSize(width: bound.pixelWidth, height: bound.pixelHeight), screenshotRelativePath: "captures/" + bound.screenshotName)
        let geometry = PerceptionGeometry(pixels: capture.pixelSize, screenFrame: bound.screenFrame)
        let recognizer = self.recognizer
        while true {
            do {
                return try await boundedPerception(deadline: deadline) {
                    if fast {
                        return try await recognizer.recognizeFast(imageData: data, capture: capture, geometry: geometry)
                    }
                    do {
                        return try await recognizer.recognize(imageData: data, capture: capture, geometry: geometry)
                    } catch {
                        if error is CancellationError { throw error }
                        let native = error as NSError
                        guard native.domain == "Foundation._GenericObjCError" else { throw error }
                        // Vision's accurate request can fail inside its native
                        // service for an otherwise valid screenshot. The fast
                        // request uses a separate recognition path on the same
                        // capture, preserving the target's provenance.
                        do {
                            return try await recognizer.recognizeFast(imageData: data, capture: capture, geometry: geometry)
                        } catch {
                            let fallback = error as NSError
                            throw DriverFailure.unavailable("Vision OCR failed in accurate and fast modes (\(native.domain) \(native.code); \(fallback.domain) \(fallback.code))")
                        }
                    }
                }
            } catch PerceptionFailure.workerBusy {
                // A previous Vision request can still be unwinding after cancellation.
                // Wait for its serial worker instead of treating the visible sheet as absent.
                guard deadline.timeIntervalSinceNow > 0.35 else { throw PerceptionFailure.workerBusy }
                try await Task.sleep(for: .milliseconds(350))
            }
        }
    }
    private func boundedPerception<T: Sendable>(deadline: Date, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard deadline > Date() else { throw DriverFailure.unavailable("Perception deadline elapsed") }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                throw DriverFailure.unavailable("Perception deadline exceeded")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func semantic(_ operation: CompanionOperation, element: UIElement, text: String? = nil, direction: String? = nil, deadline: Date) async throws {
        guard element.originBundleIdentifier == nil || element.originBundleIdentifier != "com.apple.springboard" else { throw DriverFailure.notDispatched("Foreign-origin semantic target") }
        guard let captureID = latestCapture else { throw DriverFailure.notDispatched("No current semantic capture") }
        _ = try await command(operation, deadline: deadline) {
            $0.captureID = captureID
            $0.semanticTarget = CompanionSemanticTarget(role: element.role, label: element.label,
                value: element.value, frame: element.frame)
            $0.text = text; $0.direction = direction
        }
    }

    private func command(_ operation: CompanionOperation, deadline: Date,
                         configure: @Sendable (inout CompanionRequest) -> Void) async throws -> CompanionResponse {
        try Task.checkCancellation()
        guard !stopped, let bridge else { throw DriverFailure.unavailable("Companion is not running") }
        guard deadline.timeIntervalSinceNow > 0 else { throw DriverFailure.notDispatched("Deadline elapsed before dispatch") }
        let dispatchedAt = Date()
        do {
            return try await bridge.request(operation) {
                $0.deadline = min(deadline.timeIntervalSince1970, Date().timeIntervalSince1970 + 59)
                configure(&$0)
            }
        } catch {
            if error is CancellationError { await stop(); throw error }
            if let failure = error as? CompanionFailure {
                switch failure {
                case .absentTarget, .unavailableTarget, .ambiguousTarget, .expired:
                    throw DriverFailure.notDispatched(failure.rawValue)
                case .invalidRequest, .unsupportedVersion, .invalidPoint, .staleCapture, .contextChanged:
                    throw DriverFailure.unavailable(failure.rawValue)
                case .timeout, .lostSession, .appCrashed:
                    // A timed-out read has no unknown input side effect; keep the
                    // companion alive so the next capture can retry it.
                    if failure != .timeout || operation != .snapshot { await stop() }
                    throw Self.terminalFailure(failure, operation: operation,
                        elapsedSeconds: Date().timeIntervalSince(dispatchedAt))
                }
            }
            await stop()
            throw DriverFailure.uncertain(String(describing: error))
        }
    }

    /// A failed read has no unknown input side effect. The engine can distinguish
    /// an exhausted wait budget from a capture environment failure using its deadline.
    static func terminalFailure(_ failure: CompanionFailure, operation: CompanionOperation,
                                elapsedSeconds: Double? = nil) -> DriverFailure {
        let reason = elapsedSeconds.map { elapsed in
            "\(failure.rawValue) during \(operation.rawValue) after \(String(format: "%.1f", max(0, elapsed)))s"
        } ?? failure.rawValue
        return operation == .snapshot ? .unavailable(reason) : .uncertain(reason)
    }

    public func stop() async {
        stopped = true
        await bridge?.invalidate()
        bridge = nil
        await lifecycle.stop()
    }
    public func finish() async throws {
        stopped = true
        await bridge?.invalidate()
        bridge = nil
        try await lifecycle.finish()
    }
}
