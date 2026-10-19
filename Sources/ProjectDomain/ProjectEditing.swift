import Foundation

/// Pure value transformations. The editor never mutates a definition owned by a run.
public extension TestProject {
    func replacing(name: String? = nil, app: AppConfiguration? = nil, simulator: SimulatorProfile? = nil, categories: [Category]? = nil, reviewedAlertPolicies: [ReviewedAlertPolicy]? = nil, defaultRecoveryPolicy: RecoveryPolicy? = nil) -> Self {
        .init(schemaVersion: schemaVersion, id: id, name: name ?? self.name, app: app ?? self.app, simulator: simulator ?? self.simulator, categories: categories ?? self.categories, reviewedAlertPolicies: reviewedAlertPolicies ?? self.reviewedAlertPolicies, defaultRecoveryPolicy: defaultRecoveryPolicy ?? self.defaultRecoveryPolicy)
    }
    func updatingCategory(_ id: UUID, _ edit: (Category) -> Category) -> Self {
        replacing(categories: categories.map { $0.id == id ? edit($0) : $0 })
    }
    func updatingSuite(_ id: UUID, _ edit: (TestSuite) -> TestSuite) -> Self {
        replacing(categories: categories.map { $0.replacing(suites: $0.suites.map { $0.id == id ? edit($0) : $0 }) })
    }
    func updatingTest(_ id: UUID, _ edit: (TestCase) -> TestCase) -> Self {
        replacing(categories: categories.map { $0.replacing(suites: $0.suites.map { $0.replacing(tests: $0.tests.map { $0.id == id ? edit($0) : $0 }) }) })
    }
    func deleting(_ id: UUID) -> Self {
        replacing(categories: categories.filter { $0.id != id }.map { $0.replacing(suites: $0.suites.filter { $0.id != id }.map { $0.replacing(tests: $0.tests.filter { $0.id != id }) }) })
    }
}
public extension Category {
    func replacing(name: String? = nil, suites: [TestSuite]? = nil) -> Self { .init(id: id, name: name ?? self.name, suites: suites ?? self.suites) }
    func duplicated() -> Self { .init(name: name + " copy", suites: suites.map { $0.duplicated() }) }
}
public extension TestSuite {
    func replacing(name: String? = nil, tests: [TestCase]? = nil) -> Self { .init(id: id, name: name ?? self.name, setup: setup, tests: tests ?? self.tests, teardown: teardown) }
    func duplicated() -> Self { .init(name: name + " copy", setup: setup.map { $0.duplicated() }, tests: tests.map { $0.duplicated() }, teardown: teardown.map { $0.duplicated() }) }
}
public extension TestCase {
    func updatingBlock(_ id: UUID, _ edit: (TestBlock) -> TestBlock) -> Self {
        replacing(blocks: blocks.map { $0.id == id ? edit($0) : $0 })
    }
    func replacing(name: String? = nil, goal: String? = nil, successCriteria: String? = nil, executionMode: TestExecutionMode? = nil, blocks: [TestBlock]? = nil, preconditions: [AssertionDefinition]? = nil, assertions: [AssertionDefinition]? = nil, recoveryPolicy: RecoveryPolicy? = nil, timeoutSeconds: Double? = nil, useProjectRecoveryPolicy: Bool? = nil, goalAssessmentPolicy: GoalAssessmentPolicy? = nil, startingState: TestStartingState? = nil) -> Self {
        .init(id: id, name: name ?? self.name, goal: goal ?? self.goal, successCriteria: successCriteria ?? self.successCriteria,
              executionMode: executionMode ?? self.executionMode, preconditions: preconditions ?? self.preconditions,
              blocks: blocks ?? self.blocks, assertions: assertions ?? self.assertions, recoveryPolicy: recoveryPolicy ?? self.recoveryPolicy,
              timeoutSeconds: timeoutSeconds ?? self.timeoutSeconds, useProjectRecoveryPolicy: useProjectRecoveryPolicy ?? (recoveryPolicy == nil ? self.useProjectRecoveryPolicy ?? false : false), goalAssessmentPolicy: goalAssessmentPolicy ?? self.goalAssessmentPolicy,
              startingState: startingState ?? self.startingState)
    }
    func duplicated() -> Self { .init(name: name + " copy", goal: goal, successCriteria: successCriteria, executionMode: executionMode,
                                      preconditions: preconditions, blocks: blocks.map { $0.duplicated() }, assertions: assertions,
                                      recoveryPolicy: recoveryPolicy, timeoutSeconds: timeoutSeconds,
                                      useProjectRecoveryPolicy: useProjectRecoveryPolicy ?? false, goalAssessmentPolicy: goalAssessmentPolicy,
                                      startingState: startingState) }
}
public extension TestBlock {
    func replacing(title: String? = nil, action: BlockAction? = nil, enabled: Bool? = nil, breakpoint: Bool? = nil, retryPolicy: RetryPolicy? = nil) -> Self {
        .init(id: id, title: title ?? self.title, action: action ?? self.action, enabled: enabled ?? self.enabled, breakpoint: breakpoint ?? self.breakpoint, retryPolicy: retryPolicy ?? self.retryPolicy)
    }
    func duplicated() -> Self { .init(title: title, action: action, enabled: enabled, breakpoint: breakpoint, retryPolicy: retryPolicy) }
}
public extension Array where Element: Identifiable {
    /// Moves the dragged item before the destination, preserving every identity.
    func moving(_ id: Element.ID, before destination: Element.ID?) -> Self {
        guard id != destination, let source = firstIndex(where: { $0.id == id }) else { return self }
        var copy = self; let item = copy.remove(at: source)
        if let destination {
            guard let index = copy.firstIndex(where: { $0.id == destination }) else { return self }
            copy.insert(item, at: index)
        } else { copy.append(item) }
        return copy
    }
    /// Move within canonical sibling order; invalid IDs and boundaries leave it unchanged.
    func moving(_ id: Element.ID, by offset: Int) -> Self {
        guard let index = firstIndex(where: { $0.id == id }), indices.contains(index + offset) else { return self }
        var copy = self; let item = copy.remove(at: index); copy.insert(item, at: index + offset); return copy
    }
}

public extension RecoveryPolicy {
    func replacing(maximumActions: Int? = nil, timeoutSeconds: Double? = nil, minimumConfidence: Double? = nil,
                   mode: RecoveryMode? = nil, allowTextFallback: Bool? = nil, allowSystemDismiss: Bool? = nil, knownInterruptionPolicies: [String]? = nil,
                   maximumRecaptures: Int? = nil, maximumCaptureAge: Double? = nil, candidateProvider: CandidateProvider? = nil,
                   allowSafeEscapes: Bool? = nil, allowProgressControls: Bool? = nil, maximumEscapes: Int? = nil, maximumUnresolvedSteps: Int? = nil) -> Self {
        .init(maximumActions: maximumActions ?? self.maximumActions, timeoutSeconds: timeoutSeconds ?? self.timeoutSeconds,
              minimumConfidence: minimumConfidence ?? self.minimumConfidence, allowTextFallback: allowTextFallback ?? self.allowTextFallback,
              allowSystemDismiss: allowSystemDismiss ?? self.allowSystemDismiss,
              knownInterruptionPolicies: knownInterruptionPolicies ?? self.knownInterruptionPolicies,
              maximumRecaptures: maximumRecaptures ?? self.maximumRecaptures, maximumCaptureAge: maximumCaptureAge ?? self.maximumCaptureAge,
              mode: mode ?? self.mode, candidateProvider: candidateProvider ?? self.candidateProvider,
              allowSafeEscapes: allowSafeEscapes ?? self.allowSafeEscapes, allowProgressControls: allowProgressControls ?? self.allowProgressControls,
              maximumEscapes: maximumEscapes ?? self.maximumEscapes, maximumUnresolvedSteps: maximumUnresolvedSteps ?? self.maximumUnresolvedSteps)
    }
}
