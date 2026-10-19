import Foundation
import RunnerCore
import SimulatorControl
#if os(macOS)
import Vision
#endif

@main struct CompanionExperiment {
    static func main() async {
        do { try await run() }
        catch { fputs("companion-experiment: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        #if os(macOS)
        let arguments = Array(CommandLine.arguments.dropFirst())
        func argument(_ flag: String) throws -> String {
            guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else {
                throw NSError(domain: "Trial", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"])
            }
            return arguments[i + 1]
        }
        let mailbox = URL(fileURLWithPath: try argument("--mailbox"), isDirectory: true)
        let output = URL(fileURLWithPath: try argument("--artifacts"), isDirectory: true)
        let bundleID = try argument("--bundle-id")
        let count = Int(try argument("--runs")) ?? 0
        let negativeProbes = arguments.contains("--negative-probes")
        guard (1...10).contains(count) else { throw CompanionFailure.invalidRequest }
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let screenshots = output.appendingPathComponent("screenshots")
        try fm.createDirectory(at: screenshots, withIntermediateDirectories: true)
        let eventsURL = output.appendingPathComponent("events.jsonl")
        guard !fm.fileExists(atPath: eventsURL.path) else { throw CompanionFailure.invalidRequest }
        fm.createFile(atPath: eventsURL.path, contents: nil)
        let events = try FileHandle(forWritingTo: eventsURL)
        defer { try? events.close() }
        var sequence = 0
        func log(_ event: [String: Any]) throws {
            sequence += 1
            var data = event
            data["sequence"] = sequence
            data["timestamp"] = Date().timeIntervalSince1970
            var bytes = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
            bytes.append(10)
            try events.write(contentsOf: bytes)
            try events.synchronize()
        }
        let bridge = CompanionBridge(directory: mailbox, bundleID: bundleID)
        let connectionStart = Date()
        try await bridge.connect()
        try log(["kind": "connected", "connectionSeconds": Date().timeIntervalSince(connectionStart)])
        var recording: (any VideoRecordingSession)?
        if arguments.contains("--udid") {
            recording = try MacSimulatorController().startVideoRecording(to: output.appendingPathComponent("video.mp4"), udid: argument("--udid"))
        }
        defer { try? recording?.stop() }
        var passed = 0
        var screenshotCount = 0
        var probeResults: [String] = []
        func request(_ operation: CompanionOperation, trial: Int, configure: @Sendable (inout CompanionRequest) -> Void = { _ in }) async throws -> CompanionResponse {
            let start = Date()
            do {
                let response = try await bridge.request(operation, configure: configure)
                try log(["kind": "operation", "trial": trial, "operation": operation.rawValue,
                    "requestID": response.requestID.uuidString, "sessionID": response.sessionID.uuidString,
                    "clientSeconds": Date().timeIntervalSince(start), "serviceSeconds": response.elapsedSeconds])
                return response
            } catch {
                try log(["kind": "operationFailure", "trial": trial, "operation": operation.rawValue, "error": String(describing: error)])
                throw error
            }
        }
        func capture(_ label: String, trial: Int) async throws -> CompanionCapture {
            let id = CaptureID()
            let response = try await request(.snapshot, trial: trial) { $0.captureID = id }
            guard let capture = response.capture, capture.snapshot.captureID == id,
                  capture.screenshotName == id.description + ".png", capture.pixelWidth > 0, capture.pixelHeight > 0 else {
                throw CompanionFailure.invalidRequest
            }
            _ = try capture.screenPoint(for: PixelPoint(x: 0, y: 0))
            let destination = screenshots.appendingPathComponent(String(format: "%02d-%@-%@.png", trial, label, id.description))
            try fm.copyItem(at: mailbox.appendingPathComponent(capture.screenshotName), to: destination)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(capture).write(to: destination.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            screenshotCount += 1
            try log(["kind": "capture", "trial": trial, "state": label, "captureID": id.description, "screenshot": destination.lastPathComponent])
            return capture
        }
        func unique(_ snapshot: UISnapshot, _ identifier: String) throws -> UIElement {
            let found = snapshot.elements.filter { $0.identifier == identifier }
            guard found.count == 1 else { throw found.isEmpty ? CompanionFailure.absentTarget : CompanionFailure.ambiguousTarget }
            return found[0]
        }
        do {
            for trial in 1...count {
                let start = Date()
                let name = "Ada \(trial)"
                _ = try await request(.launch, trial: trial) { $0.launchArguments = ["--bridge-probes"] }
                let initial = try await capture("launch", trial: trial)
                _ = try unique(initial.snapshot, "onboarding.name")
                if negativeProbes {
                    let session = try JSONDecoder().decode(CompanionSession.self,
                        from: Data(contentsOf: mailbox.appendingPathComponent("session.json")))
                    let unknownID = UUID()
                    let unknown: [String: Any] = ["version": 1, "requestID": unknownID.uuidString,
                        "sessionID": session.sessionID.uuidString, "operation": "unsupported-probe",
                        "bundleID": bundleID, "deadline": Date().timeIntervalSince1970 + 3]
                    try JSONSerialization.data(withJSONObject: unknown).write(
                        to: mailbox.appendingPathComponent("requests/" + unknownID.uuidString + ".json"), options: .atomic)
                    let rejectionPath = mailbox.appendingPathComponent("responses/" + unknownID.uuidString + ".json")
                    let rejectionDeadline = Date().addingTimeInterval(3)
                    while !fm.fileExists(atPath: rejectionPath.path), Date() < rejectionDeadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    let rejection = try JSONDecoder().decode(CompanionResponse.self, from: Data(contentsOf: rejectionPath))
                    guard rejection.requestID == unknownID, rejection.sessionID == session.sessionID,
                          rejection.failure == .invalidRequest else { throw CompanionFailure.invalidRequest }
                    probeResults.append("unknownOperationRejected")
                    try log(["kind": "expectedRejection", "operation": "unsupported-probe", "failure": "invalidRequest"])
                    for (identifier, expected) in [("fixture.ambiguous", CompanionFailure.ambiguousTarget),
                                                   ("onboarding.continue", .unavailableTarget),
                                                   ("fixture.missing", .absentTarget)] {
                        do {
                            _ = try await request(.tap, trial: trial) { $0.identifier = identifier }
                            throw CompanionFailure.invalidRequest
                        } catch let failure as CompanionFailure where failure == expected {
                            probeResults.append(expected.rawValue)
                            try log(["kind": "expectedRejection", "target": identifier, "failure": expected.rawValue])
                        }
                    }
                    _ = try await request(.wait, trial: trial) { $0.identifier = "onboarding.name"; $0.timeout = 1 }
                    _ = try await request(.wait, trial: trial) { $0.identifier = "fixture.missing"; $0.timeout = 1; $0.disappear = true }
                    probeResults += ["waitExists", "waitDisappearance"]
                }
                _ = try await request(.tap, trial: trial) { $0.identifier = "onboarding.name" }
                _ = try await capture("focused", trial: trial)
                _ = try await request(.type, trial: trial) { $0.identifier = "onboarding.name"; $0.text = name }
                let typed = try await capture("typed", trial: trial)
                guard try unique(typed.snapshot, "onboarding.name").value == name else { throw CompanionFailure.invalidRequest }
                _ = try await request(.tap, trial: trial) { $0.identifier = "onboarding.continue" }
                let alert = try await capture("alert", trial: trial)
                let button = try unique(alert.snapshot, "fixture.alert.notNow")
                guard button.label == "Not Now", button.role == "button", button.isEnabled == true,
                      button.isHittable == true, button.containingAlertContext?.contains("Try reminders?") == true else {
                    throw CompanionFailure.unavailableTarget
                }
                let gate = CaptureActionGate()
                try await gate.activate(alert.snapshot.captureID)
                let dismiss = ActionCandidate(captureID: alert.snapshot.captureID, title: "Dismiss known optional reminder",
                    action: .tapAccessibilityIdentifier("fixture.alert.notNow"), isSafeForAutomaticExecution: true)
                _ = try await gate.validateAndConsume(choice: .init(candidateID: dismiss.id, captureID: dismiss.captureID, confidence: 1), candidates: [dismiss], minimumConfidence: 0.8)
                _ = try await request(.tap, trial: trial) { $0.identifier = "fixture.alert.notNow" }
                var source = try await capture("ocr-source", trial: trial)
                guard !source.snapshot.elements.contains(where: { $0.label == "Finish setup" }) else { throw CompanionFailure.invalidRequest }
                do {
                    _ = try await request(.pointTap, trial: trial) { $0.captureID = alert.snapshot.captureID; $0.point = PixelPoint(x: 0, y: 0) }
                    throw CompanionFailure.invalidRequest
                } catch CompanionFailure.staleCapture {
                    try log(["kind": "staleCaptureRejected", "trial": trial])
                }
                var point: PixelPoint?
                var confidence = 0.0
                for attempt in 0..<2 {
                    let ocr = VNRecognizeTextRequest(); ocr.recognitionLevel = .accurate; ocr.recognitionLanguages = ["en-US"]
                    let ocrStart = Date()
                    try VNImageRequestHandler(url: mailbox.appendingPathComponent(source.screenshotName)).perform([ocr])
                    let elapsed = Date().timeIntervalSince(ocrStart)
                    let hits = (ocr.results ?? []).filter { $0.topCandidates(1).first?.string == "Finish setup" }
                    guard hits.count == 1, let hit = hits.first, let text = hit.topCandidates(1).first else { throw CompanionFailure.absentTarget }
                    try log(["kind": "ocr", "trial": trial, "attempt": attempt, "seconds": elapsed, "captureID": source.snapshot.captureID.description, "confidence": text.confidence])
                    if Date().timeIntervalSince(source.snapshot.capturedAt) >= 8, attempt == 0 {
                        source = try await capture("ocr-refreshed", trial: trial)
                        continue
                    }
                    point = PixelPoint(x: hit.boundingBox.midX * Double(source.pixelWidth), y: (1 - hit.boundingBox.midY) * Double(source.pixelHeight))
                    confidence = Double(text.confidence)
                    break
                }
                guard let point else { throw CompanionFailure.timeout }
                let transformed = try source.screenPoint(for: point)
                try await gate.activate(source.snapshot.captureID)
                let candidate = ActionCandidate(captureID: source.snapshot.captureID, title: "Finish setup", action: .tapPoint(point), isSafeForAutomaticExecution: true)
                _ = try await gate.validateAndConsume(choice: .init(candidateID: candidate.id, captureID: candidate.captureID, confidence: confidence), candidates: [candidate], minimumConfidence: 0.8)
                try log(["kind": "pointDecision", "trial": trial, "captureID": source.snapshot.captureID.description, "pixelPoint": [point.x, point.y], "screenPoint": [transformed.x, transformed.y]])
                let bound = source.snapshot.captureID
                _ = try await request(.pointTap, trial: trial) { $0.captureID = bound; $0.point = point }
                let final = try await capture("complete", trial: trial)
                guard try unique(final.snapshot, "onboarding.complete").label == "Setup complete",
                      try unique(final.snapshot, "onboarding.finalName").label == "Welcome, \(name)" else { throw CompanionFailure.invalidRequest }
                passed += 1
                try log(["kind": "trialPassed", "trial": trial, "seconds": Date().timeIntervalSince(start), "name": name])
            }
            if negativeProbes {
                _ = try await request(.launch, trial: count + 1) { $0.launchArguments = ["--scroll-probe"] }
                let before = try await capture("scroll-before", trial: count + 1)
                let firstBefore = try unique(before.snapshot, "fixture.scroll.first")
                var progressed = false
                for swipe in 1...4 {
                    _ = try await request(.swipe, trial: count + 1) { $0.identifier = "fixture.scroll"; $0.direction = "up" }
                    let after = try await capture("scroll-after-\(swipe)", trial: count + 1)
                    let first = after.snapshot.elements.first { $0.identifier == "fixture.scroll.first" }
                    let target = after.snapshot.elements.first { $0.identifier == "fixture.scroll.target" }
                    progressed = target?.isHittable == true || first == nil ||
                        ((first?.frame?.y ?? .infinity) < (firstBefore.frame?.y ?? -.infinity) - 20)
                    if progressed { break }
                }
                guard progressed else { throw CompanionFailure.invalidRequest }
                probeResults.append("swipeChangedContent")
                let timeoutStart = Date()
                do {
                    _ = try await request(.wait, trial: count + 1) {
                        $0.identifier = "fixture.missing"; $0.timeout = 10
                        $0.deadline = Date().timeIntervalSince1970 + 0.3
                    }
                    throw CompanionFailure.invalidRequest
                } catch CompanionFailure.timeout {
                    probeResults.append("boundedTimeout")
                    try log(["kind": "expectedTimeout", "seconds": Date().timeIntervalSince(timeoutStart)])
                }
                do {
                    _ = try await bridge.request(.launch)
                    throw CompanionFailure.invalidRequest
                } catch CompanionFailure.lostSession { probeResults.append("poisonedSessionRejectsNextAction") }
            } else {
                try await bridge.shutdown()
            }
            try recording?.stop()
            let summary: [String: Any] = ["requestedRuns": count, "passedRuns": passed, "failedRuns": 0,
                "screenshots": screenshotCount, "negativeProbes": probeResults,
                "stateKinds": ["launch", "focused", "typed", "alert", "ocr-source", "complete"],
                "scope": "Repeated controlled onboarding; six UI state kinds with varying entered names. Not broad app coverage."]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("summary.json"), options: .atomic)
            print("Passed \(passed)/\(count) bridge trials; saved \(screenshotCount) captures at \(output.path)")
        } catch {
            try? log(["kind": "experimentFailed", "passedRuns": passed, "error": String(describing: error)])
            try? await bridge.shutdown()
            throw error
        }
        #else
        throw CompanionFailure.invalidRequest
        #endif
    }
}
