import Foundation

public enum ProjectValidationError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case duplicateID(UUID)
    case invalid(String)
    case unknownSelection(UUID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "This project uses unsupported format version \(version). Open it with a compatible version of HappyPath."
        case .duplicateID: return "Two project items share the same identifier. Each category, suite, test and block must have its own identifier."
        case .invalid(let message): return message
        case .unknownSelection: return "The selected item is no longer in this project. Select an existing test, suite or category."
        }
    }
}

extension TestProject {
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw ProjectValidationError.unsupportedVersion(schemaVersion) }
        var ids = Set<UUID>()
        func unique(_ id: UUID) throws {
            guard ids.insert(id).inserted else { throw ProjectValidationError.duplicateID(id) }
        }
        func nonempty(_ value: String, _ label: String) throws {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectValidationError.invalid("\(label) must not be empty.") }
        }
        func positive(_ value: Double, _ label: String) throws {
            guard value.isFinite && value > 0 else { throw ProjectValidationError.invalid("\(label) must be a finite number greater than zero.") }
        }
        func target(_ value: TargetStrategy) throws {
            switch value {
            case .identifier(let text): try nonempty(text, "Target accessibility identifier")
            case .text(let text): try nonempty(text, "Target text")
            case .semantic(let role, let label, let value):
                let parts = [role, label, value].compactMap { $0 }
                guard !parts.isEmpty else { throw ProjectValidationError.invalid("A semantic target needs at least one role, label or value.") }
                for part in parts { try nonempty(part, "Semantic target component") }
            }
        }
        func assertion(_ value: AssertionDefinition) throws {
            switch value {
            case .exists(let t), .doesNotExist(let t), .valueEquals(let t, _), .valueContains(let t, _): try target(t)
            case .textVisible(let text): try nonempty(text, "Expected visible text")
            case .imageMatches(_, let digest, let mean, let fraction):
                guard digest.count == 64, digest.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }),
                      mean.isFinite, (0...1).contains(mean),
                      fraction.isFinite, (0...1).contains(fraction) else {
                    throw ProjectValidationError.invalid("Visual reference needs a valid SHA-256 and thresholds between 0 and 1.")
                }
            }
        }
        func block(_ value: TestBlock) throws {
            try unique(value.id); try nonempty(value.title, "Block title")
            guard (1...100).contains(value.retryPolicy.maximumAttempts) else { throw ProjectValidationError.invalid("Maximum attempts must be between 1 and 100.") }
            guard value.retryPolicy.delaySeconds.isFinite, value.retryPolicy.delaySeconds >= 0 else { throw ProjectValidationError.invalid("Retry delay must be a finite number greater than or equal to zero.") }
            try positive(value.retryPolicy.timeoutSeconds, "Block timeout")
            switch value.action {
            case .tap(let targets), .typeText(_, let targets):
                guard !targets.isEmpty else { throw ProjectValidationError.invalid("Tap and text-entry blocks need at least one target. Add an identifier, semantic or text target.") }
                for t in targets { try target(t) }
            case .swipe(_, let targets): for t in targets { try target(t) }
            case .wait(let a), .assertion(let a): try assertion(a)
            case .relaunch: break
            case .device(let action): try action.validate()
            }
        }
        try unique(id); try nonempty(name, "Project name")
        try nonempty(app.projectPath, "Xcode container"); try nonempty(app.scheme, "Scheme")
        try nonempty(app.bundleIdentifier, "Bundle identifier"); try nonempty(app.configuration, "Build configuration")
        try nonempty(app.productName, "Product name"); try nonempty(app.derivedDataPath, "Derived data path")
        guard !app.productName.contains("/"), !app.productName.contains("\\"),
              ![".", ".."].contains(app.productName), !app.productName.contains("\0") else {
            throw ProjectValidationError.invalid("Product name must be an app basename")
        }
        try nonempty(simulator.deviceID, "Simulator device")
        if let c = app.companion {
            try nonempty(c.projectPath, "Companion container"); try nonempty(c.scheme, "Companion scheme")
            try nonempty(c.testIdentifier, "Companion test"); try nonempty(c.runnerBundleIdentifier, "Companion runner")
            let components = c.mailboxRelativePath.split(separator: "/")
            guard !c.mailboxRelativePath.hasPrefix("/"), !components.isEmpty, !components.contains(".."), !components.contains(".") else { throw ProjectValidationError.invalid("Companion mailbox must stay within its container") }
        }
        let policies = reviewedAlertPolicies ?? []
        guard Set(policies.map(\.id)).count == policies.count else { throw ProjectValidationError.invalid("Duplicate reviewed policy IDs") }
        for policy in policies {
            try nonempty(policy.id, "Policy ID"); try nonempty(policy.alertIdentifier, "Alert identity"); try nonempty(policy.exactContext, "Exact alert context")
            guard policy.bundleIdentifier == app.bundleIdentifier, !policy.buttons.isEmpty,
                  Set(policy.buttons.map { ($0.identifier ?? "") + "|" + $0.label }).count == policy.buttons.count else { throw ProjectValidationError.invalid("Reviewed policy must match app and contain unique complete buttons") }
            for button in policy.buttons { try nonempty(button.label, "Button label") }
        }
        for category in categories {
            try unique(category.id); try nonempty(category.name, "Category name")
            for suite in category.suites {
                try unique(suite.id); try nonempty(suite.name, "Suite name")
                for b in suite.setup + suite.teardown { try block(b) }
                for test in suite.tests {
                    try unique(test.id); try nonempty(test.name, "Test name"); try positive(test.timeoutSeconds, "Test timeout")
                    if let policy = test.goalAssessmentPolicy {
                        try positive(policy.timeoutSeconds, "Goal assessment timeout")
                        guard policy.timeoutSeconds <= 120, policy.minimumConfidence.isFinite, (0...1).contains(policy.minimumConfidence) else { throw ProjectValidationError.invalid("Invalid goal assessment policy") }
                    }
                    guard (0...100).contains(recoveryPolicy(for: test).maximumActions) else { throw ProjectValidationError.invalid("Maximum recovery actions must be between 0 and 100.") }
                    guard (0...100).contains(recoveryPolicy(for: test).maximumEscapes) else { throw ProjectValidationError.invalid("Maximum escapes must be between 0 and 100.") }
                    guard (0...100).contains(recoveryPolicy(for: test).maximumUnresolvedSteps) else { throw ProjectValidationError.invalid("Maximum unresolved steps must be between 0 and 100.") }
                    guard recoveryPolicy(for: test).minimumConfidence.isFinite, (0...1).contains(recoveryPolicy(for: test).minimumConfidence) else { throw ProjectValidationError.invalid("Minimum confidence must be a finite number between 0 and 1.") }
                    try positive(recoveryPolicy(for: test).timeoutSeconds, "Recovery timeout")
                    guard (0...10).contains(recoveryPolicy(for: test).maximumRecaptures), recoveryPolicy(for: test).maximumCaptureAge.isFinite,
                          recoveryPolicy(for: test).maximumCaptureAge > 0, recoveryPolicy(for: test).maximumCaptureAge <= 8,
                          Set(recoveryPolicy(for: test).knownInterruptionPolicies).count == recoveryPolicy(for: test).knownInterruptionPolicies.count,
                          recoveryPolicy(for: test).knownInterruptionPolicies.allSatisfy({ id in (reviewedAlertPolicies ?? []).contains { $0.id == id } }) else {
                        throw ProjectValidationError.invalid("Recovery requires bounded freshness/recapture limits and known reviewed policy IDs.")
                    }
                    if test.effectiveExecutionMode == .scripted {
                        for a in test.preconditions + test.assertions { try assertion(a) }
                        for b in test.blocks { try block(b) }
                    } else {
                        guard test.goal.count <= 8000, test.successCriteria.count <= 8000 else {
                            throw ProjectValidationError.invalid("Goal and success description must be at most 8,000 characters.")
                        }
                        for item in test.assertions {
                            if case .imageMatches = item { try assertion(item) }
                        }
                        // Preserve older scripted definitions when switching
                        // modes, without making their targets part of a goal run.
                        for b in test.blocks { try unique(b.id) }
                    }
                }
            }
        }
    }
}

/// Canonical definitions live in a single diffable JSON document. Artifacts remain alongside it.
public struct ProjectBundleStore: Sendable {
    public init() {}
    public func save(_ project: TestProject, to directory: URL) throws {
        try project.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for child in ["references", "runs"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(child, isDirectory: true), withIntermediateDirectories: true)
        }
        try data.write(to: directory.appendingPathComponent("project.json"), options: .atomic)
    }
    public func load(from directory: URL) throws -> TestProject {
        let file = directory.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ProjectValidationError.invalid("Selected folder is not a testing project (missing project.json). Choose a .uitestproject folder, or use New Testing Project… then Save to create one.")
        }
        let data = try Data(contentsOf: file)
        struct Header: Decodable { let schemaVersion: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.schemaVersion == TestProject.currentSchemaVersion else { throw ProjectValidationError.unsupportedVersion(header.schemaVersion) }
        let project = try JSONDecoder().decode(TestProject.self, from: data)
        try project.validate()
        return project
    }
}
