import XCTest
import CryptoKit
import UIKit

/// Deliberately contains no fixture flow: the Mac client supplies each individual command.
final class CompanionServiceTests: XCTestCase {
    @MainActor func testServe() throws {
        guard ProcessInfo.processInfo.environment["COMPANION_SERVICE_ENABLED"] == "1" else {
            throw XCTSkip("Companion service requires explicit opt-in; use the CompanionService scheme")
        }
        continueAfterFailure = false
        guard let allowedBundle = ProcessInfo.processInfo.environment["COMPANION_TARGET_BUNDLE_ID"], !allowedBundle.isEmpty else {
            throw CompanionFailure.invalidRequest
        }
        let fm = FileManager.default
        let root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CompanionMailbox")
        let requests = root.appendingPathComponent("requests")
        let responses = root.appendingPathComponent("responses")
        try fm.createDirectory(at: requests, withIntermediateDirectories: true)
        try fm.createDirectory(at: responses, withIntermediateDirectories: true)
        let inputKey = Curve25519.KeyAgreement.PrivateKey()
        var session = CompanionSession(sessionID: UUID(),
            secretPublicKey: inputKey.publicKey.rawRepresentation)
        func heartbeat(_ state: String = "ready") throws {
            session.heartbeat = Date().timeIntervalSince1970; session.state = state
            try JSONEncoder().encode(session).write(to: root.appendingPathComponent("session.json"), options: .atomic)
        }
        try heartbeat()
        defer { try? heartbeat("closed") }
        let lifetime = Date().addingTimeInterval(900)
        var app: XCUIApplication?
        var launchedArguments: [String] = []
        var current: CompanionCapture?
        var captureIDs = Set<CaptureID>()
        var seen = Set<UUID>()
        var stop = false
        var processedRequests = 0
        func isPoisoned() -> Bool { fm.fileExists(atPath: root.appendingPathComponent("poison-" + session.sessionID.uuidString).path) }
        func systemInputGuard() throws {
            guard !XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists else { throw CompanionFailure.unavailableTarget }
        }
        func dispatchGuard(_ request: CompanionRequest) throws {
            guard !isPoisoned() else { throw CompanionFailure.lostSession }
            guard Date().timeIntervalSince1970 < request.deadline else { throw CompanionFailure.timeout }
        }
        func backgroundAndReturn(_ app: XCUIApplication, request: CompanionRequest) throws {
            try dispatchGuard(request)
            XCUIDevice.shared.press(.home)
            defer { app.activate() }
            let until = Date().addingTimeInterval(request.timeout ?? 0)
            while Date() < until {
                try dispatchGuard(request)
                RunLoop.current.run(until: min(until, Date().addingTimeInterval(0.05)))
            }
            try dispatchGuard(request)
        }
        while !stop && !isPoisoned() && Date() < lifetime && processedRequests < 2048 {
            try heartbeat()
            let files = try fm.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files.prefix(32) {
                guard processedRequests < 2048 else { break }
                processedRequests += 1
                // Payloads are bounded before decoding; malformed files are quarantined by removal.
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32_768,
                      let data = try? Data(contentsOf: file), data.count <= 32_768 else {
                    try fm.removeItem(at: file); continue
                }
                guard let request = try? JSONDecoder().decode(CompanionRequest.self, from: data) else {
                    if let rejection = CompanionResponse.malformedRequest(data) {
                        try JSONEncoder().encode(rejection).write(to: responses.appendingPathComponent(rejection.requestID.uuidString + ".json"), options: .atomic)
                    }
                    try fm.removeItem(at: file); continue
                }
                try fm.removeItem(at: file)
                let start = Date()
                var capture: CompanionCapture?
                var failure: CompanionFailure?
                var requestStage = "validation"
                do {
                    try request.validate()
                    requestStage = "session"
                    guard request.sessionID == session.sessionID else { throw CompanionFailure.lostSession }
                    requestStage = "uniqueness"
                    guard seen.insert(request.requestID).inserted else { throw CompanionFailure.invalidRequest }
                    requestStage = "bundle"
                    guard request.bundleID == allowedBundle else { throw CompanionFailure.invalidRequest }
                    requestStage = "dispatch"
                    if request.operation == .shutdown { stop = true }
                    else if request.operation == .launch {
                        try dispatchGuard(request)
                        app?.terminate(); current = nil
                        let target = XCUIApplication(bundleIdentifier: request.bundleID)
                        target.launchArguments = request.launchArguments ?? []
                        launchedArguments = target.launchArguments
                        try dispatchGuard(request)
                        target.launch(); app = target
                        Self.skipEventQuiescence(target)
                    } else {
                        guard let app else { throw CompanionFailure.lostSession }
                        guard app.state != .notRunning else { throw CompanionFailure.appCrashed }
                        guard request.operation == .background || app.state == .runningForeground else { throw CompanionFailure.unavailableTarget }
                        switch request.operation {
                        case .background:
                            current = nil
                            try backgroundAndReturn(app, request: request)
                            guard app.state == .runningForeground else { throw CompanionFailure.unavailableTarget }
                        case .snapshot:
                            let id = request.captureID!
                            guard captureIDs.insert(id).inserted else { throw CompanionFailure.staleCapture }
                            let capturedAt = Date()
                            let screenshot = XCUIScreen.main.screenshot()
                            let screenshotCompletedAt = Date()
                            guard let image = screenshot.image.cgImage else { throw CompanionFailure.invalidRequest }
                            let frame = app.frame
                            guard frame.origin == .zero, frame.width > 0, frame.height > 0 else { throw CompanionFailure.invalidRequest }
                            let name = id.description + ".png"
                            try screenshot.pngRepresentation.write(to: root.appendingPathComponent(name), options: .atomic)
                            let semanticStartedAt = Date()
                            let tree = try app.snapshot()
                            let semanticTreeCompletedAt = Date()
                            // Build identifier leaves once. Looking for matching leaves
                            // by traversing the whole tree for every row grows quadratically
                            // on long, non-lazy lists even after XCTest has fetched the tree.
                            let identifierLeaves = launchedArguments.contains("--snapshot-baseline")
                                ? nil : Self.snapshotIdentifierLeaves(tree)
                            let deadline = Date(timeIntervalSince1970: request.deadline)
                            var elements: [UIElement] = []
                            func walk(_ node: XCUIElementSnapshot, origin: String, readOnly: Bool = false, alertIdentity: String? = nil, alertContext: String? = nil) throws {
                                guard Date() < deadline else { throw CompanionFailure.timeout }
                                let isAlert = node.elementType == .alert
                                let identity = isAlert ? (node.identifier.isEmpty ? "alert:" + node.label : node.identifier) : alertIdentity
                                let context = isAlert ? Self.alertContext(node) : alertContext
                                // Snapshot-only matching: live XCUITest queries here cost one
                                // full-tree round trip per node and stall on web content.
                                let semantic = CompanionSemanticTarget(role: Self.role(node.elementType), label: node.label,
                                    value: node.value as? String, frame: CGRectValue(x: node.frame.minX, y: node.frame.minY,
                                        width: node.frame.width, height: node.frame.height))
                                let canActSemantically = ["button", "textField", "secureTextField", "textView", "scrollView"].contains(semantic.role)
                                let matches: [XCUIElementSnapshot] = readOnly ? [] : node.identifier.isEmpty
                                    ? (canActSemantically ? Self.snapshotSemanticLeaves(tree, target: semantic) : [])
                                    : (identifierLeaves.map { $0[Self.norm(node.identifier)] ?? [] }
                                        ?? Self.snapshotLeaves(tree, identifier: node.identifier))
                                let hittable = matches.count == 1 ? Self.snapshotHittable(matches[0], appFrame: frame) : nil
                                func hasMatchingDescendant(_ n: XCUIElementSnapshot) -> Bool {
                                    n.children.contains { Self.norm($0.identifier) == Self.norm(node.identifier) || hasMatchingDescendant($0) }
                                }
                                func hasSemanticDescendant(_ n: XCUIElementSnapshot) -> Bool {
                                    n.children.contains { (Self.norm(Self.role($0.elementType)) == Self.norm(semantic.role) && Self.fieldEq($0.label, semantic.label) && Self.fieldEq($0.value as? String, semantic.value)) || hasSemanticDescendant($0) }
                                }
                                let duplicateWrapper = node.identifier.isEmpty ? (canActSemantically && hasSemanticDescendant(node)) : hasMatchingDescendant(node)
                                if !duplicateWrapper { elements.append(UIElement(identifier: node.identifier.isEmpty ? nil : node.identifier,
                                    role: Self.role(node.elementType), label: node.label, value: node.value as? String,
                                    frame: CGRectValue(x: node.frame.minX, y: node.frame.minY, width: node.frame.width, height: node.frame.height),
                                    isEnabled: node.isEnabled, isHittable: hittable,
                                    containingAlertIdentifier: identity, containingAlertContext: context, buttonRole: nil, originBundleIdentifier: origin)) }
                                for child in node.children { try walk(child, origin: origin, readOnly: readOnly, alertIdentity: identity, alertContext: context) }
                            }
                            try walk(tree, origin: request.bundleID)
                            // Observe OS prompts and record live button hittability for
                            // the later capture-bound system prompt decision.
                            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                            for alert in springboard.alerts.allElementsBoundByIndex {
                                let systemTree = try alert.snapshot()
                                try walk(systemTree, origin: "com.apple.springboard", readOnly: true)
                                let context = Self.alertContext(systemTree)
                                let liveButtons = alert.descendants(matching: .button).allElementsBoundByIndex
                                for index in elements.indices {
                                    let node = elements[index]
                                    guard node.originBundleIdentifier == "com.apple.springboard", node.role == "button",
                                          node.containingAlertContext == context,
                                          let label = node.label else { continue }
                                    let matches = liveButtons.filter { Self.norm($0.label) == Self.norm(label) }
                                    guard matches.count == 1 else { continue }
                                    elements[index] = UIElement(identifier: node.identifier, role: node.role, label: node.label,
                                        value: node.value, frame: node.frame, isEnabled: matches[0].isEnabled,
                                        isHittable: matches[0].isHittable, containingAlertIdentifier: node.containingAlertIdentifier,
                                        containingAlertContext: node.containingAlertContext, buttonRole: node.buttonRole,
                                        originBundleIdentifier: node.originBundleIdentifier)
                                }
                            }
                            capture = CompanionCapture(snapshot: UISnapshot(captureID: id, capturedAt: capturedAt, elements: elements), screenshotName: name,
                                pixelWidth: image.width, pixelHeight: image.height,
                                screenFrame: CGRectValue(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                                screenshotCompletedAt: screenshotCompletedAt, semanticStartedAt: semanticStartedAt,
                                semanticTreeCompletedAt: semanticTreeCompletedAt, semanticCompletedAt: Date())
                            current = capture
                        case .tap, .type, .swipe:
                            let element: XCUIElement
                            if let target = request.recoveryTarget {
                                if target.originBundleIdentifier == "com.apple.springboard" {
                                    guard request.operation == .tap else { throw CompanionFailure.unavailableTarget }
                                    guard let bound = current, bound.snapshot.captureID == request.captureID,
                                          Date().timeIntervalSince(bound.snapshot.capturedAt) >= 0,
                                          Date().timeIntervalSince(bound.snapshot.capturedAt) < 8,
                                          bound.snapshot.elements.filter({ $0 == target }).count == 1,
                                          Self.systemPromptChoice(bound.snapshot) == target,
                                          app.frame == CGRect(x: bound.screenFrame.x, y: bound.screenFrame.y, width: bound.screenFrame.width, height: bound.screenFrame.height) else { throw CompanionFailure.staleCapture }
                                    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                                    let systemAlerts = springboard.alerts.allElementsBoundByIndex.compactMap { alert -> (XCUIElement, String)? in
                                        guard let tree = try? alert.snapshot() else { return nil }
                                        let identity = tree.identifier.isEmpty ? "alert:" + tree.label : tree.identifier
                                        guard identity == target.containingAlertIdentifier else { return nil }
                                        return (alert, Self.alertContext(tree))
                                    }
                                    guard systemAlerts.count == 1 else { throw CompanionFailure.staleCapture }
                                    guard systemAlerts[0].1 == target.containingAlertContext else { throw CompanionFailure.contextChanged }
                                    func matchesSystemTarget(_ candidate: XCUIElement) -> Bool {
                                        guard let node = try? candidate.snapshot() else { return false }
                                        let idOK: Bool = {
                                            switch (node.identifier.isEmpty ? nil : node.identifier, target.identifier) {
                                            case (nil, nil): return true
                                            case (let a?, let b?): return Self.norm(a) == Self.norm(b)
                                            default: return false
                                            }
                                        }()
                                        return idOK && Self.fieldEq(node.label, target.label) && Self.fieldEq(node.value as? String, target.value)
                                    }
                                    let systemMatches = systemAlerts[0].0.descendants(matching: .button).allElementsBoundByIndex.filter {
                                        matchesSystemTarget($0) && !$0.descendants(matching: .button).allElementsBoundByIndex.contains(where: matchesSystemTarget)
                                    }
                                    guard systemMatches.count == 1, systemMatches[0].isEnabled, systemMatches[0].isHittable else { throw CompanionFailure.unavailableTarget }
                                    element = systemMatches[0]
                                } else {
                                guard target.originBundleIdentifier == nil || target.originBundleIdentifier == request.bundleID else { throw CompanionFailure.unavailableTarget }
                                guard let bound = current, bound.snapshot.captureID == request.captureID,
                                      Date().timeIntervalSince(bound.snapshot.capturedAt) >= 0,
                                      Date().timeIntervalSince(bound.snapshot.capturedAt) < 8,
                                      bound.snapshot.elements.filter({ $0 == target }).count == 1,
                                      app.frame == CGRect(x: bound.screenFrame.x, y: bound.screenFrame.y, width: bound.screenFrame.width, height: bound.screenFrame.height) else { throw CompanionFailure.staleCapture }
                                let alerts = app.alerts.allElementsBoundByIndex.compactMap { alert -> (XCUIElement, String)? in
                                    guard let tree = try? alert.snapshot() else { return nil }
                                    let identity = tree.identifier.isEmpty ? "alert:" + tree.label : tree.identifier
                                    guard identity == target.containingAlertIdentifier else { return nil }
                                    return (alert, Self.alertContext(tree))
                                }
                                guard alerts.count == 1 else { throw CompanionFailure.staleCapture }
                                guard alerts[0].1 == target.containingAlertContext else { throw CompanionFailure.contextChanged }
                                func matchesTarget(_ candidate: XCUIElement) -> Bool {
                                    guard let node = try? candidate.snapshot() else { return false }
                                    let idOK: Bool = {
                                        switch (node.identifier.isEmpty ? nil : node.identifier, target.identifier) {
                                        case (nil, nil): return true
                                        case (let a?, let b?): return Self.norm(a) == Self.norm(b)
                                        default: return false
                                        }
                                    }()
                                    return idOK && Self.fieldEq(node.label, target.label) && Self.fieldEq(node.value as? String, target.value)
                                }
                                let matches = alerts[0].0.descendants(matching: .button).allElementsBoundByIndex.filter {
                                    matchesTarget($0) && !$0.descendants(matching: .button).allElementsBoundByIndex.contains(where: matchesTarget)
                                }
                                guard matches.count == 1, matches[0].isEnabled, matches[0].isHittable else { throw CompanionFailure.unavailableTarget }
                                element = matches[0]
                                }
                            } else if let target = request.semanticTarget {
                                guard let bound = current, bound.snapshot.captureID == request.captureID,
                                      Date().timeIntervalSince(bound.snapshot.capturedAt) >= 0,
                                      Date().timeIntervalSince(bound.snapshot.capturedAt) < 10,
                                      Self.snapshotMatchCount(bound.snapshot, target: target, bundleID: request.bundleID) == 1,
                                      app.frame == CGRect(x: bound.screenFrame.x, y: bound.screenFrame.y, width: bound.screenFrame.width, height: bound.screenFrame.height) else { throw CompanionFailure.staleCapture }
                                let matches = Self.semanticLeaves(app, target: target)
                                guard !matches.isEmpty else { throw CompanionFailure.absentTarget }
                                guard matches.count == 1 else { throw CompanionFailure.ambiguousTarget }
                                guard matches[0].isEnabled && matches[0].isHittable else { throw CompanionFailure.unavailableTarget }
                                element = matches[0]
                            } else { element = try Self.resolve(app, identifier: request.identifier!, actionable: true) }
                            if let target = request.recoveryTarget, target.originBundleIdentifier == "com.apple.springboard",
                               let bound = current, Self.systemPromptChoice(bound.snapshot) == target {
                                // The selected prompt button bypasses the overlay guard.
                            } else {
                                try systemInputGuard()
                            }
                            // Live queries above may be slow. Revalidate age at the final dispatch boundary.
                            if request.recoveryTarget != nil || request.semanticTarget != nil {
                                guard let bound = current, Date().timeIntervalSince(bound.snapshot.capturedAt) >= 0,
                                      Date().timeIntervalSince(bound.snapshot.capturedAt) < (request.recoveryTarget != nil ? 8 : 10) else { throw CompanionFailure.staleCapture }
                            }
                            // Consume the old image before executing any mutation, including failed execution.
                            current = nil
                            try dispatchGuard(request)
                            if request.operation == .tap { element.tap() }
                            else if request.operation == .type {
                                guard [.textField, .secureTextField, .textView].contains(element.elementType) else { throw CompanionFailure.unavailableTarget }
                                element.tap(); try systemInputGuard(); try dispatchGuard(request); element.typeText(request.text!)
                            } else {
                                switch request.direction! {
                                case "up": element.swipeUp(velocity: .slow)
                                case "down": element.swipeDown(velocity: .slow)
                                case "left": element.swipeLeft(velocity: .slow)
                                default: element.swipeRight(velocity: .slow)
                                }
                            }
                        case .wait:
                            current = nil
                            let until = min(Date().addingTimeInterval(request.timeout!), Date(timeIntervalSince1970: request.deadline))
                            var satisfied = false
                            repeat {
                                let matches = Self.leaves(app, identifier: request.identifier!)
                                if matches.count > 1 { throw CompanionFailure.ambiguousTarget }
                                satisfied = request.disappear == true ? matches.isEmpty : matches.count == 1
                                if satisfied { break }
                                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                            } while Date() < until
                            guard satisfied else { throw CompanionFailure.timeout }
                        case .pointTap:
                            requestStage = "bound-point"
                            guard let bound = current, bound.snapshot.captureID == request.captureID,
                                  Date().timeIntervalSince(bound.snapshot.capturedAt) >= 0,
                                  Date().timeIntervalSince(bound.snapshot.capturedAt) < 10 else { throw CompanionFailure.staleCapture }
                            let point = try bound.screenPoint(for: request.point!)
                            guard app.frame == CGRect(x: bound.screenFrame.x, y: bound.screenFrame.y, width: bound.screenFrame.width, height: bound.screenFrame.height) else { throw CompanionFailure.staleCapture }
                            try systemInputGuard()
                            if let target = request.semanticTarget {
                                requestStage = "bound-snapshot"
                                guard Self.snapshotMatchCount(bound.snapshot, target: target,
                                      bundleID: request.bundleID) == 1 else { throw CompanionFailure.ambiguousTarget }
                                // Controlled fixture race: move the view after capture but before
                                // resolving the live element, exercising the dispatch-time guard.
                                if launchedArguments == ["--targeting-probe", "moving"] {
                                    let move = app.buttons["targeting.move"]
                                    guard move.exists else { throw CompanionFailure.unavailableTarget }
                                    move.tap()
                                }
                                requestStage = "live-target"
                                let live = Self.semanticLeaves(app, target: target)
                                guard live.count == 1, live[0].isEnabled,
                                      live[0].frame.contains(CGPoint(x: point.x, y: point.y)) else {
                                    throw CompanionFailure.unavailableTarget
                                }
                            }
                            guard Date().timeIntervalSince(bound.snapshot.capturedAt) >= 0,
                                  Date().timeIntervalSince(bound.snapshot.capturedAt) < 10 else { throw CompanionFailure.staleCapture }
                            current = nil
                            requestStage = "point-dispatch"
                            try dispatchGuard(request)
                            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
                        case .pointTypeSecret:
                            func markSecretStage(_ stage: String) {
                                try? Data(stage.utf8).write(to: root.appendingPathComponent("secret-stage-" + request.requestID.uuidString), options: .atomic)
                            }
                            markSecretStage("validating capture")
                            guard let bound = current, bound.snapshot.captureID == request.captureID,
                                  Date().timeIntervalSince(bound.snapshot.capturedAt) >= 0,
                                  Date().timeIntervalSince(bound.snapshot.capturedAt) < 10,
                                  let envelope = request.encryptedSecret else { throw CompanionFailure.staleCapture }
                            let point = try bound.screenPoint(for: request.point!)
                            guard app.frame == CGRect(x: bound.screenFrame.x, y: bound.screenFrame.y,
                                width: bound.screenFrame.width, height: bound.screenFrame.height) else {
                                throw CompanionFailure.staleCapture
                            }
                            try systemInputGuard()
                            markSecretStage("system guard passed")
                            // AuthKit owns this sheet. Its secure-field query and
                            // typeText call can stall after focus appears, leaving
                            // the password empty until the command deadline. Use
                            // the fresh OCR point and one explicit Paste gesture.
                            let authKit = XCUIApplication(bundleIdentifier: "com.apple.AuthKitUIService")
                            let plaintext = try SecureInputCrypto.open(envelope,
                                for: bound.snapshot.captureID, recipientPrivateKey: inputKey)
                            guard let secret = String(data: plaintext, encoding: .utf8), !secret.isEmpty else {
                                throw CompanionFailure.invalidRequest
                            }
                            current = nil
                            try dispatchGuard(request)
                            let coordinate = app.coordinate(withNormalizedOffset: .zero)
                                .withOffset(CGVector(dx: point.x, dy: point.y))
                            markSecretStage("focusing field")
                            coordinate.tap()
                            markSecretStage("field focused")
                            let pasteboard = UIPasteboard.general
                            let previousItems = pasteboard.items
                            defer {
                                if pasteboard.string == secret { pasteboard.items = previousItems }
                            }
                            pasteboard.setItems([["public.utf8-plain-text": secret]], options: [
                                .localOnly: true,
                                .expirationDate: Date().addingTimeInterval(60)
                            ])
                            // Give AuthKit a moment to observe the new local pasteboard
                            // before asking its edit menu for Paste.
                            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                            try dispatchGuard(request)
                            markSecretStage("opening edit menu")
                            coordinate.press(forDuration: 1)
                            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                            try dispatchGuard(request)
                            markSecretStage("querying paste control")
                            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                            let pasteItems = [authKit.menuItems["Paste"], springboard.menuItems["Paste"],
                                authKit.buttons["Paste"], springboard.buttons["Paste"]].filter {
                                    $0.exists && $0.isHittable
                                }
                            guard let paste = pasteItems.first else { throw CompanionFailure.unavailableTarget }
                            markSecretStage("tapping paste")
                            paste.tap()
                            markSecretStage("paste dispatched")
                        default: throw CompanionFailure.invalidRequest
                        }
                    }
                    try dispatchGuard(request)
                } catch let error as CompanionFailure {
                    if error == .invalidRequest {
                        print("Companion rejected \(request.operation.rawValue) at \(requestStage): visualBound=\(request.semanticTarget != nil), point=\(request.point != nil)")
                    }
                    failure = error
                }
                catch {
                    print("Companion unexpected \(request.operation.rawValue) at \(requestStage): \(error)")
                    // Query failures before the point event have no input side effect.
                    // Let the runner recapture once the accessibility tree settles.
                    failure = request.operation == .pointTap &&
                        ["bound-point", "bound-snapshot", "live-target"].contains(requestStage)
                        ? .unavailableTarget : .invalidRequest
                }
                // A timed-out read has no input side effect; the session stays serviceable.
                let readTimeout = failure == .timeout && [.snapshot, .wait].contains(request.operation)
                if request.sessionID == session.sessionID && !readTimeout && (failure == .timeout || failure == .lostSession || failure == .appCrashed) {
                    stop = true
                    try? Data("stop".utf8).write(to: root.appendingPathComponent("poison-" + session.sessionID.uuidString), options: .atomic)
                }
                let response = CompanionResponse(request: request, elapsedSeconds: Date().timeIntervalSince(start), failure: failure, capture: capture)
                try JSONEncoder().encode(response).write(to: responses.appendingPathComponent(request.requestID.uuidString + ".json"), options: .atomic)
                if stop { break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
    @MainActor static func leaves(_ app: XCUIApplication, identifier: String) -> [XCUIElement] {
        // Identifiers are code: case/whitespace tolerant, never substring.
        // Keep leaf-only semantics: drop wrappers that contain a matching descendant.
        // The exact query is pushed into the accessibility query so dense screens
        // resolve only their matches; tolerance falls back to a full enumeration.
        let wanted = norm(identifier)
        let query = app.descendants(matching: .any)
        let exact = query.matching(identifier: identifier).allElementsBoundByIndex.filter { $0.exists }
        let candidates = exact.isEmpty ? query.allElementsBoundByIndex.filter { $0.exists } : exact
        let matching = candidates.filter { norm($0.identifier) == wanted }
        return matching.filter { candidate in
            !candidate.descendants(matching: .any).allElementsBoundByIndex.contains {
                $0.exists && norm($0.identifier) == wanted
            }
        }
    }
    @MainActor static func semanticLeaves(_ app: XCUIApplication, target: CompanionSemanticTarget) -> [XCUIElement] {
        func exactMatches(_ element: XCUIElement) -> Bool {
            // XCTest snapshots can omit a value that the live element exposes.
            // Absence is an unknown constraint, not evidence that live value is nil.
            norm(role(element.elementType)) == norm(target.role) && fieldEq(element.label, target.label) &&
                (target.value == nil || fieldEq(element.value as? String, target.value)) &&
                sameFrame(element.frame, target.frame)
        }
        func vagueMatches(_ element: XCUIElement) -> Bool {
            norm(role(element.elementType)) == norm(target.role) && fieldContains(element.label, target.label) &&
                (target.value == nil || fieldContains(element.value as? String, target.value)) &&
                sameFrame(element.frame, target.frame)
        }
        if norm(target.role) == "application" { return exactMatches(app) ? [app] : [] }
        // Scope the live query to the target's element type so a web view's
        // hundreds of wrappers are never enumerated during an action.
        let all = app.descendants(matching: elementType(target.role)).allElementsBoundByIndex.filter { $0.exists }
        let exact = all.filter { element in
            exactMatches(element) && !element.descendants(matching: .any).allElementsBoundByIndex.contains(where: exactMatches)
        }
        if !exact.isEmpty { return exact }
        // Vague fallback so `apple` finds `Sign in with Apple`; uniqueness still enforced.
        return all.filter { element in
            vagueMatches(element) && !element.descendants(matching: .any).allElementsBoundByIndex.contains(where: vagueMatches)
        }
    }
    static func elementType(_ role: String) -> XCUIElement.ElementType {
        switch norm(role) {
        case "button": return .button
        case "textfield": return .textField
        case "securetextfield": return .secureTextField
        case "textview": return .textView
        case "statictext": return .staticText
        case "alert": return .alert
        case "application": return .application
        case "keyboard": return .keyboard
        case "sheet": return .sheet
        case "activityindicator": return .activityIndicator
        case "progressindicator": return .progressIndicator
        case "scrollview": return .scrollView
        default: return .any
        }
    }
    static func snapshotDescendants(_ node: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        var result: [XCUIElementSnapshot] = []
        func visit(_ n: XCUIElementSnapshot) {
            for child in n.children { result.append(child); visit(child) }
        }
        visit(node)
        return result
    }
    static func snapshotLeaves(_ root: XCUIElementSnapshot, identifier: String) -> [XCUIElementSnapshot] {
        let wanted = norm(identifier)
        let all = snapshotDescendants(root).filter { !$0.identifier.isEmpty && norm($0.identifier) == wanted }
        return all.filter { candidate in
            !snapshotDescendants(candidate).contains { !$0.identifier.isEmpty && norm($0.identifier) == wanted }
        }
    }
    static func snapshotIdentifierLeaves(_ root: XCUIElementSnapshot) -> [String: [XCUIElementSnapshot]] {
        let grouped = Dictionary(grouping: snapshotDescendants(root).filter { !$0.identifier.isEmpty }) {
            norm($0.identifier)
        }
        return grouped.mapValues { nodes in
            nodes.filter { candidate in
                !snapshotDescendants(candidate).contains { descendant in
                    !descendant.identifier.isEmpty && norm(descendant.identifier) == norm(candidate.identifier)
                }
            }
        }
    }
    static func snapshotSemanticLeaves(_ root: XCUIElementSnapshot, target: CompanionSemanticTarget) -> [XCUIElementSnapshot] {
        func exactMatches(_ node: XCUIElementSnapshot) -> Bool {
            norm(role(node.elementType)) == norm(target.role) && fieldEq(node.label, target.label) &&
                (target.value == nil || fieldEq(node.value as? String, target.value)) &&
                sameFrame(node.frame, target.frame)
        }
        func vagueMatches(_ node: XCUIElementSnapshot) -> Bool {
            norm(role(node.elementType)) == norm(target.role) && fieldContains(node.label, target.label) &&
                (target.value == nil || fieldContains(node.value as? String, target.value)) &&
                sameFrame(node.frame, target.frame)
        }
        if norm(target.role) == "application" { return exactMatches(root) ? [root] : [] }
        let all = snapshotDescendants(root)
        let exact = all.filter { exactMatches($0) && !snapshotDescendants($0).contains(where: exactMatches) }
        if !exact.isEmpty { return exact }
        return all.filter { vagueMatches($0) && !snapshotDescendants($0).contains(where: vagueMatches) }
    }
    static func snapshotHittable(_ node: XCUIElementSnapshot, appFrame: CGRect) -> Bool {
        node.isEnabled && node.frame.width > 0 && node.frame.height > 0 && node.frame.intersects(appFrame)
    }
    static func sameFrame(_ frame: CGRect, _ target: CGRectValue?) -> Bool {
        guard let target else { return true }
        guard frame.width > 0, frame.height > 0 else { return false }
        return abs(frame.midX - (target.x + target.width / 2)) <= 12 &&
            abs(frame.midY - (target.y + target.height / 2)) <= 12 &&
            abs(frame.width - target.width) <= 24 && abs(frame.height - target.height) <= 24
    }
    static func sameFrame(_ frame: CGRectValue?, _ target: CGRectValue?) -> Bool {
        guard let target else { return true }
        guard let frame else { return false }
        return abs(frame.x + frame.width / 2 - (target.x + target.width / 2)) <= 12 &&
            abs(frame.y + frame.height / 2 - (target.y + target.height / 2)) <= 12 &&
            abs(frame.width - target.width) <= 24 && abs(frame.height - target.height) <= 24
    }
    // MARK: - Tolerant text (mirrors RunnerCore.TargetTextMatching)
    static func norm(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func fieldEq(_ element: String?, _ target: String?) -> Bool {
        guard let target else { return true }
        guard let element else { return false }
        return norm(element) == norm(target)
    }
    static func fieldContains(_ element: String?, _ target: String?) -> Bool {
        guard let target else { return true }
        guard let element else { return false }
        let nTarget = norm(target), nElement = norm(element)
        if nTarget.count >= 2, nElement.contains(nTarget) { return true }
        if nElement.count >= 2, nTarget.count > nElement.count, nTarget.contains(nElement) { return true }
        return nElement == nTarget
    }
    /// Mirrors RunnerCore matching tiers: exact first, vague substring fallback.
    static func snapshotMatchCount(_ snapshot: UISnapshot, target: CompanionSemanticTarget, bundleID: String) -> Int {
        let scoped = snapshot.elements.filter { $0.originBundleIdentifier == nil || $0.originBundleIdentifier == bundleID }
        let exact = scoped.filter {
            norm($0.role) == norm(target.role) && fieldEq($0.label, target.label) && fieldEq($0.value, target.value) &&
                sameFrame($0.frame, target.frame)
        }
        if !exact.isEmpty { return exact.count }
        return scoped.filter {
            norm($0.role) == norm(target.role) && fieldContains($0.label, target.label) && fieldContains($0.value, target.value) &&
                sameFrame($0.frame, target.frame)
        }.count
    }
    @MainActor static func resolve(_ app: XCUIApplication, identifier: String, actionable: Bool) throws -> XCUIElement {
        let matches = leaves(app, identifier: identifier)
        guard !matches.isEmpty else { throw CompanionFailure.absentTarget }
        guard matches.count == 1 else { throw CompanionFailure.ambiguousTarget }
        guard !actionable || (matches[0].isEnabled && matches[0].isHittable) else { throw CompanionFailure.unavailableTarget }
        return matches[0]
    }
    /// XCTest blocks every synthesized event until the target app idles. Web
    /// views, spinners and perpetual animations never idle, so taps hang until
    /// the caller's deadline expires. XCTest's own interaction options can skip
    /// both quiescence checks; the selector is guarded so a future Xcode that
    /// removes it falls back to default waiting instead of crashing.
    @MainActor static func skipEventQuiescence(_ app: XCUIApplication) {
        let selector = NSSelectorFromString("setCurrentInteractionOptions:")
        guard app.responds(to: selector), let method = app.method(for: selector) else { return }
        typealias SetOptions = @convention(c) (AnyObject, Selector, UInt32) -> Void
        unsafeBitCast(method, to: SetOptions.self)(app, selector, 3)
    }
    static func systemPromptChoice(_ snapshot: UISnapshot) -> UIElement? {
        let nodes = snapshot.elements.filter { $0.originBundleIdentifier == "com.apple.springboard" &&
            ($0.role == "alert" || $0.containingAlertContext != nil) }
        guard !nodes.isEmpty, Set(nodes.compactMap(\.containingAlertIdentifier)).count == 1,
              Set(nodes.compactMap(\.containingAlertContext)).count == 1 else { return nil }
        let context = norm(nodes.compactMap(\.containingAlertContext).first ?? "")
        let accountPrompt = context.contains("sign in to your apple account") ||
            (context.contains("apple account verification") && context.contains("enter the password for") && context.contains("in settings"))
        let ranked = nodes.compactMap { node -> (UIElement, Int)? in
            guard node.role == "button", node.isEnabled == true, node.isHittable == true,
                  node.buttonRole != "destructive", let label = node.label else { return nil }
            let rank: Int?
            if accountPrompt {
                rank = ["close", "not now"].contains(norm(label)) ? 1 : nil
            } else {
                switch norm(label) {
                case "always allow", "allow always", "allow full access": rank = 10
                case "allow while using app", "allow while using the app": rank = 9
                case "allow once": rank = 8
                case "allow", "allow access", "allow all", "allow notifications": rank = 7
                case "ok", "okay", "continue", "enable", "turn on", "accept", "agree", "yes", "confirm": rank = 6
                default:
                    let name = norm(label)
                    let excluded = ["don't allow", "don’t allow", "deny", "cancel", "not now", "later", "close", "no", "settings", "open settings", "learn more", "more info"]
                    let destructive = ["delete", "erase", "buy", "purchase", "pay"]
                    if excluded.contains(name) || destructive.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) {
                        rank = nil
                    } else if name.hasPrefix("allow ") {
                        rank = 7
                    } else if name.hasPrefix("enable ") || name.hasPrefix("accept ") || name.hasPrefix("continue ") {
                        rank = 6
                    } else {
                        rank = 1
                    }
                }
            }
            return rank.map { (node, $0) }
        }
        guard let highest = ranked.map(\.1).max() else { return nil }
        let best = ranked.filter { $0.1 == highest }
        return best.count == 1 ? best[0].0 : nil
    }
    static func alertContext(_ node: XCUIElementSnapshot) -> String {
        func labels(_ n: XCUIElementSnapshot) -> [String] {
            if n.elementType == .button || n.elementType == .staticText { return [n.label] }
            return n.children.flatMap { labels($0) }
        }
        return ([node.label] + labels(node).filter { !$0.isEmpty && $0 != node.label }).joined(separator: "\n")
    }
    static func role(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "button"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .textView: return "textView"
        case .staticText: return "staticText"
        case .alert: return "alert"
        case .application: return "application"
        case .keyboard: return "keyboard"
        case .sheet: return "sheet"
        case .activityIndicator: return "activityIndicator"
        case .progressIndicator: return "progressIndicator"
        case .scrollView: return "scrollView"
        default: return "other"
        }
    }
}
