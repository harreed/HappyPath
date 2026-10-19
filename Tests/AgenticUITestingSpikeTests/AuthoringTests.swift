import XCTest
import ProjectDomain
@testable import ModelProviders

final class AuthoringTests: XCTestCase {
    func fixture() -> TestCase {
        TestCase(name: "Original", goal: "Keep goal", preconditions: [.textVisible("Ready")], blocks: [.init(title: "Tap", action: .tap(targets: [.identifier("start")])), .init(title: "Type", action: .typeText("Ada", targets: [.semantic(role: "textField", label: "Name", value: nil)])), .init(title: "Swipe", action: .swipe(.up, targets: []))], assertions: [.exists(.identifier("dashboard"))], recoveryPolicy: .init(maximumActions: 3, timeoutSeconds: 7, minimumConfidence: 0.95), timeoutSeconds: 42)
    }
    func testOrderedEditingDuplicationAndPoliciesRoundTrip() throws {
        let original = fixture(), id = original.blocks[1].id
        var test = original.updatingBlock(id) { $0.replacing(title: "Name", enabled: false) }
        test = test.updatingBlock(id) { $0.replacing(breakpoint: true, retryPolicy: .init(maximumAttempts: 3, delaySeconds: 0.5, timeoutSeconds: 17)) }
        test = test.replacing(blocks: test.blocks.moving(id, before: original.blocks[0].id))
        XCTAssertEqual(test.blocks.map(\.id), [id, original.blocks[0].id, original.blocks[2].id])
        let copy = test.blocks[0].duplicated()
        XCTAssertNotEqual(copy.id, id); XCTAssertEqual(copy.action, test.blocks[0].action)
        XCTAssertFalse(copy.enabled); XCTAssertTrue(copy.breakpoint); XCTAssertEqual(copy.retryPolicy.timeoutSeconds, 17)
        test = test.replacing(blocks: test.blocks + [copy])
        let decoded = try JSONDecoder().decode(TestCase.self, from: JSONEncoder().encode(test))
        XCTAssertEqual(decoded, test); XCTAssertEqual(decoded.preconditions, original.preconditions); XCTAssertEqual(decoded.assertions, original.assertions); XCTAssertEqual(decoded.recoveryPolicy, original.recoveryPolicy); XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(test.blocks.moving(UUID(), before: id), test.blocks)
        XCTAssertEqual(test.blocks.moving(id, before: nil).last?.id, id)
    }
    func testDraftApplyPreservesLatestFieldsAndRejectsInvalidDefinitions() throws {
        let original = fixture()
        let newer = original.replacing(name: "Newer name", goal: "Newer goal", timeoutSeconds: 88)
        let draft = DraftPlan(blocks: [.init(title: "Relaunch", action: .relaunch)])
        let appended = try draft.applying(to: newer, append: true)
        XCTAssertEqual(appended.blocks.count, 4); XCTAssertEqual(Array(appended.blocks.prefix(3)), newer.blocks)
        let replaced = try draft.applying(to: newer, append: false)
        XCTAssertEqual(replaced, newer.replacing(blocks: draft.blocks))
        XCTAssertThrowsError(try DraftPlan(blocks: []).validate())
        XCTAssertThrowsError(try DraftPlan(blocks: [.init(title: "Tap", action: .tap(targets: []))]).validate())
        XCTAssertThrowsError(try DraftPlan(blocks: [.init(title: "Tap", action: .tap(targets: [.semantic(role: nil, label: nil, value: nil)]))]).validate())
        XCTAssertThrowsError(try DraftPlan(blocks: [.init(title: "Wait", action: .wait(.textVisible("")))]).validate())
        XCTAssertThrowsError(try DraftPlan(blocks: [draft.blocks[0], draft.blocks[0]]).validate())
        XCTAssertThrowsError(try DraftPlan(blocks: [original.blocks[0]]).applying(to: original, append: true))
        XCTAssertThrowsError(try DraftPlan(blocks: [.init(title: "Retry", action: .relaunch, retryPolicy: .init(maximumAttempts: 0))]).validate())
    }
    func testGenerationContextRejectsNewerEditsAndCancelledLateResponses() {
        let test = fixture(), projectID = UUID(), token = UUID()
        let context = DraftRequestContext(projectID: projectID, source: test, prompt: "Original prompt", token: token)
        XCTAssertTrue(context.matches(projectID: projectID, selection: test.id, test: test, prompt: "Original prompt", token: token))
        let edited = test.updatingBlock(test.blocks[0].id) { $0.replacing(title: "Newer title") }
        XCTAssertFalse(context.matches(projectID: projectID, selection: test.id, test: edited, prompt: "Original prompt", token: token))
        XCTAssertFalse(context.matches(projectID: projectID, selection: test.id, test: test, prompt: "Original prompt", token: UUID()))
        XCTAssertFalse(context.matches(projectID: projectID, selection: UUID(), test: test, prompt: "Original prompt", token: token))
        XCTAssertFalse(context.matches(projectID: UUID(), selection: test.id, test: test, prompt: "Original prompt", token: token))
        XCTAssertFalse(context.matches(projectID: projectID, selection: test.id, test: test, prompt: "New prompt", token: token))
    }
    @available(macOS 26.0, *)
    func testTypedSchemaMappingRestrictsActionsAndRequiresUsableTargets() throws {
        let target = PlannedTarget(kind: .identifier, text: "name.input", role: "", label: "", value: "")
        let planned = PlannedBlock(title: "Enter name", action: .typeText, targets: [target], text: "Ada", assertion: .exists, direction: .up)
        XCTAssertEqual(try planned.mapped().action, .typeText("Ada", targets: [.identifier("name.input")]))
        XCTAssertThrowsError(try PlannedTarget(kind: .semantic, text: "", role: "", label: "", value: "").mapped())
        let invalid = PlannedBlock(title: "Assert", action: .assertion, targets: [target,target], text: "", assertion: .exists, direction: .up)
        XCTAssertThrowsError(try invalid.mapped())
        let valid = PlannedBlock(title: "Visible", action: .assertion, targets: [], text: "Dashboard", assertion: .textVisible, direction: .up)
        XCTAssertEqual(try valid.mapped().action, .assertion(.textVisible("Dashboard")))
        let bad = PlannedBlock(title: "Missing target", action: .tap, targets: [], text: "", assertion: .exists, direction: .up)
        let raw = "{\"actual\":\"model output retained\"}"
        XCTAssertThrowsError(try PlannedResponse(blocks: [bad]).validatedDraft(rawJSON: raw)) { error in
            let failure = error as? PlanGenerationFailure
            XCTAssertEqual(failure?.rawJSON, raw)
            XCTAssertTrue(failure?.reason.contains("Block 1 “Missing target”") == true)
            XCTAssertTrue(failure?.reason.contains("target") == true)
        }
    }
    func testLiveAppleTypedPlan() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_APPLE_PLANNER"] == "1" else { throw XCTSkip("Opt-in live model probe; set RUN_LIVE_APPLE_PLANNER=1.") }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("phase2-runs/planning-probe/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("Live Apple planning evidence: \(directory.path)")
        let provider = ApplePlanGenerator()
        try String(describing: provider.availability).write(to: directory.appendingPathComponent("availability.txt"), atomically: true, encoding: .utf8)
        guard provider.availability == .available else { XCTFail("Live Apple model unavailable; see availability.txt"); return }
        let prompt = ProcessInfo.processInfo.environment["APPLE_PLANNER_PROMPT"] ?? "Create exactly three ordered blocks: tap the accessibility identifier welcome.continue; enter the literal text Ada into the accessibility identifier profile.name; assert that accessibility identifier dashboard.title exists. Use only tap, typeText, and assertion actions, one identifier target per block. Do not add relaunch or other steps."
        try prompt.write(to: directory.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
        do {
            let output = try await provider.generateWithEvidence(prompt: prompt)
            try output.rawJSON.write(to: directory.appendingPathComponent("raw-response.json"), atomically: true, encoding: .utf8)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(output.draft.blocks).write(to: directory.appendingPathComponent("mapped-blocks.json"))
            try output.draft.validate()
            XCTAssertEqual(output.draft.blocks.map(\.action), [.tap(targets: [.identifier("welcome.continue")]), .typeText("Ada", targets: [.identifier("profile.name")]), .assertion(.exists(.identifier("dashboard.title")))])
            try "Typed generation completed; inspect test result for exact action assertions.".write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        } catch {
            if let failure = error as? PlanGenerationFailure { try failure.rawJSON.write(to: directory.appendingPathComponent("raw-response.json"), atomically: true, encoding: .utf8) }
            try error.localizedDescription.write(to: directory.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            throw error
        }
    }
}
