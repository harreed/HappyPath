import XCTest
import Vision

final class FixtureUITests: XCTestCase {
    @MainActor func testOnboarding() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        var sequence = 0
        @discardableResult func capture(_ action: String, screenshot supplied: XCUIScreenshot? = nil, details: [String: Any] = [:]) -> CaptureID {
            let captureID = CaptureID()
            sequence += 1
            let screenshot = XCTAttachment(screenshot: supplied ?? XCUIScreen.main.screenshot())
            screenshot.name = String(format: "%02d-%@-%@", sequence, captureID.description, action)
            screenshot.lifetime = .keepAlways
            add(screenshot)
            var event: [String: Any] = ["sequence": sequence, "action": action,
                "timestamp": Date().timeIntervalSince1970, "captureID": captureID.description, "hierarchy": app.debugDescription]
            event.merge(details) { _, new in new }
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: event), uniformTypeIdentifier: "public.json")
            attachment.name = String(format: "%02d-event.json", sequence)
            attachment.lifetime = .keepAlways
            add(attachment)
            return captureID
        }
        XCTAssertTrue(app.textFields["onboarding.name"].waitForExistence(timeout: 10))
        capture("launch")
        app.textFields["onboarding.name"].tap()
        app.textFields["onboarding.name"].typeText("Ada")
        XCTAssertEqual(app.textFields["onboarding.name"].value as? String, "Ada")
        capture("semantic-type")
        app.buttons["onboarding.continue"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let alertCapture = capture("unexpected-alert")
        XCTAssertTrue(alert.staticTexts["Try reminders?"].exists)
        // SwiftUI can expose both a wrapper and its nested button with the same
        // identifier. Resolve by index, discard wrappers, and reject ambiguous leaves.
        let matchingButtons = alert.descendants(matching: .button)
            .matching(identifier: "fixture.alert.notNow").allElementsBoundByIndex
        let candidates = matchingButtons.filter { element in
            guard element.exists, element.label == "Not Now", element.isEnabled,
                  element.isHittable else { return false }
            return element.descendants(matching: .button)
                .matching(identifier: "fixture.alert.notNow").count == 0
        }
        XCTAssertEqual(candidates.count, 1, "Expected exactly one safe hittable alert leaf")
        let gate = CaptureActionGate()
        try await gate.activate(alertCapture)
        let safeCandidate = ActionCandidate(captureID: alertCapture, title: "Not Now",
            action: .tapAccessibilityIdentifier("fixture.alert.notNow"), isSafeForAutomaticExecution: true)
        _ = try await gate.validateAndConsume(choice: CandidateChoice(candidateID: safeCandidate.id,
            captureID: alertCapture, confidence: 1), candidates: [safeCandidate], minimumConfidence: 0.8)
        try XCTUnwrap(candidates.first).tap()
        XCTAssertTrue(app.staticTexts["onboarding.greeting"].waitForExistence(timeout: 5))
        capture("safe-alert-dismissal")
        XCTAssertFalse(app.buttons["Finish setup"].exists)
        XCTAssertFalse(app.staticTexts["Finish setup"].exists)
        let screenshot = XCUIScreen.main.screenshot()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(data: screenshot.pngRepresentation).perform([request])
        let hits = (request.results ?? []).filter { $0.topCandidates(1).first?.string == "Finish setup" }
        XCTAssertEqual(hits.count, 1)
        let box = try XCTUnwrap(hits.first).boundingBox
        // Vision uses normalized bottom-left coordinates; XCTest uses top-left screen points.
        let cgImage = try XCTUnwrap(screenshot.image.cgImage)
        XCTAssertEqual(app.frame.origin, .zero, "Fixture requires a full-screen app")
        XCTAssertLessThan(app.frame.width, app.frame.height, "Fixture requires portrait orientation")
        XCTAssertEqual(Double(cgImage.width) / app.frame.width,
                       Double(cgImage.height) / app.frame.height, accuracy: 0.01)
        let ocrCapture = capture("ocr-source", screenshot: screenshot, details: [
            "pixelWidth": cgImage.width, "pixelHeight": cgImage.height,
            "appFramePoints": [app.frame.minX, app.frame.minY, app.frame.width, app.frame.height],
            "screenPointOrigin": "top-left", "visionOrigin": "bottom-left",
            "pixelToPointScale": app.frame.width / Double(cgImage.width),
            "normalizedBoundingBox": [box.minX, box.minY, box.width, box.height],
            "tapScreenPoints": [box.midX * app.frame.width, (1 - box.midY) * app.frame.height],
            "confidence": hits.first!.topCandidates(1).first!.confidence])
        try await gate.activate(ocrCapture)
        do {
            _ = try await gate.validateAndConsume(choice: CandidateChoice(candidateID: safeCandidate.id,
                captureID: alertCapture, confidence: 1), candidates: [safeCandidate], minimumConfidence: 0.8)
            XCTFail("Old capture was accepted")
        } catch CaptureActionGateError.staleCapture { }
        let candidate = ActionCandidate(captureID: ocrCapture, title: "Finish setup",
            action: .tapPoint(PixelPoint(x: box.midX * Double(cgImage.width),
                y: (1 - box.midY) * Double(cgImage.height))), isSafeForAutomaticExecution: true)
        _ = try await gate.validateAndConsume(choice: CandidateChoice(candidateID: candidate.id,
            captureID: ocrCapture, confidence: Double(hits.first!.topCandidates(1).first!.confidence)),
            candidates: [candidate], minimumConfidence: 0.8)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: box.midX * app.frame.width, dy: (1 - box.midY) * app.frame.height)).tap()
        XCTAssertTrue(app.staticTexts["onboarding.complete"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["onboarding.finalName"].label, "Welcome, Ada")
        capture("ocr-tap-final-semantic-assertion")
    }
}
