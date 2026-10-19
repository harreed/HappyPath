import Foundation
import Darwin
import ProjectDomain

func writeAcceptanceProjects(at directory: URL, repository: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func canonical(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw POSIXError(.init(rawValue: errno) ?? .ENOENT) }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }
    let projectDirectory = try canonical(directory).appendingPathComponent("Fixture.uitestproject")
    let repository = try canonical(repository)
    func relativePath(to target: URL) -> String {
        let base = projectDirectory.pathComponents
        let destination = target.standardizedFileURL.pathComponents
        var shared = 0
        while shared < min(base.count, destination.count), base[shared] == destination[shared] { shared += 1 }
        return (Array(repeating: "..", count: base.count - shared) + Array(destination.dropFirst(shared))).joined(separator: "/")
    }
    let companion = CompanionConfiguration(projectPath: relativePath(to: repository.appendingPathComponent("Fixtures/OnboardingFixture/OnboardingFixture.xcodeproj")),
        scheme: "CompanionService", testIdentifier: "FixtureUITests/CompanionServiceTests/testServe",
        runnerBundleIdentifier: "dev.agentic.FixtureUITests.xctrunner")
    let simulator = SimulatorProfile(deviceID: "BAF8410A-432D-4BEF-BC0A-4F50B7A50C5A")
    func fixture(_ arguments: [String] = []) -> AppConfiguration {
        .init(projectPath: companion.projectPath, scheme: "OnboardingFixture", bundleIdentifier: "dev.agentic.OnboardingFixture",
              derivedDataPath: relativePath(to: repository.appendingPathComponent("phase1-runs/DerivedDataFixture")),
              launchArguments: arguments, companion: companion)
    }
    func block(_ title: String, _ action: BlockAction) -> TestBlock { .init(title: title, action: action) }
    let name = ProjectDomain.TestCase(name: "Enter name and dismiss known reminder", blocks: [
        block("Fresh launch", .relaunch),
        block("Wait for name", .wait(.exists(.identifier("onboarding.name")))),
        block("Focus name", .tap(targets: [.identifier("onboarding.name")])),
        block("Enter Ada", .typeText("Ada Phase One", targets: [.identifier("onboarding.name")])),
        block("Verify entered name", .assertion(.valueEquals(.identifier("onboarding.name"), "Ada Phase One"))),
        block("Continue", .tap(targets: [.identifier("onboarding.continue")])),
        block("Verify reminder", .assertion(.exists(.identifier("fixture.alert.notNow")))),
        block("Dismiss known reminder", .tap(targets: [.identifier("fixture.alert.notNow")])),
    ], assertions: [.textVisible("Hello, Ada Phase One"), .doesNotExist(.identifier("fixture.alert.notNow"))])
    let fresh = ProjectDomain.TestCase(name: "Relaunch resets the form", blocks: [block("Relaunch", .relaunch)],
        assertions: [.exists(.identifier("onboarding.name")), .textVisible("Welcome")])
    let last = ProjectDomain.TestCase(name: "Second category assertion", blocks: [block("Independent launch", .relaunch)], assertions: [.exists(.identifier("onboarding.name"))])
    let project = TestProject(name: "Fixture deterministic acceptance", app: fixture(), simulator: simulator, categories: [
        .init(name: "Onboarding", suites: [.init(name: "Name entry", tests: [name, fresh])]),
        .init(name: "Smoke", suites: [.init(name: "Launch", tests: [last])])
    ])
    try ProjectBundleStore().save(project, to: directory.appendingPathComponent("Fixture.uitestproject"))
    let scroll = TestProject(name: "Fixture scrolling", app: fixture(["--scroll-probe"]), simulator: simulator,
        categories: [.init(name: "Scrolling", suites: [.init(name: "Scroll view", tests: [
            .init(name: "Swipe the real scroll view", blocks: [
                block("Swipe up", .swipe(.up, targets: [.identifier("fixture.scroll")])),
                block("Swipe application", .swipe(.up, targets: []))
            ], assertions: [.exists(.identifier("fixture.scroll.target"))])
        ])])])
    try ProjectBundleStore().save(scroll, to: directory.appendingPathComponent("Scroll.uitestproject"))
}
