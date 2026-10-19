import Foundation

public struct AppConfiguration: Codable, Sendable, Equatable {
    public let projectPath: String
    public let scheme: String
    public let configuration: String
    public let bundleIdentifier: String
    public let productName: String
    public let derivedDataPath: String
    public let launchArguments: [String]
    public let companion: CompanionConfiguration?
    public init(projectPath: String, scheme: String, configuration: String = "Debug", bundleIdentifier: String, productName: String? = nil, derivedDataPath: String = ".build/DerivedData", launchArguments: [String] = [], companion: CompanionConfiguration? = nil) {
        self.projectPath = projectPath; self.scheme = scheme; self.configuration = configuration; self.bundleIdentifier = bundleIdentifier
        self.productName = productName ?? scheme; self.derivedDataPath = derivedDataPath; self.launchArguments = launchArguments; self.companion = companion
    }
}

public struct CompanionConfiguration: Codable, Sendable, Equatable {
    public enum ResourceLocation: String, Codable, Sendable { case projectPath, bundledCompanion }
    public let resourceLocation: ResourceLocation?
    public let projectPath: String
    public let scheme: String
    public let testIdentifier: String
    public let runnerBundleIdentifier: String
    public let mailboxRelativePath: String
    public init(projectPath: String, scheme: String, testIdentifier: String, runnerBundleIdentifier: String, mailboxRelativePath: String = "Documents/CompanionMailbox", resourceLocation: ResourceLocation? = nil) {
        self.resourceLocation = resourceLocation
        self.projectPath = projectPath; self.scheme = scheme; self.testIdentifier = testIdentifier; self.runnerBundleIdentifier = runnerBundleIdentifier; self.mailboxRelativePath = mailboxRelativePath
    }
}

public struct SimulatorProfile: Codable, Sendable, Equatable {
    public let deviceID: String
    public init(deviceID: String) { self.deviceID = deviceID }
}

public enum TargetStrategy: Codable, Sendable, Equatable {
    case identifier(String)
    case semantic(role: String?, label: String?, value: String?)
    case text(String)
}

public enum AssertionDefinition: Codable, Sendable, Equatable {
    case exists(TargetStrategy)
    case doesNotExist(TargetStrategy)
    case valueEquals(TargetStrategy, String)
    case valueContains(TargetStrategy, String)
    case textVisible(String)
    /// Approved project screenshot in references/<referenceID>.png.
    case imageMatches(referenceID: UUID, referenceSHA256: String,
                      maximumMeanChannelDifference: Double, maximumChangedPixelFraction: Double)
}

public enum SwipeDirection: String, Codable, Sendable { case up, down, left, right }

/// Simulator-only state changes. Unsupported commands fail the run explicitly.
public enum DeviceAction: Codable, Sendable, Equatable {
    case openURL(String)
    case setLocation(latitude: Double, longitude: Double)
    case clearLocation
    case permission(service: SimulatorPermission, decision: PermissionDecision)
    /// Sends Home, keeps the app in the background for the given interval, then activates it.
    case background(seconds: Double)

    public func validate() throws {
        switch self {
        case .openURL(let value):
            guard let url = URLComponents(string: value), let scheme = url.scheme,
                  !scheme.isEmpty, !value.contains(where: \.isNewline) else {
                throw DeviceActionValidationError.invalidURL
            }
        case .setLocation(let latitude, let longitude):
            guard latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw DeviceActionValidationError.invalidLocation
            }
        case .background(let seconds):
            guard seconds.isFinite, (0...20).contains(seconds) else {
                throw DeviceActionValidationError.invalidBackgroundDuration
            }
        case .clearLocation, .permission: break
        }
    }
}

public enum DeviceActionValidationError: Error, LocalizedError, Equatable {
    case invalidURL, invalidLocation, invalidBackgroundDuration
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an absolute deep link or web URL with a scheme."
        case .invalidLocation: "Latitude must be between -90 and 90 and longitude between -180 and 180."
        case .invalidBackgroundDuration: "Background duration must be between 0 and 20 seconds."
        }
    }
}

public enum SimulatorPermission: String, Codable, Sendable, CaseIterable {
    case calendar, contacts, location, photos, microphone, motion, reminders
    case locationAlways = "location-always"
    case photosAdd = "photos-add"
    case mediaLibrary = "media-library"
}

public enum PermissionDecision: String, Codable, Sendable, CaseIterable {
    case grant, revoke, reset
}

public enum BlockAction: Codable, Sendable, Equatable {
    case tap(targets: [TargetStrategy])
    case typeText(String, targets: [TargetStrategy])
    case swipe(SwipeDirection, targets: [TargetStrategy])
    case wait(AssertionDefinition)
    case relaunch
    case assertion(AssertionDefinition)
    case device(DeviceAction)
}

public struct RetryPolicy: Codable, Sendable, Equatable {
    public let maximumAttempts: Int
    public let delaySeconds: Double
    public let timeoutSeconds: Double
    public init(maximumAttempts: Int = 1, delaySeconds: Double = 0.2, timeoutSeconds: Double = 10) {
        self.maximumAttempts = maximumAttempts; self.delaySeconds = delaySeconds; self.timeoutSeconds = timeoutSeconds
    }
}

public enum RecoveryMode: String, Codable, Sendable { case knownAutomatic, safeInferred, askFail }
public struct ReviewedAlertButton: Codable, Sendable, Equatable {
    public enum Risk: String, Codable, Sendable { case nonDestructiveDismissal, destructive, unknown }
    public let identifier: String?
    public let label: String
    public let risk: Risk
    public init(identifier: String?, label: String, risk: Risk) { self.identifier = identifier; self.label = label; self.risk = risk }
}
/// Project author explicitly reviews the exact prompt and complete action set.
public struct ReviewedAlertPolicy: Codable, Sendable, Equatable {
    public let id: String
    public let bundleIdentifier: String
    public let alertIdentifier: String
    public let exactContext: String
    public let buttons: [ReviewedAlertButton]
    public let automaticButtonIdentifier: String?
    public let automaticButtonLabel: String?
    public init(id: String, bundleIdentifier: String, alertIdentifier: String, exactContext: String,
                buttons: [ReviewedAlertButton], automaticButtonIdentifier: String? = nil, automaticButtonLabel: String? = nil) {
        self.automaticButtonLabel = automaticButtonLabel
        self.id = id; self.bundleIdentifier = bundleIdentifier; self.alertIdentifier = alertIdentifier
        self.exactContext = exactContext; self.buttons = buttons; self.automaticButtonIdentifier = automaticButtonIdentifier
    }
}

/// Candidate choice defaults to hosted Jev and falls back to the local
/// reviewed policy when Jev is unavailable. Automatic mutation still requires
/// each test's local policy, confidence and freshness gates.
public enum CandidateProvider: String, Codable, Sendable { case local, jev }
public struct RecoveryPolicy: Codable, Sendable, Equatable {
    public let candidateProvider: CandidateProvider
    public let mode: RecoveryMode
    public let maximumActions: Int
    public let timeoutSeconds: Double
    public let minimumConfidence: Double
    public let allowTextFallback: Bool
    /// Legacy persisted key; now controls automatic SpringBoard prompt choices.
    public let allowSystemDismiss: Bool
    public let knownInterruptionPolicies: [String]
    public let maximumRecaptures: Int
    public let maximumCaptureAge: Double
    /// Safe escapes clear an obstruction (Close/Back/Not Now) or advance an
    /// unambiguous progress control when an authored step cannot proceed.
    /// They are bounded, evidence-recorded and verify observable progress.
    public let allowSafeEscapes: Bool
    public let allowProgressControls: Bool
    public let maximumEscapes: Int
    /// Consecutive unresolved steps the runner may carry forward before it
    /// declares the run off course and stops. Zero keeps fail-fast semantics.
    public let maximumUnresolvedSteps: Int
    public init(maximumActions: Int = 0, timeoutSeconds: Double = 10, minimumConfidence: Double = 0.9,
                allowTextFallback: Bool = false, allowSystemDismiss: Bool = true, knownInterruptionPolicies: [String] = [],
                maximumRecaptures: Int = 2, maximumCaptureAge: Double = 8, mode: RecoveryMode = .askFail, candidateProvider: CandidateProvider = .jev,
                allowSafeEscapes: Bool = true, allowProgressControls: Bool = true, maximumEscapes: Int = 2, maximumUnresolvedSteps: Int = 2) {
        self.candidateProvider = candidateProvider
        self.mode = mode
        self.maximumActions = maximumActions; self.timeoutSeconds = timeoutSeconds; self.minimumConfidence = minimumConfidence
        self.allowTextFallback = allowTextFallback; self.allowSystemDismiss = allowSystemDismiss; self.knownInterruptionPolicies = knownInterruptionPolicies
        self.maximumRecaptures = maximumRecaptures; self.maximumCaptureAge = maximumCaptureAge
        self.allowSafeEscapes = allowSafeEscapes; self.allowProgressControls = allowProgressControls
        self.maximumEscapes = maximumEscapes; self.maximumUnresolvedSteps = maximumUnresolvedSteps
    }
    private enum CodingKeys: String, CodingKey { case candidateProvider, mode, maximumActions, timeoutSeconds, minimumConfidence, allowTextFallback, allowSystemDismiss, knownInterruptionPolicies, maximumRecaptures, maximumCaptureAge, allowSafeEscapes, allowProgressControls, maximumEscapes, maximumUnresolvedSteps }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(maximumActions: try c.decode(Int.self, forKey: .maximumActions), timeoutSeconds: try c.decode(Double.self, forKey: .timeoutSeconds),
                  minimumConfidence: try c.decode(Double.self, forKey: .minimumConfidence),
                  allowTextFallback: try c.decodeIfPresent(Bool.self, forKey: .allowTextFallback) ?? false,
                  allowSystemDismiss: try c.decodeIfPresent(Bool.self, forKey: .allowSystemDismiss) ?? true,
                  knownInterruptionPolicies: try c.decodeIfPresent([String].self, forKey: .knownInterruptionPolicies) ?? [],
                  maximumRecaptures: try c.decodeIfPresent(Int.self, forKey: .maximumRecaptures) ?? 2,
                  maximumCaptureAge: try c.decodeIfPresent(Double.self, forKey: .maximumCaptureAge) ?? 8,
                  mode: try c.decodeIfPresent(RecoveryMode.self, forKey: .mode) ?? .askFail,
                  candidateProvider: try c.decodeIfPresent(CandidateProvider.self, forKey: .candidateProvider) ?? .jev,
                  allowSafeEscapes: try c.decodeIfPresent(Bool.self, forKey: .allowSafeEscapes) ?? true,
                  allowProgressControls: try c.decodeIfPresent(Bool.self, forKey: .allowProgressControls) ?? true,
                  maximumEscapes: try c.decodeIfPresent(Int.self, forKey: .maximumEscapes) ?? 2,
                  maximumUnresolvedSteps: try c.decodeIfPresent(Int.self, forKey: .maximumUnresolvedSteps) ?? 2)
    }
}

public struct TestBlock: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let action: BlockAction
    public let enabled: Bool
    public let breakpoint: Bool
    public let retryPolicy: RetryPolicy
    public init(id: UUID = UUID(), title: String, action: BlockAction, enabled: Bool = true, breakpoint: Bool = false, retryPolicy: RetryPolicy = .init()) {
        self.id = id; self.title = title; self.action = action; self.enabled = enabled; self.breakpoint = breakpoint; self.retryPolicy = retryPolicy
    }
}

public struct GoalAssessmentPolicy: Codable, Sendable, Equatable {
    public enum EvidenceRequirement: String, Codable, Sendable { case semantic, ocr, image }
    public let requirement: EvidenceRequirement
    public let minimumConfidence: Double
    public let timeoutSeconds: Double
    public init(requirement: EvidenceRequirement = .semantic, minimumConfidence: Double = 0.8, timeoutSeconds: Double = 45) {
        self.requirement = requirement; self.minimumConfidence = minimumConfidence; self.timeoutSeconds = timeoutSeconds
    }
}

public enum TestExecutionMode: String, Codable, Sendable, Hashable { case goal, scripted }

/// Applied before this test starts. All defaults preserve the current Simulator state.
public struct TestStartingState: Codable, Sendable, Equatable {
    public enum AppData: String, Codable, Sendable, CaseIterable { case preserve, reinstall }
    public enum Permissions: String, Codable, Sendable, CaseIterable { case preserve, reset }
    public enum Appearance: String, Codable, Sendable, CaseIterable { case unchanged, light, dark }
    public enum Keychain: String, Codable, Sendable, CaseIterable { case preserve, resetSimulator }
    public enum Location: Codable, Sendable, Equatable {
        case unchanged
        case clear
        case coordinate(latitude: Double, longitude: Double)
    }
    public let appData: AppData
    public let permissions: Permissions
    public let appearance: Appearance
    public let keychain: Keychain
    public let location: Location
    public init(appData: AppData = .preserve, permissions: Permissions = .preserve,
                appearance: Appearance = .unchanged, keychain: Keychain = .preserve,
                location: Location = .unchanged) {
        self.appData = appData; self.permissions = permissions; self.appearance = appearance; self.keychain = keychain
        self.location = location
    }
    public var isDefault: Bool { self == .init() }
    private enum CodingKeys: String, CodingKey { case appData, permissions, appearance, keychain, location }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(appData: try c.decodeIfPresent(AppData.self, forKey: .appData) ?? .preserve,
                  permissions: try c.decodeIfPresent(Permissions.self, forKey: .permissions) ?? .preserve,
                  appearance: try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .unchanged,
                  keychain: try c.decodeIfPresent(Keychain.self, forKey: .keychain) ?? .preserve,
                  location: try c.decodeIfPresent(Location.self, forKey: .location) ?? .unchanged)
    }
}

public struct TestCase: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let goal: String
    public let successCriteria: String
    /// Missing on older projects, which retain their scripted behavior.
    public let executionMode: TestExecutionMode?
    public var effectiveExecutionMode: TestExecutionMode { executionMode ?? .scripted }
    public let goalAssessmentPolicy: GoalAssessmentPolicy?
    public let startingState: TestStartingState
    public let preconditions: [AssertionDefinition]
    public let blocks: [TestBlock]
    public let assertions: [AssertionDefinition]
    public let recoveryPolicy: RecoveryPolicy
    public let useProjectRecoveryPolicy: Bool?
    public let timeoutSeconds: Double
    public init(id: UUID = UUID(), name: String, goal: String = "", successCriteria: String = "", executionMode: TestExecutionMode? = nil, preconditions: [AssertionDefinition] = [], blocks: [TestBlock], assertions: [AssertionDefinition] = [], recoveryPolicy: RecoveryPolicy = .init(), timeoutSeconds: Double = 120, useProjectRecoveryPolicy: Bool = false, goalAssessmentPolicy: GoalAssessmentPolicy? = nil, startingState: TestStartingState = .init()) {
        self.goalAssessmentPolicy = goalAssessmentPolicy
        self.startingState = startingState
        self.useProjectRecoveryPolicy = useProjectRecoveryPolicy
        self.id = id; self.name = name; self.goal = goal; self.successCriteria = successCriteria; self.executionMode = executionMode
        self.preconditions = preconditions; self.blocks = blocks; self.assertions = assertions; self.recoveryPolicy = recoveryPolicy; self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey { case id, name, goal, successCriteria, executionMode, goalAssessmentPolicy, startingState, preconditions, blocks, assertions, recoveryPolicy, useProjectRecoveryPolicy, timeoutSeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  goal: try c.decodeIfPresent(String.self, forKey: .goal) ?? "",
                  successCriteria: try c.decodeIfPresent(String.self, forKey: .successCriteria) ?? "",
                  executionMode: try c.decodeIfPresent(TestExecutionMode.self, forKey: .executionMode),
                  preconditions: try c.decodeIfPresent([AssertionDefinition].self, forKey: .preconditions) ?? [],
                  blocks: try c.decode([TestBlock].self, forKey: .blocks),
                  assertions: try c.decodeIfPresent([AssertionDefinition].self, forKey: .assertions) ?? [],
                  recoveryPolicy: try c.decodeIfPresent(RecoveryPolicy.self, forKey: .recoveryPolicy) ?? .init(),
                  timeoutSeconds: try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 120,
                  useProjectRecoveryPolicy: try c.decodeIfPresent(Bool.self, forKey: .useProjectRecoveryPolicy) ?? false,
                  goalAssessmentPolicy: try c.decodeIfPresent(GoalAssessmentPolicy.self, forKey: .goalAssessmentPolicy),
                  startingState: try c.decodeIfPresent(TestStartingState.self, forKey: .startingState) ?? .init())
    }
}

public struct TestSuite: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let setup: [TestBlock]
    public let tests: [TestCase]
    public let teardown: [TestBlock]
    public init(id: UUID = UUID(), name: String, setup: [TestBlock] = [], tests: [TestCase], teardown: [TestBlock] = []) {
        self.id = id; self.name = name; self.setup = setup; self.tests = tests; self.teardown = teardown
    }
}

public struct Category: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let suites: [TestSuite]
    public init(id: UUID = UUID(), name: String, suites: [TestSuite]) { self.id = id; self.name = name; self.suites = suites }
}

public struct TestProject: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 2
    public let schemaVersion: Int
    public let id: UUID
    public let name: String
    public let app: AppConfiguration
    public let simulator: SimulatorProfile
    /// Array order is canonical execution order; UUIDs survive renaming and reordering.
    public let categories: [Category]
    public let reviewedAlertPolicies: [ReviewedAlertPolicy]?
    public let defaultRecoveryPolicy: RecoveryPolicy?
    public init(schemaVersion: Int = Self.currentSchemaVersion, id: UUID = UUID(), name: String, app: AppConfiguration, simulator: SimulatorProfile, categories: [Category], reviewedAlertPolicies: [ReviewedAlertPolicy]? = nil, defaultRecoveryPolicy: RecoveryPolicy? = nil) {
        self.defaultRecoveryPolicy = defaultRecoveryPolicy
        self.reviewedAlertPolicies = reviewedAlertPolicies
        self.schemaVersion = schemaVersion; self.id = id; self.name = name; self.app = app; self.simulator = simulator; self.categories = categories
    }
    public func selectedTests(_ selection: RunSelection) throws -> [SelectedTest] {
        try validate()
        let all = categories.flatMap { category in category.suites.flatMap { suite in suite.tests.map { SelectedTest(categoryID: category.id, suite: suite, test: $0) } } }
        switch selection {
        case .all: return all
        case .test(let id):
            guard all.contains(where: { $0.test.id == id }) else { throw ProjectValidationError.unknownSelection(id) }
            return all.filter { $0.test.id == id }
        case .suite(let id):
            guard categories.contains(where: { $0.suites.contains(where: { $0.id == id }) }) else { throw ProjectValidationError.unknownSelection(id) }
            return all.filter { $0.suite.id == id }
        case .category(let id):
            guard categories.contains(where: { $0.id == id }) else { throw ProjectValidationError.unknownSelection(id) }
            return all.filter { $0.categoryID == id }
        case .selection(let ids):
            for id in ids where !all.contains(where: { $0.test.id == id }) { throw ProjectValidationError.unknownSelection(id) }
            return all.filter { ids.contains($0.test.id) }
        }
    }
}

public enum RunSelection: Codable, Sendable, Equatable {
    case all, test(UUID), suite(UUID), category(UUID), selection(Set<UUID>)
}

public struct SelectedTest: Sendable, Equatable {
    public let categoryID: UUID
    public let suite: TestSuite
    public let test: TestCase
}

public extension TestProject {
    func recoveryPolicy(for test: TestCase) -> RecoveryPolicy {
        if test.effectiveExecutionMode == .goal {
            return defaultRecoveryPolicy ?? .init()
        }
        return test.useProjectRecoveryPolicy == true ? (defaultRecoveryPolicy ?? test.recoveryPolicy) : test.recoveryPolicy
    }
}
