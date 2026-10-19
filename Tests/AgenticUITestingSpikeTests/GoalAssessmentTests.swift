import XCTest
import RunnerCore
import ProjectDomain
@testable import ModelProviders
import ArtifactStore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private actor GoalDriver: RunnerDriving {
    var captured: [CaptureID] = []
    var actions = 0
    var failPrepare = false
    func prepare(project: TestProject, deadline: Date) async throws { if failPrepare { throw DriverFailure.unavailable("fixture unavailable") } }
    func capture(deadline: Date) async throws -> UISnapshot { let id = CaptureID(); captured.append(id); return .init(captureID: id, elements: [.init(identifier: "done", role: "staticText", label: "Welcome Ada", value: nil, frame: nil)]) }
    func perform(_ action: DrivenAction, deadline: Date) async throws { actions += 1 }
    func stop() async {}
}
private actor VisibleCriterionDriver: RunnerDriving {
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot {
        .init(captureID: .init(), elements: [
            .init(identifier: nil, role: "application", label: "Fixture", value: nil,
                frame: .init(x: 0, y: 0, width: 400, height: 800), isEnabled: true,
                originBundleIdentifier: "dev.fixture"),
            .init(identifier: "done", role: "staticText", label: "Scenario created", value: nil,
                frame: .init(x: 40, y: 200, width: 260, height: 40), isEnabled: true,
                originBundleIdentifier: "dev.fixture")
        ])
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws { XCTFail("Completed criterion dispatched input") }
    func stop() async {}
}
private struct TestEvaluator: AssertionEvaluating {
    var providerID: String { "test.mock" }
    var verdict: AssertionAssessment.Verdict = .satisfied
    var confidence = 1.0
    var wrongID = false
    var requiresImage = false
    func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment {
        .init(requestID: wrongID ? UUID() : request.requestID, captureID: request.captureID, verdict: verdict, requiresImage: requiresImage, confidence: confidence, evidenceIDs: [request.evidence[0].id], reason: "Recorded semantic label")
    }
}
private struct OCRThenImageEvaluator: AssertionEvaluating {
    let providerID = "fixture.ocr-evaluator"
    func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment {
        if request.mode == .ocrText {
            return .init(requestID: request.requestID, captureID: request.captureID,
                verdict: .satisfied, confidence: 0.98, evidenceIDs: ["ocr-0"],
                reason: "OCR shows the completion text")
        }
        return .init(requestID: request.requestID, captureID: request.captureID,
            verdict: .insufficient, requiresImage: true, confidence: 0.9,
            evidenceIDs: request.evidence.prefix(1).map(\.id), reason: "Accessibility cannot see the text")
    }
}
private struct WrongSummary: FailureSummarising {
    func summarise(_ request: FailureSummaryRequest) async throws -> FailureSummaryEvidence { .init(source: .init(testID: UUID(), outcome: .passed, reason: "invented", assessmentRequestID: nil), provider: "invalid.mock", text: "Passed") }
}
private actor ScreenshotGoalDriver: RunnerDriving {
    private var sources: [CaptureID: CompanionCapture] = [:]
    private let image: Data
    private let ocrText: String?
    init(ocrText: String? = nil) throws {
        self.ocrText = ocrText
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        image = output as Data
    }
    func prepare(project: TestProject, deadline: Date) async throws {}
    func capture(deadline: Date) async throws -> UISnapshot {
        let snapshot = UISnapshot(captureID: .init(), elements: [
            .init(identifier: nil, role: "application", label: "Fixture", value: nil,
                frame: .init(x: 0, y: 0, width: 1, height: 1), originBundleIdentifier: "dev.fixture")])
        let t = snapshot.capturedAt
        sources[snapshot.captureID] = CompanionCapture(snapshot: snapshot,
            screenshotName: snapshot.captureID.rawValue.uuidString.lowercased() + ".png",
            pixelWidth: 1, pixelHeight: 1, screenFrame: .init(x: 0, y: 0, width: 1, height: 1),
            screenshotCompletedAt: t, semanticStartedAt: t, semanticCompletedAt: t)
        return snapshot
    }
    func provenance(for id: CaptureID) async -> CompanionCapture? { sources[id] }
    func recognizeText(for id: CaptureID, deadline: Date) async throws -> TextPerception {
        guard let capture = sources[id], let ocrText else { throw ProviderFailure.unavailable }
        let now = Date()
        return .init(captureID: id, geometry: .init(pixels: .init(width: 1, height: 1),
            screenFrame: .init(x: 0, y: 0, width: 1, height: 1)),
            screenshotStartedAt: capture.snapshot.capturedAt, recognitionStartedAt: now,
            recognitionCompletedAt: now, recognitionMilliseconds: 0,
            provider: "fixture.ocr", imageSHA256: String(repeating: "0", count: 64),
            regions: [.init(text: ocrText, confidence: 0.98,
                pixelBox: .init(x: 0, y: 0, width: 1, height: 1))])
    }
    func visualImageData(for id: CaptureID) async throws -> Data { image }
    func perform(_ action: DrivenAction, deadline: Date) async throws { XCTFail("No input expected") }
    func stop() async {}
}
private actor ScreenshotGoalAssessor: ImageAssessing {
    nonisolated let providerID = "fixture.screenshot"
    nonisolated let processingLocation: ImageProcessingLocation = .remote
    private var count = 0
    func assess(_ request: ImageAssessmentRequest) async throws -> ImageAssessment {
        count += 1
        return .init(captureID: request.capture.id, imageSHA256: request.imageSHA256,
            verdict: .satisfied, confidence: 0.95, reason: "Practice tab is highlighted",
            providerID: providerID, processingLocation: processingLocation)
    }
    func calls() -> Int { count }
}
final class GoalAssessmentTests: XCTestCase {
    private func project(_ test: ProjectDomain.TestCase) -> TestProject { .init(name: "Goal", app: .init(projectPath: "Fixture.xcodeproj", scheme: "Fixture", bundleIdentifier: "dev.fixture"), simulator: .init(deviceID: "fixture"), categories: [.init(name: "Goals", suites: [.init(name: "Goals", tests: [test])])]) }
    private func run(_ test: ProjectDomain.TestCase, evaluator: any AssertionEvaluating = TestEvaluator(), summary: any FailureSummarising = RecordedFailureSummariser()) async -> (ExecutionReport, [ExecutionEvent]) {
        let handle = ExecutionEngine(driver: GoalDriver(), assertionEvaluator: evaluator, failureSummariser: summary).start(project: project(test))
        var events: [ExecutionEvent] = []; for await event in handle.events { events.append(event) }
        return (await handle.task.value, events)
    }
    func testExactVisibleCriterionPassesFromFreshAppTextWithoutProvider() async {
        let visibleSnapshot = try! await VisibleCriterionDriver().capture(deadline: Date().addingTimeInterval(1))
        XCTAssertEqual(GoalNavigationSafety.literalVisibleSuccess("Scenario created is visible",
            snapshot: visibleSnapshot, appBundleID: "dev.fixture"), "Scenario created")
        let test = ProjectDomain.TestCase(name: "Visible", goal: "Tap Create scenario so Scenario created appears",
            successCriteria: "Scenario created is visible", blocks: [])
        let handle = ExecutionEngine(driver: VisibleCriterionDriver(),
            assertionEvaluator: UnavailableAssertionEvaluator()).start(project: project(test))
        var assessments: [GoalAssessmentEvidence] = []
        for await event in handle.events {
            if case .goalAssessment(let value) = event { assessments.append(value) }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        XCTAssertEqual(assessments.last?.provider, "local.literal-visible")
        XCTAssertEqual(assessments.last?.assessment?.evidenceIDs, ["semantic-1"])
    }
    func testFinalGoalUsesFreshPostActionCaptureAndPersistsBeforeFinish() async {
        let (report, events) = await run(.init(name: "Goal", goal: "Welcome Ada is shown", blocks: [.init(title: "Relaunch", action: .relaunch)], assertions: [.exists(.identifier("done"))]))
        XCTAssertEqual(report.outcome, .passed)
        let captures = events.compactMap { if case .capture(let value) = $0 { return value }; return nil }
        let assessments = events.compactMap { if case .goalAssessment(let value) = $0 { return value }; return nil }
        XCTAssertEqual(assessments.count, 1); XCTAssertEqual(assessments[0].request?.captureID, captures.last?.captureID)
        XCTAssertEqual(captures.count, 4)
        XCTAssertEqual(assessments[0].request?.evidence.first?.id, "semantic-0")
    }
    func testUncertaintyAndUnavailableCannotPass() async {
        for evaluator in [TestEvaluator(verdict: .insufficient), TestEvaluator(confidence: 0.2), TestEvaluator(wrongID: true), TestEvaluator(requiresImage: true), TestEvaluator(confidence: .nan)] {
            let (report, events) = await run(.init(name: "Goal", goal: "Welcome", blocks: []), evaluator: evaluator)
            XCTAssertEqual(report.outcome, .needsReview)
            for event in events { XCTAssertNoThrow(try JSONEncoder().encode(event)) }
        }
        let unavailable = await run(.init(name: "Goal", goal: "Welcome", blocks: []), evaluator: UnavailableAssertionEvaluator())
        XCTAssertEqual(unavailable.0.outcome, .needsReview)
    }
    func testExplicitImageAndOCRRequirementsRefuseSemanticOnlyPass() async {
        for mode in [GoalAssessmentPolicy.EvidenceRequirement.image, .ocr] {
            let (report, _) = await run(.init(name: "Goal", goal: "Welcome", blocks: [], goalAssessmentPolicy: .init(requirement: mode)))
            XCTAssertEqual(report.outcome, .needsReview)
        }
    }
    func testImageNeededFallsBackOnlyWithRunApprovalAndFreshScreenshot() async throws {
        let driver = try ScreenshotGoalDriver()
        let assessor = ScreenshotGoalAssessor()
        let test = ProjectDomain.TestCase(name: "Practice", goal: "Complete onboarding",
            successCriteria: "When the practice tab is active", blocks: [])
        func execute(_ choice: ImageDisclosureChoice) async -> (ExecutionReport, [GoalAssessmentEvidence]) {
            let handle = ExecutionEngine(driver: driver,
                assertionEvaluator: TestEvaluator(verdict: .insufficient, requiresImage: true),
                imageAssessor: assessor, imageDisclosureChoice: choice).start(project: project(test))
            var assessments: [GoalAssessmentEvidence] = []
            for await event in handle.events {
                if case .goalAssessment(let value) = event { assessments.append(value) }
            }
            return (await handle.task.value, assessments)
        }
        let refused = await execute(.localOnly)
        XCTAssertEqual(refused.0.outcome, .needsReview)
        let before = await assessor.calls()
        XCTAssertEqual(before, 0)
        let approved = await execute(.allowRemoteForThisRun)
        XCTAssertEqual(approved.0.outcome, .passed)
        XCTAssertEqual(approved.1.last?.request?.mode, .imageObserved)
        XCTAssertEqual(approved.1.last?.imageAssessment?.captureID, approved.1.last?.request?.captureID)
        XCTAssertEqual(approved.1.last?.provider, "fixture.screenshot")
        let after = await assessor.calls()
        XCTAssertEqual(after, 1)
    }
    func testOCRProvesGoalBeforeSendingScreenshot() async throws {
        let driver = try ScreenshotGoalDriver(ocrText: "Scenario created")
        let assessor = ScreenshotGoalAssessor()
        let test = ProjectDomain.TestCase(name: "Completion", goal: "Create a scenario",
            successCriteria: "Scenario created is visible", blocks: [])
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: OCRThenImageEvaluator(),
            imageAssessor: assessor, imageDisclosureChoice: .localOnly).start(project: project(test))
        var assessments: [GoalAssessmentEvidence] = []
        for await event in handle.events {
            if case .goalAssessment(let value) = event { assessments.append(value) }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed)
        XCTAssertEqual(assessments.last?.request?.mode, .ocrText)
        XCTAssertEqual(assessments.last?.provider, "fixture.ocr-evaluator")
        let calls = await assessor.calls()
        XCTAssertEqual(calls, 0)
    }
    func testDeterministicFailureWinsAndInvalidSummaryFallsBack() async {
        let (report, events) = await run(.init(name: "Goal", goal: "Welcome", blocks: [], assertions: [.exists(.identifier("absent"))]), summary: WrongSummary())
        XCTAssertEqual(report.outcome, .failed)
        let summaries = events.compactMap { if case .failureSummary(let s) = $0 { return s }; return nil }
        XCTAssertEqual(summaries.first?.source.outcome, .failed); XCTAssertEqual(summaries.first?.provider, "local.recorded-evidence")
    }
    func testLocalValidationRejectsUnknownReferencesAndLateResponses() {
        let request = GoalAssessmentRequest(goal: "Ready", snapshot: .init(captureID: .init(), elements: [.init(identifier: "ready", role: "text", label: "Ready", value: nil, frame: nil)]), deadline: Date().addingTimeInterval(5))
        for ids in [[], ["invented"], ["semantic-0", "semantic-0"]] {
            let response = AssertionAssessment(requestID: request.requestID, captureID: request.captureID, verdict: .satisfied, confidence: 1, evidenceIDs: ids, reason: "Ready")
            XCTAssertEqual(GoalAssessmentEvidence.validate(response, request: request, minimumConfidence: 0.9).0, .needsReview)
        }
        let response = AssertionAssessment(requestID: request.requestID, captureID: request.captureID, verdict: .satisfied, confidence: 1, evidenceIDs: ["semantic-0"], reason: "Ready")
        XCTAssertEqual(GoalAssessmentEvidence.validate(response, request: request, minimumConfidence: 0.9, now: request.deadline).0, .needsReview)
    }
    func testBoundedProviderReturnsWithoutWaitingForUncooperativeWorker() async {
        let start = Date()
        do { let _: Int = try await boundedProviderCall(deadline: Date().addingTimeInterval(0.03)) { await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 1) { c.resume(returning: 3) } } }; XCTFail() } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
    func testGoalPolicyRoundtripAndEditingPreserveConfiguration() throws {
        let value = ProjectDomain.TestCase(name: "test", goal: "blue", blocks: [], goalAssessmentPolicy: .init(requirement: .image))
        let decoded = try JSONDecoder().decode(ProjectDomain.TestCase.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.replacing(name: "renamed").goalAssessmentPolicy?.requirement, .image)
        XCTAssertEqual(decoded.duplicated().goalAssessmentPolicy?.requirement, .image)
    }
}

private actor SlowGoalEvaluator: AssertionEvaluating {
    nonisolated var providerID: String { "test.uncooperative" }
    var entered = false
    func assess(_ request: GoalAssessmentRequest) async throws -> AssertionAssessment {
        entered = true
        await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { c.resume() } }
        return .init(requestID: request.requestID, captureID: request.captureID, verdict: .satisfied, confidence: 1, evidenceIDs: ["semantic-0"], reason: "Late immutable result")
    }
}
extension GoalAssessmentTests {
    func testStopDuringProviderCannotPublishLatePass() async throws {
        let evaluator = SlowGoalEvaluator()
        let driver = GoalDriver()
        let handle = ExecutionEngine(driver: driver, assertionEvaluator: evaluator).start(project: project(.init(name: "Stop", goal: "Welcome", blocks: [])))
        while !(await evaluator.entered) { try await Task.sleep(for: .milliseconds(1)) }
        let start = Date(); handle.cancel()
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .cancelled); XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
        var goals: [GoalAssessmentEvidence] = []
        for await event in handle.events { if case .goalAssessment(let evidence) = event { goals.append(evidence) } }
        XCTAssertEqual(goals.count, 1); XCTAssertEqual(goals.first?.outcome, .needsReview)
        let actions = await driver.actions; XCTAssertEqual(actions, 0)
    }
    func testShortGoalBudgetNeedsReviewWithoutWaitingForProvider() async {
        let start = Date()
        let result = await run(.init(name: "deadline", goal: "Welcome", blocks: [], goalAssessmentPolicy: .init(timeoutSeconds: 0.02)), evaluator: SlowGoalEvaluator())
        XCTAssertEqual(result.0.outcome, .needsReview); XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}

extension GoalAssessmentTests {
    func testSharedAppleLeaseRejectsFreshProviderInstances() async throws {
        guard AppleAssertionEvaluator().availability == .available else { throw XCTSkip("Actual Apple runtime unavailable for controlled lease test") }
        try await AppleAssessmentLease.shared.acquire()
        let request = GoalAssessmentRequest(goal: "Ready", snapshot: .init(captureID: .init(), elements: []), deadline: Date().addingTimeInterval(1))
        for _ in 0..<3 {
            do { _ = try await AppleAssertionEvaluator().assess(request); XCTFail("Fresh evaluator escaped shared lease") } catch ProviderFailure.busy {} catch { XCTFail("Unexpected \(error)") }
        }
        do { _ = try await AppleFailureSummariser().summarise(.init(testID: UUID(), outcome: .failed, reason: "Recorded failure", assessmentRequestID: nil)); XCTFail() } catch ProviderFailure.busy {} catch { XCTFail("Unexpected \(error)") }
        await AppleAssessmentLease.shared.release()
    }
}

extension GoalAssessmentTests {
    func testNonfiniteConfidenceCannotMasqueradeAsValidZeroThreshold() async {
        let (report, events) = await run(.init(name: "invalid", goal: "Welcome", blocks: [], goalAssessmentPolicy: .init(minimumConfidence: 0)), evaluator: TestEvaluator(confidence: .nan))
        XCTAssertEqual(report.outcome, .needsReview)
        let evidence = events.compactMap { if case .goalAssessment(let value) = $0 { return value }; return nil }.first
        XCTAssertNotNil(evidence?.invalidNumericValues?["assessment.confidence"])
        XCTAssertEqual(evidence?.outcome, .needsReview)
        XCTAssertNoThrow(try JSONEncoder().encode(evidence))
    }
}
