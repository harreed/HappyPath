import SwiftUI
import AppKit
import ProjectDomain

struct ProjectDependencySheet: View {
    @Bindable var model: WorkspaceModel
    @State private var device = ""
    @State private var buildPath = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkbenchSheetHeader(title: "Project dependencies", subtitle: "External application source is referenced, never copied by project export. Relative paths resolve from this project folder.")
            if let project = model.project {
                let resolver = ProjectDependencies(base: model.bundleURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                VStack(alignment: .leading, spacing: 10) {
                    WorkbenchSectionLabel("Xcode application")
                    Text(resolver.resolve(project.app.projectPath).path).font(WorkbenchStyle.infoFont).textSelection(.enabled)
                    Text(FileManager.default.fileExists(atPath: resolver.resolve(project.app.projectPath).path) ? "Available" : "Unresolved — relink required").font(WorkbenchStyle.infoFont).foregroundStyle(FileManager.default.fileExists(atPath: resolver.resolve(project.app.projectPath).path) ? Color.secondary : Color.orange)
                    Button("Relink Xcode Project…") { relink(companion: false) }.workbenchSheetButtons()
                }.frame(maxWidth: .infinity, alignment: .leading).workbenchCard()
                VStack(alignment: .leading, spacing: 10) {
                    WorkbenchSectionLabel("Automation companion")
                    Text(project.app.companion?.resourceLocation == .bundledCompanion ? "Packaged companion from current app installation" : "External companion").font(WorkbenchStyle.infoFont)
                    Text((try? project.app.companion.map { try resolver.companion($0).path }) ?? "Unresolved").font(WorkbenchStyle.infoFont).textSelection(.enabled)
                    HStack { Button("Use Current Packaged Companion") { packaged() }; Button("Relink Custom Companion…") { relink(companion: true) } }.workbenchSheetButtons()
                }.frame(maxWidth: .infinity, alignment: .leading).workbenchCard()
                VStack(alignment: .leading, spacing: 10) {
                    WorkbenchSectionLabel("Build cache")
                    TextField("Build cache path (relative to project)", text: $buildPath)
                    Button("Apply Build Cache Path") { replace(buildPath: buildPath) }.workbenchSheetButtons()
                }.frame(maxWidth: .infinity, alignment: .leading).workbenchCard()
                VStack(alignment: .leading, spacing: 10) {
                    WorkbenchSectionLabel("Simulator")
                    Picker("Simulator", selection: $device) { Text("Select device").tag(""); ForEach(model.devices) { Text("\($0.name) · \($0.runtime)").tag($0.id) } }
                    Text(model.devices.contains { $0.id == project.simulator.deviceID } ? "Saved device available" : "Saved device unavailable — select a replacement").workbenchInfo()
                    Button("Apply Device") { guard !device.isEmpty else { return }; model.edit { $0.replacing(simulator: .init(deviceID: device)) } }.workbenchSheetButtons()
                }.frame(maxWidth: .infinity, alignment: .leading).workbenchCard()
            }
            HStack { Button("Verify Dependencies") { do { if let project = model.project, let base = model.bundleURL { try ProjectDependencies(base: base).validate(project); model.error = "Dependencies available. Simulator availability is checked again before build." } } catch { model.report(error) } }; Spacer(); Button("Save and Close") { if model.save() { model.showingDependencies = false } }.buttonStyle(WorkbenchButtonStyle(prominent: true)) }.workbenchSheetButtons()
        }.padding(WorkbenchStyle.sheetPadding).frame(width: 760).task { device = model.project?.simulator.deviceID ?? ""; buildPath = model.project?.app.derivedDataPath ?? ".build/DerivedData"; await model.refreshDevices() }
    }
    func replace(appPath: String? = nil, companion: CompanionConfiguration? = nil, buildPath: String? = nil) {
        model.edit { project in
            let a = project.app
            return project.replacing(app: .init(projectPath: appPath ?? a.projectPath, scheme: a.scheme, configuration: a.configuration, bundleIdentifier: a.bundleIdentifier, productName: a.productName, derivedDataPath: buildPath ?? a.derivedDataPath, launchArguments: a.launchArguments, companion: companion ?? a.companion))
        }
    }
    func relink(companion: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "xcodeproj")!, .init(filenameExtension: "xcworkspace")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let base = model.bundleURL?.standardizedFileURL.path
        let path = base.map { url.path.hasPrefix($0 + "/") ? String(url.path.dropFirst($0.count + 1)) : url.path } ?? url.path
        if companion, let c = model.project?.app.companion { replace(companion: .init(projectPath: path, scheme: c.scheme, testIdentifier: c.testIdentifier, runnerBundleIdentifier: c.runnerBundleIdentifier, mailboxRelativePath: c.mailboxRelativePath, resourceLocation: .projectPath)) }
        else if !companion { replace(appPath: path) }
    }
    func packaged() {
        replace(companion: .init(projectPath: "Companion/Fixtures/OnboardingFixture/OnboardingFixture.xcodeproj", scheme: "CompanionService", testIdentifier: "FixtureUITests/CompanionServiceTests/testServe", runnerBundleIdentifier: "dev.agentic.FixtureUITests.xctrunner", resourceLocation: .bundledCompanion))
    }
}

struct ProjectExportSheet: View {
    @Bindable var model: WorkspaceModel
    @State private var scope = "none"
    @State private var selected: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkbenchSheetHeader(title: "Export testing project", subtitle: "Copies definitions, references, migration originals and the run evidence you choose. External Xcode source and build caches are not copied. Dependencies may need relinking after relocation. Captures and logs may contain sensitive app data.")
            Picker("Run artifacts", selection: $scope) { Text("No runs").tag("none"); Text("Selected runs").tag("selected"); Text("All runs").tag("all") }.pickerStyle(.segmented)
            if scope == "selected" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.run.history, id: \.path) { url in
                            Toggle(url.lastPathComponent, isOn: Binding(get: { selected.contains(url.lastPathComponent) }, set: { if $0 { selected.insert(url.lastPathComponent) } else { selected.remove(url.lastPathComponent) } }))
                                .font(WorkbenchStyle.rowFont)
                                .padding(.horizontal, 10)
                                .frame(minHeight: WorkbenchStyle.rowHeight, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .workbenchCard(padding: WorkbenchStyle.cardPadding)
                }
                .frame(height: 180)
            }
            HStack { Button("Cancel") { model.showingExport = false }; Spacer(); Button("Choose New Destination…") { export() }.buttonStyle(WorkbenchButtonStyle(prominent: true)) }.workbenchSheetButtons()
        }.padding(WorkbenchStyle.sheetPadding).frame(width: 700)
    }
    func export() {
        guard model.save(), let source = model.bundleURL, let project = model.project else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = project.name + " Copy.uitestproject"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try ProjectBundleStore().export(from: source, to: destination, runs: scope == "all" ? .all : scope == "selected" ? .selected(selected) : .none); model.showingExport = false }
        catch { model.report(error) }
    }
}
