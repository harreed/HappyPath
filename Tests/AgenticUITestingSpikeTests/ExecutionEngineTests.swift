import XCTest
import ProjectDomain
@testable import RunnerCore

private actor EngineTestDriver: RunnerDriving {
    var actions: [DrivenAction] = []
    var failures: [DriverFailure]
    var captures = 0
    var stopped = false
    var deadlines: [Date] = []
    var startingStates: [TestStartingState] = []
    let slow: Bool
    let failAfterAction: Bool
    var elements: [UIElement]?
    var recoveryElements: [UIElement]?
    var expireSecondCapture = false
    var failSecondCapture = false
    var failFinalization = false
    var slowPreparation = false
    func delayPreparation() { slowPreparation = true }
    func configure(elements: [UIElement]? = nil, expireSecondCapture: Bool = false, failSecondCapture: Bool = false, failFinalization: Bool = false) {
        self.elements = elements; self.expireSecondCapture = expireSecondCapture
        self.failSecondCapture = failSecondCapture; self.failFinalization = failFinalization
    }
    func recoverTo(_ elements: [UIElement]) { recoveryElements = elements }
    init(failures: [DriverFailure] = [], slow: Bool = false, failAfterAction: Bool = false) {
        self.failures = failures; self.slow = slow; self.failAfterAction = failAfterAction
    }
    func prepare(project: TestProject, deadline: Date) async throws { if slowPreparation { try await Task.sleep(for: .milliseconds(150)) } }
    func applyStartingState(_ state: TestStartingState, deadline: Date) async throws { startingStates.append(state) }
    func capture(deadline: Date) async throws -> UISnapshot {
        captures += 1; deadlines.append(deadline)
        if captures == 2 && expireSecondCapture {
            try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 0.005))
            throw DriverFailure.unavailable("deadline")
        }
        if captures == 2 && failSecondCapture { throw DriverFailure.unavailable("environment unavailable") }
        if let elements { return .init(captureID: .init(), elements: elements) }
        if failAfterAction && !actions.isEmpty { throw DriverFailure.notDispatched("capture unavailable") }
        return .init(captureID: .init(), elements: [.init(identifier: "button", role: "button", label: "Continue", value: "ready", frame: nil, isEnabled: true, isHittable: true)])
    }
    func perform(_ action: DrivenAction, deadline: Date) async throws {
        actions.append(action); deadlines.append(deadline)
        if case .tapElement = action, let recoveryElements { elements = recoveryElements }
        if case .recoveryTap = action, let recoveryElements { elements = recoveryElements }
        if slow { try await Task.sleep(for: .seconds(5)) }
        if !failures.isEmpty { throw failures.removeFirst() }
    }
    func stop() async { stopped = true }
    func finish() async throws {
        if failFinalization { throw DriverFailure.unavailable("recording incomplete") }
        await stop()
    }
}

final class ExecutionEngineTests: XCTestCase {
    func testAppliesConfiguredStartingStateBeforeFirstCapture() async {
        let state = TestStartingState(appData: .reinstall, permissions: .reset, appearance: .dark)
        let driver = EngineTestDriver()
        let test = ProjectDomain.TestCase(name: "Stateful", preconditions: [.exists(.identifier("button"))], blocks: [], startingState: state)
        let handle = ExecutionEngine(driver: driver).start(project: project([test]))
        for await _ in handle.events {}
        let report = await handle.task.value
        let applied = await driver.startingStates
        let captures = await driver.captures
        XCTAssertEqual(report.outcome, .passed)
        XCTAssertEqual(applied, [state])
        XCTAssertGreaterThan(captures, 0)
    }
    func testSetupAndTeardownBreakpointsExcludePauseFromTheirBudgets() async {
        let driver = EngineTestDriver()
        let bounded = TestBlock(title: "boundary", action: .relaunch, breakpoint: true, retryPolicy: .init(timeoutSeconds: 0.1))
        let handle = ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [], assertions: [.exists(.identifier("button"))], timeoutSeconds: 0.1)], setup: [bounded], teardown: [.init(title: "teardown", action: .relaunch, breakpoint: true, retryPolicy: .init(timeoutSeconds: 0.1))]))
        var pauses = 0
        for await event in handle.events {
            if case .state(.paused) = event {
                pauses += 1
                let before = await driver.actions.count
                try? await Task.sleep(for: .milliseconds(180))
                let after = await driver.actions.count; XCTAssertEqual(before, after)
                await handle.control.resume()
            }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed); XCTAssertEqual(pauses, 2)
    }
    func testPauseBeforeEmptyAssertionOnlyTestPreventsCaptureUntilResume() async {
        let driver = EngineTestDriver(); await driver.delayPreparation()
        let handle = ExecutionEngine(driver: driver).start(project: project([.init(name: "assert only", preconditions: [.exists(.identifier("button"))], blocks: [], assertions: [.exists(.identifier("button"))], timeoutSeconds: 0.1)]))
        await handle.control.pause()
        var pauses = 0
        for await event in handle.events {
            if case .state(.paused) = event {
                pauses += 1
                try? await Task.sleep(for: .milliseconds(180))
                let captures = await driver.captures; XCTAssertEqual(captures, 0)
                await handle.control.resume()
            }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed); XCTAssertEqual(pauses, 1)
    }
    func testStepAndPauseExcludeLongIdleFromFinalAssertionDeadline() async {
        let driver = EngineTestDriver()
        let handle = ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [tap(breakpoint: true), tap()], assertions: [.exists(.identifier("button"))], timeoutSeconds: 0.15)]))
        var pauses = 0
        for await event in handle.events {
            if case .state(.paused) = event {
                pauses += 1
                let before = await driver.actions.count
                XCTAssertEqual(before, pauses - 1)
                try? await Task.sleep(for: .milliseconds(220))
                let after = await driver.actions.count
                XCTAssertEqual(after, before)
                if pauses < 3 { await handle.control.step() } else { await handle.control.resume() }
            }
        }
        let result = await handle.task.value
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(pauses, 3)
    }
    func testCancelPausedRetainsCleanupAndNeverReachesNextTest() async {
        let driver = EngineTestDriver()
        let handle = ExecutionEngine(driver: driver).start(project: project([.init(name: "first", blocks: [tap(breakpoint: true)]), .init(name: "second", preconditions: [.exists(.identifier("button"))], blocks: [tap()])]))
        for await event in handle.events { if case .state(.paused) = event { handle.cancel() } }
        let result = await handle.task.value
        XCTAssertEqual(result.outcome, .cancelled)
        let captures = await driver.captures; let stopped = await driver.stopped
        XCTAssertEqual(captures, 0); XCTAssertTrue(stopped)
        XCTAssertEqual(result.tests.count, 1)
    }
    func testFinalizationFailureCannotPass() async {
        let driver = EngineTestDriver()
        await driver.configure(failFinalization: true)
        let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [])])).task.value
        XCTAssertEqual(report.outcome, .blocked)
        let stopped = await driver.stopped; XCTAssertTrue(stopped)
    }
    func testSemanticActionsWithoutIdentifiersAndAmbiguity() async {
        let element = UIElement(identifier: nil, role: "button", label: "Continue", value: "ready", frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [element])
        let blocks = [tap(), TestBlock(title: "type", action: .typeText("text", targets: [.text("Continue")])), TestBlock(title: "swipe", action: .swipe(.up, targets: [.text("Continue")]))]
        let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: blocks)])).task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, [.tapElement(element), .typeTextElement("text", element), .swipeElement(.up, element)])
        let ambiguous = EngineTestDriver(); await ambiguous.configure(elements: [element, element])
        let blocked = await ExecutionEngine(driver: ambiguous).start(project: project([.init(name: "t", blocks: [tap()])])).task.value
        XCTAssertEqual(blocked.outcome, .blocked)
        let count = await ambiguous.actions.count; XCTAssertEqual(count, 0)
    }
    func testWaitNextCaptureDeadlineVersusEnvironmentFailure() async {
        for expire in [true, false] {
            let driver = EngineTestDriver()
            await driver.configure(expireSecondCapture: expire, failSecondCapture: !expire)
            let block = TestBlock(title: "wait", action: .wait(.exists(.identifier("missing"))), retryPolicy: .init(timeoutSeconds: 0.2))
            let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [block])])).task.value
            XCTAssertEqual(report.outcome, expire ? .failed : .blocked)
        }
    }
    func testRetryDelayAndNextCaptureDeadlineRemainFailed() async {
        for nextCapture in [true, false] {
            let driver = EngineTestDriver(failures: [.notDispatched("not sent")])
            await driver.configure(expireSecondCapture: nextCapture)
            let block = TestBlock(title: "tap", action: .tap(targets: [.identifier("button")]), retryPolicy: .init(maximumAttempts: 3, delaySeconds: nextCapture ? 0 : 1, timeoutSeconds: 0.05))
            let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [block])])).task.value
            XCTAssertEqual(report.outcome, .failed)
            let count = await driver.actions.count; XCTAssertEqual(count, 1)
        }
    }
    private func project(_ tests: [ProjectDomain.TestCase], setup: [TestBlock] = [], teardown: [TestBlock] = []) -> TestProject {
        .init(name: "p", app: .init(projectPath: "p", scheme: "s", bundleIdentifier: "b"), simulator: .init(deviceID: "d"), categories: [.init(name: "c", suites: [.init(name: "s", setup: setup, tests: tests, teardown: teardown)])])
    }
    private func tap(enabled: Bool = true, breakpoint: Bool = false) -> TestBlock {
        .init(title: "tap", action: .tap(targets: [.semantic(role: "button", label: "Continue", value: nil)]), enabled: enabled, breakpoint: breakpoint, retryPolicy: .init(maximumAttempts: 3, delaySeconds: 0, timeoutSeconds: 2))
    }
    func testRetryOnlyProvenNonDispatch() async {
        for (failure, expected, count) in [(DriverFailure.notDispatched("not sent"), RunOutcome.passed, 2), (.uncertain("lost response"), .needsReview, 1), (.unavailable("unsupported"), .blocked, 1)] {
            let driver = EngineTestDriver(failures: [failure])
            let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [tap()])])).task.value
            XCTAssertEqual(report.outcome, expected)
            let actual = await driver.actions.count; XCTAssertEqual(actual, count)
            let stopped = await driver.stopped; XCTAssertTrue(stopped)
        }
    }
    func testPostActionCaptureFailureNeverRetriesMutation() async {
        let driver = EngineTestDriver(failAfterAction: true)
        let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [tap()])])).task.value
        XCTAssertEqual(report.outcome, .needsReview)
        let count = await driver.actions.count; XCTAssertEqual(count, 1)
    }
    func testOrderingSetupTeardownDisabledAndCaptureEvents() async throws {
        let first = ProjectDomain.TestCase(name: "a", blocks: [tap(enabled: false), .init(title: "type", action: .typeText("a", targets: [.identifier("button")]))])
        let second = ProjectDomain.TestCase(name: "b", blocks: [.init(title: "swipe", action: .swipe(.up, targets: [.identifier("button")]))])
        let driver = EngineTestDriver()
        let handle = ExecutionEngine(driver: driver).start(project: project([first, second], setup: [.init(title: "launch", action: .relaunch)], teardown: [tap()]), selection: .selection([second.id, first.id]))
        var ids: [UUID] = []; var skipped = 0; var actionStarted = 0; var captured = 0; var finished = 0
        for await event in handle.events {
            _ = try JSONEncoder().encode(event)
            switch event {
            case .testStarted(let id): ids.append(id)
            case .blockSkipped: skipped += 1
            case .actionStarted: actionStarted += 1
            case .capture: captured += 1
            case .blockFinished: finished += 1
            default: break
            }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .passed); XCTAssertEqual(ids, [first.id, second.id])
        XCTAssertEqual(skipped, 1); XCTAssertEqual(actionStarted, 4); XCTAssertEqual(captured, 8); XCTAssertEqual(finished, 4)
        let actions = await driver.actions
        XCTAssertEqual(actions, [.relaunch, .typeText("a", identifier: "button"), .swipe(.up, identifier: "button"), .tap(identifier: "button")])
    }
    func testBreakpointCannotActAndFailureOverridesReview() async {
        let driver = EngineTestDriver()
        let handle = ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [tap(breakpoint: true)], assertions: [.exists(.identifier("missing"))])]))
        for await event in handle.events {
            if case .state(.paused) = event {
                let count = await driver.actions.count; XCTAssertEqual(count, 0)
                await handle.control.resume()
            }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .failed)
        let count = await driver.actions.count; XCTAssertEqual(count, 1)
    }
    func testWaitTimeoutAndMissingTargetFail() async {
        for action in [BlockAction.wait(.exists(.identifier("missing"))), .tap(targets: [.identifier("missing")])] {
            let driver = EngineTestDriver()
            let block = TestBlock(title: "missing", action: action, retryPolicy: .init(maximumAttempts: 2, delaySeconds: 0, timeoutSeconds: 0.05))
            let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [block])])).task.value
            XCTAssertEqual(report.outcome, .failed)
            let count = await driver.actions.count; XCTAssertEqual(count, 0)
        }
    }
    func testCancellationStopsWithoutRetry() async {
        let driver = EngineTestDriver(slow: true)
        let handle = ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [tap()])]))
        for await event in handle.events {
            if case .actionStarted = event { try? await Task.sleep(for: .milliseconds(10)); handle.cancel(); break }
        }
        let report = await handle.task.value
        XCTAssertEqual(report.outcome, .cancelled)
        let count = await driver.actions.count; XCTAssertEqual(count, 1)
        let stopped = await driver.stopped; XCTAssertTrue(stopped)
    }
    func testTestDeadlineCapsEveryCaptureAndAction() async {
        let driver = EngineTestDriver(); let start = Date()
        let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [tap()], assertions: [.valueEquals(.identifier("button"), "ready")], timeoutSeconds: 0.5)])).task.value
        XCTAssertEqual(report.outcome, .passed)
        let deadlines = await driver.deadlines
        XCTAssertGreaterThan(deadlines.count, 2)
        XCTAssertTrue(deadlines.allSatisfy { $0.timeIntervalSince(start) < 0.7 })
    }
    func testIdentifierGuessFallsBackToVisibleLabel() async {
        // Regression: the Apple button exposes no accessibilityIdentifier,
        // only role=button label="Sign in with Apple". A user-guessed identifier
        // derived from the label must still resolve — to the true node.
        let element = UIElement(identifier: nil, role: "button", label: "Sign in with Apple", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [element])
        let block = TestBlock(title: "tap", action: .tap(targets: [.identifier("Sign In With Apple Button")]), retryPolicy: .init(maximumAttempts: 1, delaySeconds: 0, timeoutSeconds: 2))
        let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [block])])).task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, [.tapElement(element)])
    }
    func testSuccessfulFallbackProducesReviewableLocatorSuggestion() async {
        let element = UIElement(identifier: "currentButton", role: "button", label: "Continue", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [element])
        let original: [TargetStrategy] = [.identifier("oldButton"), .semantic(role: "button", label: "Continue", value: nil)]
        let block = TestBlock(title: "tap", action: .tap(targets: original))
        let (report, events) = await run(ExecutionEngine(driver: driver), project([.init(name: "t", blocks: [block])]))
        XCTAssertEqual(report.outcome, .passed)
        let suggestions = events.compactMap { if case .locatorSuggestion(let value) = $0 { return value }; return nil }
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.blockID, block.id)
        XCTAssertEqual(suggestions.first?.originalTargets, original)
        XCTAssertEqual(suggestions.first?.proposedTarget, .identifier("currentButton"))
        XCTAssertEqual(suggestions.first?.matchedStrategyIndex, 1)
        XCTAssertNotEqual(suggestions.first?.sourceCaptureID, suggestions.first?.postActionCaptureID)
    }
    func testExactLocatorAndFailedDispatchDoNotSuggestEdit() async {
        let element = UIElement(identifier: "currentButton", role: "button", label: "Continue", value: nil, frame: nil, isEnabled: true, isHittable: true)
        for (targets, failures) in [([TargetStrategy.identifier("currentButton")], [DriverFailure]()),
                                    ([.identifier("oldButton"), .semantic(role: "button", label: "Continue", value: nil)], [.notDispatched("not sent")])] {
            let driver = EngineTestDriver(failures: failures); await driver.configure(elements: [element])
            let block = TestBlock(title: "tap", action: .tap(targets: targets), retryPolicy: .init(maximumAttempts: 1))
            let (_, events) = await run(ExecutionEngine(driver: driver), project([.init(name: "t", blocks: [block])]))
            XCTAssertFalse(events.contains { if case .locatorSuggestion = $0 { return true }; return false })
        }
    }
    func testCloseButtonGuessResolvesBackAffordance() async {
        // Regression: the plan says `close button` for the navigation
        // control the app exposes as `BackButton` (label `Back`).
        let back = UIElement(identifier: "BackButton", role: "button", label: "Back", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [back])
        let block = TestBlock(title: "back", action: .tap(targets: [.identifier("close button")]), retryPolicy: .init(maximumAttempts: 1, delaySeconds: 0, timeoutSeconds: 2))
        let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [block])])).task.value
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions, [.tap(identifier: "BackButton")])
    }
    func testAmbiguousDismissalAffordancesBlockWithoutActing() async {
        let back = UIElement(identifier: "BackButton", role: "button", label: "Back", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let dismiss = UIElement(identifier: "DismissButton", role: "button", label: "Dismiss", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [back, dismiss])
        let block = TestBlock(title: "back", action: .tap(targets: [.identifier("close button")]), retryPolicy: .init(maximumAttempts: 1, delaySeconds: 0, timeoutSeconds: 2))
        let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [block])])).task.value
        XCTAssertEqual(report.outcome, .blocked)
        let count = await driver.actions.count; XCTAssertEqual(count, 0)
    }
    func testDismissalInferenceNeverMatchesUnrelatedPhrases() async {
        let back = UIElement(identifier: "BackButton", role: "button", label: "Back", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [back])
        let block = TestBlock(title: "close account", action: .tap(targets: [.identifier("close account")]), retryPolicy: .init(maximumAttempts: 1, delaySeconds: 0, timeoutSeconds: 0.05))
        // Escapes are disabled so this isolates target inference from the
        // separate, policy-gated safe-escape mechanism.
        let test = ProjectDomain.TestCase(name: "t", blocks: [block], recoveryPolicy: .init(allowSafeEscapes: false, maximumUnresolvedSteps: 0))
        let report = await ExecutionEngine(driver: driver).start(project: project([test])).task.value
        XCTAssertEqual(report.outcome, .failed)
        let count = await driver.actions.count; XCTAssertEqual(count, 0)
    }
    func testVagueTextFallsBackToSubstring() async {
        let element = UIElement(identifier: nil, role: "button", label: "Sign in with Apple", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [element])
        let block = TestBlock(title: "tap", action: .tap(targets: [.text("sign in with apple")]), retryPolicy: .init(maximumAttempts: 1, delaySeconds: 0, timeoutSeconds: 2))
        let report = await ExecutionEngine(driver: driver).start(project: project([.init(name: "t", blocks: [block])])).task.value
        XCTAssertEqual(report.outcome, .passed)
    }
    private func run(_ engine: ExecutionEngine, _ project: TestProject) async -> (ExecutionReport, [ExecutionEvent]) {
        let handle = engine.start(project: project)
        var events: [ExecutionEvent] = []
        for await event in handle.events { events.append(event) }
        return (await handle.task.value, events)
    }
    func testWaitEscapesObstructionThenSucceeds() async {
        let sheet: [UIElement] = [
            .init(identifier: nil, role: "sheet", label: nil, value: nil, frame: nil),
            .init(identifier: "CloseButton", role: "button", label: "Close", value: nil, frame: nil, isEnabled: true, isHittable: true)
        ]
        let next: [UIElement] = [.init(identifier: "NextButton", role: "button", label: "Next", value: nil, frame: nil, isEnabled: true, isHittable: true)]
        let driver = EngineTestDriver(); await driver.configure(elements: sheet); await driver.recoverTo(next)
        let block = TestBlock(title: "wait", action: .wait(.exists(.identifier("NextButton"))), retryPolicy: .init(timeoutSeconds: 5))
        let (report, events) = await run(ExecutionEngine(driver: driver), project([.init(name: "t", blocks: [block])]))
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions.count, 1)
        guard case .tapElement(let element) = actions.first else { return XCTFail("Expected one bound semantic escape tap") }
        XCTAssertEqual(element.label, "Close")
        XCTAssertTrue(events.contains { if case .recovery(let evidence) = $0 { return evidence.origin == .escape && evidence.status == .verified }; return false })
    }
    func testUnresolvedStepContinuesForwardToLaterWaypoint() async {
        let target = UIElement(identifier: "Target", role: "button", label: "Target", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [target])
        let blocks = [TestBlock(title: "missing", action: .tap(targets: [.identifier("Missing")])),
                      TestBlock(title: "waypoint", action: .wait(.exists(.identifier("Target"))), retryPolicy: .init(timeoutSeconds: 2))]
        let (report, events) = await run(ExecutionEngine(driver: driver), project([.init(name: "t", blocks: blocks)]))
        XCTAssertEqual(report.outcome, .needsReview)
        let count = await driver.actions.count; XCTAssertEqual(count, 0)
        XCTAssertTrue(events.contains { if case .blockFinished(_, let outcome, _, let reason) = $0 { return outcome == .needsReview && (reason?.contains("Continued forward") ?? false) }; return false })
    }
    func testConsecutiveUnresolvedStepsStopAsOffCourse() async {
        let driver = EngineTestDriver()
        await driver.configure(elements: [.init(identifier: "static", role: "staticText", label: "Nothing here", value: nil, frame: nil)])
        let blocks = (1...4).map { TestBlock(title: "missing \($0)", action: .tap(targets: [.identifier("Missing\($0)")])) }
        let test = ProjectDomain.TestCase(name: "t", blocks: blocks, recoveryPolicy: .init(maximumUnresolvedSteps: 1))
        let (report, events) = await run(ExecutionEngine(driver: driver), project([test]))
        XCTAssertEqual(report.outcome, .needsReview)
        var started = 0; var offCourse = false
        for event in events {
            switch event {
            case .blockStarted: started += 1
            case .blockFinished(_, _, _, let reason): offCourse = offCourse || (reason?.contains("Off course") ?? false)
            default: break
            }
        }
        XCTAssertEqual(started, 2)
        XCTAssertTrue(offCourse)
        let count = await driver.actions.count; XCTAssertEqual(count, 0)
    }
    func testWaitSkipsAheadWhenLaterWaypointAlreadyVisible() async {
        let target = UIElement(identifier: "Target", role: "button", label: "Target", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [target])
        let blocks = [TestBlock(title: "stuck wait", action: .wait(.exists(.identifier("Missing"))), retryPolicy: .init(timeoutSeconds: 10)),
                      TestBlock(title: "waypoint", action: .wait(.exists(.identifier("Target"))), retryPolicy: .init(timeoutSeconds: 2))]
        let start = Date()
        let (report, events) = await run(ExecutionEngine(driver: driver), project([.init(name: "t", blocks: blocks)]))
        XCTAssertEqual(report.outcome, .needsReview)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(events.contains { if case .blockFinished(_, _, _, let reason) = $0 { return reason?.contains("matches later step") ?? false }; return false })
    }
    func testTapDoesNotBacktrackWhenLaterWaypointVisible() async {
        let back = UIElement(identifier: "BackButton", role: "button", label: "Back", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let target = UIElement(identifier: "Target", role: "button", label: "Target", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [back, target])
        let blocks = [TestBlock(title: "missing", action: .tap(targets: [.identifier("Missing")]), retryPolicy: .init(timeoutSeconds: 2)),
                      TestBlock(title: "waypoint", action: .wait(.exists(.identifier("Target"))), retryPolicy: .init(timeoutSeconds: 2))]
        let (report, events) = await run(ExecutionEngine(driver: driver), project([.init(name: "t", blocks: blocks)]))
        XCTAssertEqual(report.outcome, .needsReview)
        let count = await driver.actions.count; XCTAssertEqual(count, 0)
        XCTAssertTrue(events.contains { if case .blockFinished(_, _, _, let reason) = $0 { return reason?.contains("matches later step") ?? false }; return false })
    }
    func testZeroUnresolvedBudgetKeepsFailFast() async {
        let target = UIElement(identifier: "Target", role: "button", label: "Target", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [target])
        let blocks = [TestBlock(title: "missing", action: .tap(targets: [.identifier("Missing")])),
                      TestBlock(title: "waypoint", action: .wait(.exists(.identifier("Target"))), retryPolicy: .init(timeoutSeconds: 2))]
        let test = ProjectDomain.TestCase(name: "t", blocks: blocks, recoveryPolicy: .init(maximumUnresolvedSteps: 0))
        let (report, events) = await run(ExecutionEngine(driver: driver), project([test]))
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(events.filter { if case .blockStarted = $0 { return true }; return false }.count, 1)
    }
    func testAmbiguousEscapeRefusesWithoutDispatch() async {
        let back = UIElement(identifier: "BackButton", role: "button", label: "Back", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let close = UIElement(identifier: "CloseButton", role: "button", label: "Close", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [back, close])
        let block = TestBlock(title: "missing", action: .tap(targets: [.identifier("Missing")]), retryPolicy: .init(timeoutSeconds: 2))
        let (report, events) = await run(ExecutionEngine(driver: driver), project([.init(name: "t", blocks: [block])]))
        XCTAssertEqual(report.outcome, .failed)
        let count = await driver.actions.count; XCTAssertEqual(count, 0)
        XCTAssertTrue(events.contains { if case .recovery(let evidence) = $0 { return evidence.origin == .escape && evidence.status == .refused && evidence.reason.contains("Ambiguous dismissal") }; return false })
    }
    func testProgressEscapeAdvancesPastObstruction() async {
        let sheet: [UIElement] = [
            .init(identifier: nil, role: "sheet", label: nil, value: nil, frame: nil),
            .init(identifier: "get-started", role: "button", label: "Get Started", value: nil, frame: nil, isEnabled: true, isHittable: true)
        ]
        let next: [UIElement] = [.init(identifier: "NextButton", role: "button", label: "Next", value: nil, frame: nil, isEnabled: true, isHittable: true)]
        let driver = EngineTestDriver(); await driver.configure(elements: sheet); await driver.recoverTo(next)
        let block = TestBlock(title: "tap next", action: .tap(targets: [.identifier("NextButton")]), retryPolicy: .init(timeoutSeconds: 2))
        let (report, events) = await run(ExecutionEngine(driver: driver), project([.init(name: "t", blocks: [block])]))
        XCTAssertEqual(report.outcome, .passed)
        let actions = await driver.actions
        XCTAssertEqual(actions.count, 2)
        guard case .tapElement(let element) = actions.first else { return XCTFail("Expected bound semantic progress tap first") }
        XCTAssertEqual(element.label, "Get Started")
        XCTAssertTrue(events.contains { if case .recovery(let evidence) = $0 {
            return evidence.origin == .progress && evidence.status == .verified &&
                evidence.candidates.contains { if case .tapElement = $0.action { return true }; return false }
        }; return false })
    }
    func testIrreversibleScreenRefusesProgressEscape() async {
        let sheet: [UIElement] = [
            .init(identifier: nil, role: "sheet", label: nil, value: nil, frame: nil),
            .init(identifier: "trial", role: "button", label: "Start Free Trial", value: nil, frame: nil, isEnabled: true, isHittable: true)
        ]
        let driver = EngineTestDriver(); await driver.configure(elements: sheet)
        let block = TestBlock(title: "missing", action: .tap(targets: [.identifier("Missing")]), retryPolicy: .init(timeoutSeconds: 2))
        let (report, _) = await run(ExecutionEngine(driver: driver), project([.init(name: "t", blocks: [block])]))
        XCTAssertEqual(report.outcome, .failed)
        let count = await driver.actions.count; XCTAssertEqual(count, 0)
    }
    func testExplicitAssertionFailureContinuesButKeepsFailure() async {
        let target = UIElement(identifier: "Target", role: "button", label: "Target", value: nil, frame: nil, isEnabled: true, isHittable: true)
        let driver = EngineTestDriver(); await driver.configure(elements: [target])
        let blocks = [TestBlock(title: "check", action: .assertion(.exists(.identifier("Missing")))),
                      TestBlock(title: "waypoint", action: .wait(.exists(.identifier("Target"))), retryPolicy: .init(timeoutSeconds: 2))]
        let (report, events) = await run(ExecutionEngine(driver: driver), project([.init(name: "t", blocks: blocks)]))
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(events.filter { if case .blockStarted = $0 { return true }; return false }.count, 2)
    }

    func testFailedTestDoesNotPreventNextTestFromRunning() async {
        let driver = EngineTestDriver()
        let first = ProjectDomain.TestCase(name: "fails", preconditions: [.exists(.identifier("Missing"))], blocks: [])
        let second = ProjectDomain.TestCase(name: "passes", preconditions: [.exists(.identifier("button"))], blocks: [])
        let (report, events) = await run(ExecutionEngine(driver: driver), project([first, second]))

        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.tests.map(\.testID), [first.id, second.id])
        XCTAssertEqual(report.tests.map(\.outcome), [.failed, .passed])
        XCTAssertTrue(events.contains { if case .testStarted(second.id) = $0 { return true }; return false })
    }
}
