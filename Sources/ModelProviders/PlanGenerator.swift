import Foundation
import FoundationModels
import ProjectDomain

public enum PlanningAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// Text planning is deliberately independent of perception, assertions and candidate selection.
public protocol PlanGenerating: Sendable {
    var availability: PlanningAvailability { get }
    func generate(prompt: String) async throws -> DraftPlan
}

public enum PlanError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// Preserves the real model output even when deterministic mapping rejects it.
public struct PlanGenerationFailure: LocalizedError, Sendable {
    public let rawJSON: String
    public let reason: String
    public var errorDescription: String? { reason }
    public init(rawJSON: String, reason: String) { self.rawJSON = rawJSON; self.reason = reason }
}

/// A response is bound to the exact source definition and request revision reviewed by the user.
public struct DraftRequestContext: Sendable {
    public let projectID: UUID
    public let source: TestCase
    public let prompt: String
    public let token: UUID
    public init(projectID: UUID, source: TestCase, prompt: String, token: UUID) { self.projectID = projectID; self.source = source; self.prompt = prompt; self.token = token }
    public func matches(projectID: UUID?, selection: UUID?, test: TestCase?, prompt: String, token: UUID) -> Bool {
        self.projectID == projectID && selection == source.id && test == source && self.prompt == prompt && self.token == token
    }
}

public struct DraftPlan: Sendable, Equatable {
    public var blocks: [TestBlock]
    public init(blocks: [TestBlock]) { self.blocks = blocks }
    public func validate() throws {
        guard (1...40).contains(blocks.count) else { throw PlanError.invalid("A draft must contain 1–40 blocks.") }
        // Use the canonical validator, including duplicate UUIDs, all target shapes and retry bounds.
        try TestProject(name: "Draft validation", app: .init(projectPath: "draft.xcodeproj", scheme: "Draft", bundleIdentifier: "draft"), simulator: .init(deviceID: "draft"), categories: [.init(name: "Draft", suites: [.init(name: "Draft", tests: [.init(name: "Draft", blocks: blocks)])])]).validate()
    }
    public func applying(to test: TestCase, append: Bool) throws -> TestCase {
        try validate()
        let result = test.replacing(blocks: (append ? test.blocks : []) + blocks)
        guard Set(result.blocks.map(\.id)).count == result.blocks.count else { throw PlanError.invalid("Draft block identities conflict with this test.") }
        return result
    }
}

@available(macOS 26.0, *) @Generable
enum PlannedAction { case tap, typeText, swipe, wait, relaunch, assertion }
@available(macOS 26.0, *) @Generable
enum PlannedTargetKind { case identifier, semantic, text }
@available(macOS 26.0, *) @Generable
enum PlannedAssertion { case exists, doesNotExist, valueEquals, valueContains, textVisible }
@available(macOS 26.0, *) @Generable
enum PlannedDirection { case up, down, left, right }
@available(macOS 26.0, *) @Generable
struct PlannedTarget {
    var kind: PlannedTargetKind
    @Guide(description: "Exact accessibility identifier or exact visible text; empty for semantic") var text: String
    @Guide(description: "Semantic role, such as button or textField; empty if unknown") var role: String
    @Guide(description: "Exact semantic label; empty if unknown") var label: String
    @Guide(description: "Exact semantic value; empty if unknown") var value: String
    func mapped() throws -> TargetStrategy {
        func optional(_ s: String) -> String? { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s }
        switch kind {
        case .identifier: guard optional(text) != nil else { throw PlanError.invalid("Empty generated identifier.") }; return .identifier(text)
        case .text: guard optional(text) != nil else { throw PlanError.invalid("Empty generated text target.") }; return .text(text)
        case .semantic:
            guard [role, label, value].contains(where: { optional($0) != nil }) else { throw PlanError.invalid("Empty generated semantic target.") }
            return .semantic(role: optional(role), label: optional(label), value: optional(value))
        }
    }
}
@available(macOS 26.0, *) @Generable
struct PlannedBlock {
    var title: String
    var action: PlannedAction
    @Guide(description: "Ranked targets, identifier first. For assertions and waits use exactly one target unless textVisible. Empty only for relaunch, app-wide swipe, or textVisible.", .count(0...5)) var targets: [PlannedTarget]
    @Guide(description: "Literal text to enter or compare. For textVisible this is the exact expected visible text. Empty when unused.") var text: String
    var assertion: PlannedAssertion
    var direction: PlannedDirection
    func mapped() throws -> TestBlock {
        let targets = try targets.map { try $0.mapped() }
        func condition() throws -> AssertionDefinition {
            if case .textVisible = assertion { return .textVisible(text) }
            guard targets.count == 1, let target = targets.first else { throw PlanError.invalid("An assertion requires exactly one target.") }
            switch assertion {
            case .exists: return .exists(target)
            case .doesNotExist: return .doesNotExist(target)
            case .valueEquals: return .valueEquals(target, text)
            case .valueContains: return .valueContains(target, text)
            case .textVisible: return .textVisible(text)
            }
        }
        let result: BlockAction
        switch action {
        case .tap: result = .tap(targets: targets)
        case .typeText: result = .typeText(text, targets: targets)
        case .swipe:
            let d: SwipeDirection
            switch direction { case .up: d = .up; case .down: d = .down; case .left: d = .left; case .right: d = .right }
            result = .swipe(d, targets: targets)
        case .wait: result = .wait(try condition())
        case .assertion: result = .assertion(try condition())
        case .relaunch: result = .relaunch
        }
        return .init(title: title, action: result)
    }
}
@available(macOS 26.0, *) @Generable
struct PlannedResponse {
    @Guide(description: "Ordered deterministic UI test blocks", .count(1...40)) var blocks: [PlannedBlock]
    func validatedDraft(rawJSON: String) throws -> DraftPlan {
        let mapped = try blocks.enumerated().map { index, block in
            do {
                let value = try block.mapped()
                try DraftPlan(blocks: [value]).validate()
                return value
            } catch {
                throw PlanGenerationFailure(rawJSON: rawJSON, reason: "Block \(index + 1) “\(block.title)”: \(error.localizedDescription)")
            }
        }
        let draft = DraftPlan(blocks: mapped)
        do { try draft.validate() } catch { throw PlanGenerationFailure(rawJSON: rawJSON, reason: error.localizedDescription) }
        return draft
    }
}

public struct ApplePlanGenerator: PlanGenerating {
    public init() {}
    public var availability: PlanningAvailability { AppleModelRuntime.availability }
    static var onDeviceAvailability: PlanningAvailability {
        guard #available(macOS 26.0, *) else { return .unavailable("Planning requires macOS 26 or later. You can still edit and run deterministic tests.") }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable("This Mac does not support Apple Intelligence. Manual editing remains available.")
            case .appleIntelligenceNotEnabled: return .unavailable("Enable Apple Intelligence in System Settings to generate a draft. Manual editing remains available.")
            case .modelNotReady: return .unavailable("Apple’s on-device model is still downloading or preparing. Try again later; manual editing remains available.")
            @unknown default: return .unavailable("Apple’s on-device model is unavailable. Manual editing remains available.")
            }
        }
    }
    public func generate(prompt: String) async throws -> DraftPlan {
        try await generateWithEvidence(prompt: prompt).draft
    }
    /// Internal acceptance seam retains the actual typed model response, never a simulated plan.
    func generateWithEvidence(prompt: String) async throws -> (draft: DraftPlan, rawJSON: String) {
        guard #available(macOS 26.0, *) else { throw PlanError.invalid("Planning requires macOS 26.") }
        if case .unavailable(let message) = availability { throw PlanError.invalid(message) }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 8000 else { throw PlanError.invalid("Enter a goal of 1–8,000 characters.") }
        try Task.checkCancellation()
        let session = try AppleModelRuntime.session(instructions: "Create an editable deterministic iOS UI test draft from the user's text. Use only the typed allowed actions. Never emit code, shell commands or coordinates. Preserve exact user-provided identifiers and literal text. Prefer identifier targets; otherwise use semantic labels. These are proposed targets, not observations. Use relaunch only when requested. Use assertion for final checks and wait for synchronization. Unused text fields must be empty; unused assertion is exists and unused direction is up.")
        let response = try await session.respond(to: prompt, generating: PlannedResponse.self)
        try Task.checkCancellation()
        let rawJSON = response.rawContent.jsonString
        return (try response.content.validatedDraft(rawJSON: rawJSON), rawJSON)
    }
}
