import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ProjectDomain
import SimulatorControl
import RunnerCore
import ModelProviders

@MainActor @Observable final class WorkspaceModel {
    let run = RunWorkspace()
    var showingRun = false
    var showingTestInspector = false
    var runSet: Set<UUID> = []
    var project: TestProject?
    var bundleURL: URL?
    var selection: UUID?
    var selectedBlockID: UUID?
    var error: String?
    var isDirty = false
    var showingDependencies = false
    var showingExport = false
    var showingRecovery = false
    var showingSetup = false
    var editingSetup = false
    var busy = false
    var name = "Untitled testing project"
    var path = ""
    var scheme = ""
    var configuration = "Debug"
    var productID = ""
    var deviceID = ""
    var schemes: [String] = []
    var configurations = ["Debug", "Release"]
    var products: [DiscoveredProduct] = []
    var devices: [DiscoveredSimulator] = []
    let discovery = ProjectDiscovery()
    let resources = ProjectResourcesStore()
    var selectedTest: TestCase? { project?.categories.flatMap(\.suites).flatMap(\.tests).first { $0.id == selection } }
    func edit(_ transform: (TestProject) -> TestProject) { guard let project else { return }; self.project = transform(project); isDirty = true }
    func updateTest(_ value: TestCase) { edit { $0.updatingTest(value.id) { _ in value } } }
    func updateTest(_ id: UUID, _ transform: (TestCase) -> TestCase) { edit { $0.updatingTest(id, transform) } }
    func test(_ id: UUID) -> TestCase? { project?.categories.flatMap(\.suites).flatMap(\.tests).first { $0.id == id } }
    func report(_ error: Error) { self.error = error.localizedDescription }
    func mayReplace() -> Bool {
        if run.active {
            let alert = NSAlert(); alert.messageText = "A run is still active"; alert.informativeText = "Stop the run and wait for video and companion cleanup before closing or replacing this project."; alert.addButton(withTitle: "Keep Run Open"); alert.runModal(); return false
        }
        guard isDirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to this testing project?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() { case .alertFirstButtonReturn: return save(); case .alertThirdButtonReturn: return true; default: return false }
    }
    func newProject() {
        guard mayReplace() else { return }
        editingSetup = false; name = "Untitled testing project"; path = ""; scheme = ""; configuration = "Debug"; productID = ""; schemes = []; configurations = ["Debug", "Release"]; products = []; showingSetup = true
    }
    func configureProject() {
        guard let project else { return }
        editingSetup = true; name = project.name; path = project.app.projectPath
        if !path.hasPrefix("/"), let bundleURL { path = bundleURL.appendingPathComponent(path).standardizedFileURL.path }
        scheme = project.app.scheme; configuration = project.app.configuration; deviceID = project.simulator.deviceID; products = []; productID = ""; showingSetup = true
        Task { busy = true; defer { busy = false }; do { let info = try await discovery.container(path: path); schemes = info.schemes; configurations = info.configurations ?? ["Debug", "Release"]; try await refreshProducts() } catch { report(error) } }
    }
    func open() {
        guard mayReplace() else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }
    func load(_ url: URL) {
        do {
            let definitionURL = url.appendingPathComponent("project.json")
            guard FileManager.default.fileExists(atPath: definitionURL.path) else {
                throw ProjectValidationError.invalid("Selected folder is not a testing project (missing project.json). Choose a .uitestproject folder, or use New Testing Project… then Save to create one.")
            }
            let migration = try ProjectMigration.preview(data: Data(contentsOf: definitionURL))
            if migration.sourceVersion != TestProject.currentSchemaVersion {
                let alert = NSAlert(); alert.messageText = "Migrate testing project to format 2?"
                alert.informativeText = migration.changes.joined(separator: "\n\n")
                alert.addButton(withTitle: "Migrate This Project"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try migration.commit(to: url)
            }
            let opened = try ProjectBundleStore().load(from: url)
            try resources.load(projectID: opened.id, base: url)
            run.resetView()
            project = opened; bundleURL = url; selection = opened.categories.first?.suites.first?.tests.first?.id; isDirty = false; showingRun = false; showingTestInspector = false; runSet = []; run.refreshHistory(base: url); run.indexProject(opened, at: url)
        } catch { report(error) }
    }
    @discardableResult func save() -> Bool {
        guard let project else { return false }
        var target = bundleURL
        if target == nil {
            let panel = NSSavePanel(); panel.nameFieldStringValue = project.name + ".uitestproject"; panel.canCreateDirectories = true
            guard panel.runModal() == .OK else { return false }; target = panel.url
        }
        guard let target else { return false }
        do { try ProjectBundleStore().save(project, to: target); bundleURL = target; try resources.attach(projectID: project.id, base: target); isDirty = false; run.indexProject(project, at: target); return true } catch { report(error); return false }
    }
    func chooseContainer() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = []
        panel.message = "Choose an .xcodeproj or .xcworkspace"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ["xcodeproj", "xcworkspace"].contains(url.pathExtension.lowercased()) else {
            report(ProjectValidationError.invalid("Choose an .xcodeproj or .xcworkspace file."))
            return
        }
        path = url.path; schemes = []; products = []; scheme = ""; productID = ""
        Task { busy = true; defer { busy = false }; do {
            let info = try await discovery.container(path: path); schemes = info.schemes; configurations = info.configurations ?? ["Debug", "Release"]; scheme = schemes.first ?? ""; configuration = configurations.contains("Debug") ? "Debug" : configurations.first ?? "Debug"
            try await refreshProducts()
        } catch { report(error) } }
    }
    func refreshProducts() async throws {
        let requestedPath = path, requestedScheme = scheme, requestedConfiguration = configuration
        let discovered = try await discovery.products(path: requestedPath, scheme: requestedScheme, configuration: requestedConfiguration)
        guard requestedPath == path, requestedScheme == scheme, requestedConfiguration == configuration else { return }
        products = discovered
        productID = products.first(where: { editingSetup && $0.bundleIdentifier == project?.app.bundleIdentifier && $0.name == project?.app.productName })?.id ?? products.first?.id ?? ""
    }
    func refreshDevices() async { do { devices = try await discovery.simulators(); if !devices.contains(where: { $0.id == deviceID }) { deviceID = devices.first?.id ?? "" } } catch { report(error) } }
    func create() {
        guard let product = products.first(where: { $0.id == productID }) else { return }
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("Companion/Fixtures/OnboardingFixture/OnboardingFixture.xcodeproj"), FileManager.default.fileExists(atPath: resource.path) else {
            error = "The generic automation companion is missing. Build and open HappyPath.app using Scripts/build_mac_app.sh."; return
        }
        let companion = CompanionConfiguration(projectPath: resource.path, scheme: "CompanionService", testIdentifier: "FixtureUITests/CompanionServiceTests/testServe", runnerBundleIdentifier: "dev.agentic.FixtureUITests.xctrunner", resourceLocation: .bundledCompanion)
        let app = AppConfiguration(projectPath: path, scheme: scheme, configuration: configuration, bundleIdentifier: product.bundleIdentifier, productName: product.name, derivedDataPath: editingSetup ? project?.app.derivedDataPath ?? ".build/DerivedData" : ".build/DerivedData", launchArguments: editingSetup ? project?.app.launchArguments ?? [] : [], companion: companion)
        if editingSetup, let project { self.project = project.replacing(name: name, app: app, simulator: .init(deviceID: deviceID)) }
        else {
            let test = TestCase(name: "New test", executionMode: .goal, blocks: [], timeoutSeconds: 600)
            project = TestProject(name: name, app: app, simulator: .init(deviceID: deviceID), categories: [.init(name: "General", suites: [.init(name: "First suite", tests: [test])])])
            run.resetView(); bundleURL = nil; selection = test.id; run.history = []; showingRun = false; showingTestInspector = false; runSet = []; try? resources.load(projectID: project?.id, base: nil)
        }
        isDirty = true; showingSetup = false
    }
    func addCategory() { edit { $0.replacing(categories: $0.categories + [.init(name: "New category", suites: [])]) } }
    func addSuite(_ category: ProjectDomain.Category) { edit { $0.updatingCategory(category.id) { $0.replacing(suites: $0.suites + [.init(name: "New suite", tests: [])]) } } }
    func addTest(_ suite: TestSuite) { let test = TestCase(name: "New test", executionMode: .goal, blocks: [], timeoutSeconds: 600); edit { $0.updatingSuite(suite.id) { $0.replacing(tests: $0.tests + [test]) } }; selection = test.id }
    func addLinearTest(name: String, goal: String, successCriteria: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let criteria = successCriteria.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !goal.isEmpty, name.count <= 8000, goal.count <= 8000,
              criteria.count <= 8000 else { throw ProjectValidationError.invalid("Keep the test name, goal and success description under 8,000 characters.") }
        guard !criteria.isEmpty else { throw LinearImportError.missingCriteria }
        guard let project else { return }
        let test = TestCase(name: name, goal: goal, successCriteria: criteria,
            executionMode: .goal, blocks: [], timeoutSeconds: 600)
        let updated: TestProject
        if let suite = project.categories.flatMap(\.suites).first {
            updated = project.updatingSuite(suite.id) { $0.replacing(tests: $0.tests + [test]) }
        } else {
            updated = project.replacing(categories: project.categories + [
                .init(name: "Imported tickets", suites: [.init(name: "Linear", tests: [test])])
            ])
        }
        try updated.validate()
        self.project = updated
        selection = test.id
        showingRun = false
        isDirty = true
    }
    func generateTitleIfNeeded(_ id: UUID) async {
        guard let projectID = project?.id, let original = test(id),
              original.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || original.name == "New test" else { return }
        do {
            let title = try await AppleTestTitleGenerator().generate(for: original)
            try Task.checkCancellation()
            guard project?.id == projectID, let current = test(id), current.name == original.name,
                  current.goal == original.goal, current.successCriteria == original.successCriteria,
                  current.blocks == original.blocks else { return }
            updateTest(id) { $0.replacing(name: title) }
        } catch { /* Keep the editable placeholder when the model is unavailable. */ }
    }
    func rename(_ id: UUID, name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        edit { $0.updatingCategory(id) { $0.replacing(name: name) }.updatingSuite(id) { $0.replacing(name: name) }.updatingTest(id) { $0.replacing(name: name) } }
    }
    func move(_ id: UUID, by offset: Int) {
        edit { project in project.replacing(categories: project.categories.moving(id, by: offset).map { category in category.replacing(suites: category.suites.moving(id, by: offset).map { $0.replacing(tests: $0.tests.moving(id, by: offset)) }) }) }
    }
    func duplicate(_ id: UUID) {
        edit { project in project.replacing(categories: project.categories.flatMap { category -> [ProjectDomain.Category] in
            if category.id == id { return [category, category.duplicated()] }
            return [category.replacing(suites: category.suites.flatMap { suite -> [TestSuite] in
                if suite.id == id { return [suite, suite.duplicated()] }
                return [suite.replacing(tests: suite.tests.flatMap { $0.id == id ? [$0, $0.duplicated()] : [$0] })]
            })]
        }) }
    }
    func startRun(_ scope: RunSelection) {
        guard !run.active, save(), let project, let bundleURL else { return }
        do {
            try ProjectDependencies(base: bundleURL).validate(project)
            try run.start(project: project, selection: scope, base: bundleURL, savedInputs: resources.goalInputs())
            showingRun = true
        } catch { report(error) }
    }
    func startGoal(_ rawGoal: String, successCriteria rawCriteria: String = "") {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let criteria = rawCriteria.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.count <= 8000 else { error = "Enter a goal of 1–8,000 characters."; return }
        guard criteria.count <= 8000 else { error = "Keep the success description under 8,000 characters."; return }
        guard !run.active, save(), let project, let bundleURL else { return }
        do {
            try ProjectDependencies(base: bundleURL).validate(project)
            let test = TestCase(name: goal, goal: goal, successCriteria: criteria, executionMode: .goal,
                blocks: [], timeoutSeconds: 600)
            let oneOff = TestProject(id: project.id, name: project.name, app: project.app, simulator: project.simulator,
                categories: [.init(name: "Goal run", suites: [.init(name: "Live navigation", tests: [test])])],
                reviewedAlertPolicies: project.reviewedAlertPolicies, defaultRecoveryPolicy: project.defaultRecoveryPolicy)
            try run.start(project: oneOff, selection: .all, base: bundleURL, goalNavigation: true, savedInputs: resources.goalInputs())
            showingRun = true
        } catch { report(error) }
    }
}
