import Foundation
import ProjectDomain

/// A route is a hint for navigation. Every action is rebound to a fresh, safe
/// accessibility candidate and the goal is assessed again after replay.
public struct GoalReplayRoute: Codable, Sendable {
    public struct Identity: Codable, Sendable, Equatable {
        public let projectID: UUID
        public let testID: UUID
        public let appConfiguration: Data
        public let simulatorConfiguration: Data
        public let testConfiguration: Data

        public init(project: TestProject, test: TestCase) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            projectID = project.id
            testID = test.id
            appConfiguration = try encoder.encode(project.app)
            simulatorConfiguration = try encoder.encode(project.simulator)
            testConfiguration = try encoder.encode(test)
        }
    }

    public struct Step: Codable, Sendable, Equatable {
        public let screen: [String]
        public let role: String
        public let identifier: String?
        public let label: String?
        public let originBundleIdentifier: String?

        public init(screen: [String], element: UIElement) {
            self.screen = screen
            role = element.role
            identifier = element.identifier
            label = element.label
            originBundleIdentifier = element.originBundleIdentifier
        }
    }

    public let identity: Identity
    public let steps: [Step]
    public init(identity: Identity, steps: [Step]) {
        self.identity = identity
        self.steps = steps
    }
}

public enum GoalReplaySafety {
    /// App content and actionable controls form the screen precondition. Frames,
    /// capture IDs and dynamic values are excluded so harmless layout changes do
    /// not make a route stale.
    public static func screen(in snapshot: UISnapshot, appBundleID: String) -> [String] {
        snapshot.elements.compactMap { element in
            guard element.originBundleIdentifier == nil || element.originBundleIdentifier == appBundleID,
                  ["button", "link", "cell", "staticText"].contains(element.role),
                  let label = element.label, !label.isEmpty else { return nil }
            return "\(element.role):\(element.identifier ?? ""):\(label)"
        }
    }

    public static func candidate(for step: GoalReplayRoute.Step, in snapshot: UISnapshot,
                                 appBundleID: String) -> GoalNavigationCandidate? {
        guard step.screen == screen(in: snapshot, appBundleID: appBundleID),
              !snapshot.elements.contains(where: {
                  let origin = $0.originBundleIdentifier
                  return origin != nil && origin != appBundleID &&
                      (["button", "sheet", "alert"].contains($0.role) || $0.containingAlertContext != nil)
              }) else { return nil }
        let matches = GoalNavigationSafety.candidates(in: snapshot, appBundleID: appBundleID).filter { candidate in
            guard let index = candidate.elementIndex else { return false }
            let element = snapshot.elements[index]
            return element.role == step.role && element.identifier == step.identifier &&
                element.label == step.label && element.originBundleIdentifier == step.originBundleIdentifier
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

public protocol GoalReplayStoring: Sendable {
    func load(_ identity: GoalReplayRoute.Identity) async -> GoalReplayRoute?
    func save(_ route: GoalReplayRoute) async throws
}

public actor GoalReplayStore: GoalReplayStoring {
    private let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgenticUITestingSpike/VerifiedGoalRoutes", isDirectory: true)
    }
    private func location(_ identity: GoalReplayRoute.Identity) -> URL {
        directory.appendingPathComponent("\(identity.projectID.uuidString)-\(identity.testID.uuidString).json")
    }
    public func load(_ identity: GoalReplayRoute.Identity) -> GoalReplayRoute? {
        guard let data = try? Data(contentsOf: location(identity)),
              let route = try? JSONDecoder().decode(GoalReplayRoute.self, from: data),
              route.identity == identity, !route.steps.isEmpty, route.steps.count <= 80 else { return nil }
        return route
    }
    public func save(_ route: GoalReplayRoute) throws {
        guard !route.steps.isEmpty, route.steps.count <= 80 else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(route)
        try data.write(to: location(route.identity), options: .atomic)
    }
}
