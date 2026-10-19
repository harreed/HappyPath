import SwiftUI
import AppKit
import CoreText
import ProjectDomain
import RunnerCore

@main struct HappyPathApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchDelegate.self) private var delegate
    @State private var model = WorkspaceModel()
    init() {
        if let fontURL = Bundle.main.url(forResource: "DMSans-Variable", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }
    var body: some Scene {
        Window("HappyPath", id: "workspace") {
            WorkspaceView(model: model).frame(minWidth: 1050, minHeight: 680)
                .font(WorkbenchStyle.font(.body))
                .tint(WorkbenchStyle.accent)
                .background(WindowCloseGuard(model: model))
                .onAppear { delegate.model = model }
                .onOpenURL { url in if model.mayReplace() { model.load(url) } }
        }
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) { Button("New Testing Project…", action: model.newProject).keyboardShortcut("n"); Button("Open Testing Project…", action: model.open).keyboardShortcut("o") }
                CommandGroup(replacing: .saveItem) { Button("Save", action: { model.save() }).keyboardShortcut("s").disabled(model.project == nil) }
            }
    }
}

@MainActor final class WorkbenchDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model?.mayReplace() == false ? .terminateCancel : .terminateNow }
}

struct WindowCloseGuard: NSViewRepresentable {
    let model: WorkspaceModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView { let view = NSView(); DispatchQueue.main.async { view.window?.delegate = context.coordinator }; return view }
    func updateNSView(_ nsView: NSView, context: Context) {}
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: WorkspaceModel
        init(model: WorkspaceModel) { self.model = model }
        func windowShouldClose(_ sender: NSWindow) -> Bool { model.mayReplace() }
    }
}

private enum WorkspacePage { case test, run, history, resources }

private struct WorkbenchHomeView: View {
    let newProject: () -> Void
    let openProject: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("HappyPath")
                    .font(WorkbenchStyle.font(size: 19, weight: .bold))
                    .tracking(-0.7)
                    .foregroundStyle(WorkbenchStyle.ink)

                Spacer(minLength: 32)

                Text("Test the whole\njourney.")
                    .font(WorkbenchStyle.font(size: 56, weight: .bold, relativeTo: .largeTitle))
                    .tracking(-2.4)
                    .lineSpacing(-5)
                    .foregroundStyle(WorkbenchStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Build iOS tests, run them in Simulator, and inspect what happened at every step.")
                    .font(WorkbenchStyle.font(size: 16))
                    .foregroundStyle(WorkbenchStyle.ink.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
                    .padding(.top, 19)

                HStack(spacing: 12) {
                    Button(action: newProject) {
                        HStack(spacing: 14) {
                                Text("Create project")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .frame(minWidth: 166, minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WorkbenchStyle.accentText)
                    .background(WorkbenchStyle.accent, in: WorkbenchStyle.shape(11))

                    Button(action: openProject) {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                            Text("Open project")
                        }
                        .frame(minWidth: 166, minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WorkbenchStyle.accent)
                    .background(WorkbenchStyle.panel, in: WorkbenchStyle.shape(11))
                    .overlay(WorkbenchStyle.shape(11).strokeBorder(WorkbenchStyle.accent.opacity(0.25)))
                }
                .font(WorkbenchStyle.font(size: 14, weight: .semibold))
                .padding(.top, 36)

                Spacer(minLength: 32)
            }
            .padding(.leading, 72)
            .padding(.trailing, 40)
            .padding(.vertical, 45)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            journeyField
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WorkbenchStyle.canvas)
        .ignoresSafeArea(edges: .top)
    }

    private var journeyField: some View {
        ZStack {
            WorkbenchStyle.illustrationField
            SimulatorDotMatrix()

            HStack(spacing: 16) {
                examplePhone
                exampleTrace.offset(y: 94)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private var examplePhone: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(WorkbenchStyle.ink.opacity(0.7))
                .frame(width: 54, height: 6)
                .padding(.top, 17)

            VStack(alignment: .leading, spacing: 0) {
                Text("APP UNDER TEST")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(WorkbenchStyle.accent)
                    .padding(.top, 57)

                Text("Welcome back")
                    .font(WorkbenchStyle.font(size: 25, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(WorkbenchStyle.ink)
                    .padding(.top, 12)

                Text("Sign in to continue")
                    .font(WorkbenchStyle.font(size: 12))
                    .foregroundStyle(WorkbenchStyle.ink.opacity(0.55))
                    .padding(.top, 4)
                    .padding(.bottom, 28)

                exampleInput("alex@example.com")
                exampleInput("••••••••••")
                    .padding(.top, 9)

                Text("Continue")
                    .font(WorkbenchStyle.font(size: 12, weight: .semibold))
                    .foregroundStyle(WorkbenchStyle.accentText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(WorkbenchStyle.accent, in: WorkbenchStyle.shape(8))
                    .overlay(alignment: .trailing) {
                        Circle()
                            .strokeBorder(WorkbenchStyle.accent, lineWidth: 1.5)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(WorkbenchStyle.canvas.opacity(0.58)))
                            .overlay(Circle().fill(WorkbenchStyle.accent).frame(width: 8, height: 8))
                            .offset(x: 13, y: 12)
                    }
                    .padding(.top, 20)

                Spacer()
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 238, height: 455)
        .background(WorkbenchStyle.canvas, in: WorkbenchStyle.shape(34))
        .overlay(WorkbenchStyle.shape(34).strokeBorder(WorkbenchStyle.ink.opacity(0.46), lineWidth: 1.5))
        .shadow(color: WorkbenchStyle.ink.opacity(0.10), radius: 16, y: 9)
    }

    private func exampleInput(_ title: String) -> some View {
        Text(title)
            .font(WorkbenchStyle.font(size: 11))
            .foregroundStyle(WorkbenchStyle.ink.opacity(0.42))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 42)
            .padding(.horizontal, 12)
            .background(WorkbenchStyle.panel, in: WorkbenchStyle.shape(7))
            .overlay(WorkbenchStyle.shape(7).strokeBorder(WorkbenchStyle.ink.opacity(0.15)))
    }

    private var exampleTrace: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("EXAMPLE TEST")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(WorkbenchStyle.accent)
                .padding(.bottom, 18)

            Text("ACTION")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(WorkbenchStyle.ink.opacity(0.45))
            Text("Tap Continue")
                .font(WorkbenchStyle.font(size: 14, weight: .semibold))
                .foregroundStyle(WorkbenchStyle.ink)
                .padding(.top, 4)

            Rectangle()
                .fill(WorkbenchStyle.ink.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 17)

            Text("EXPECTED")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(WorkbenchStyle.ink.opacity(0.45))
            Text("Home screen appears")
                .font(WorkbenchStyle.font(size: 14, weight: .semibold))
                .foregroundStyle(WorkbenchStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                Text("Verified")
            }
            .font(WorkbenchStyle.font(size: 11, weight: .semibold))
            .foregroundStyle(WorkbenchStyle.accent)
            .padding(.top, 23)
        }
        .padding(20)
        .frame(width: 210, alignment: .leading)
        .background(WorkbenchStyle.panel, in: WorkbenchStyle.shape(7))
        .overlay(WorkbenchStyle.shape(7).strokeBorder(WorkbenchStyle.ink.opacity(0.16)))
        .shadow(color: WorkbenchStyle.ink.opacity(0.07), radius: 14, y: 7)
    }
}

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showingGoalRun = false
    @State private var showingLinearImport = false
    @State private var goalText = ""
    @State private var goalCriteria = ""
    @State private var page: WorkspacePage = .test
    @State private var expandedCategories: Set<UUID> = []
    @State private var expandedSuites: Set<UUID> = []
    var body: some View {
        Group {
            if model.project == nil {
                WorkbenchHomeView(newProject: model.newProject, openProject: model.open)
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 265)
                    Rectangle().fill(WorkbenchStyle.hairline).frame(width: 1)
                    mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(WorkbenchStyle.canvas)
            }
        }
        .toolbar {
            if model.project != nil {
                CustomMenu(items: projectMenuItems, width: 225) {
                    WorkbenchMenuTrigger(title: "Project", systemImage: "square.grid.2x2")
                }
                .padding(.horizontal, 12)
                Button("Save", systemImage: "square.and.arrow.down") { model.save() }
                    .padding(.horizontal, 12)
                    .disabled(!model.isDirty)
                CustomMenu(items: runMenuItems, width: 220) {
                    WorkbenchMenuTrigger(title: "Run", systemImage: "play.fill")
                }
                .padding(.horizontal, 12)
                .disabled(model.run.active)
            }
        }
        .onChange(of: model.showingRun) { if model.showingRun { page = .run } }
        .onChange(of: model.project?.id) {
            expandedCategories = Set(model.project?.categories.prefix(1).map(\.id) ?? [])
            expandedSuites = Set(model.project?.categories.first?.suites.prefix(1).map(\.id) ?? [])
            page = .test
        }
        .sheet(isPresented: $model.showingDependencies) { ProjectDependencySheet(model: model) }
        .sheet(isPresented: $model.showingExport) { ProjectExportSheet(model: model) }
        .sheet(isPresented: $model.showingRecovery) { ProjectRecoverySheet(model: model) }
        .sheet(isPresented: $model.showingSetup) { ProjectSetupView(model: model) }
        .sheet(isPresented: $showingLinearImport) { LinearTicketImportView(model: model) }
        .sheet(isPresented: $showingGoalRun) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Run a goal").font(WorkbenchStyle.titleFont)
                Text("Describe the outcome you want, such as “Start a meditation”. The agent will inspect each screen and try safe controls for up to 10 minutes. Account details, purchases, consent, and screens without enough visible text may need your review.")
                    .workbenchInfo()
                TextField("What should the app achieve?", text: $goalText, axis: .vertical).lineLimit(2...5)
                TextField("Success looks like… (optional)", text: $goalCriteria, axis: .vertical).lineLimit(2...4)
                HStack {
                    Spacer()
                    Button("Cancel") { showingGoalRun = false }
                    Button("Run Goal") { let goal = goalText; let criteria = goalCriteria; showingGoalRun = false; model.startGoal(goal, successCriteria: criteria) }
                        .disabled(goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 540)
        }
        .alert("Project error", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .alert("Rename", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) { TextField("Name", text: $renameText); Button("Cancel", role: .cancel) { renameID = nil }; Button("Rename") { if let id = renameID { model.rename(id, name: renameText) }; renameID = nil } }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(WorkbenchStyle.accent)
                Text(model.project?.name ?? "No project").font(WorkbenchStyle.font(.headline, weight: .semibold)).lineLimit(1)
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("TESTS").font(WorkbenchStyle.font(.caption2, weight: .bold)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 18)
                    if let project = model.project {
                        ForEach(project.categories) { category in
                            DisclosureGroup(isExpanded: expansion(category.id, in: $expandedCategories)) {
                                if category.suites.count == 1, let suite = category.suites.first {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(suite.tests) { test in
                                            sidebarTest(test)
                                        }
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(category.suites) { suite in
                                            DisclosureGroup(isExpanded: expansion(suite.id, in: $expandedSuites)) {
                                                VStack(alignment: .leading, spacing: 0) {
                                                    ForEach(suite.tests) { test in
                                                        sidebarTest(test)
                                                    }
                                                }
                                            } label: { Label(suite.name, systemImage: "folder").rightClickMenu(suiteMenu(suite)) }
                                        }
                                    }
                                }
                            } label: { Label(category.name, systemImage: "folder").rightClickMenu(categoryMenu(category)) }
                        }
                    } else {
                        Text("Create or open a project to see tests.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary).padding(18)
                    }
                }.font(WorkbenchStyle.font(.subheadline)).padding(.trailing, 12).padding(.leading, 18)
            }
            Divider()
            if model.run.active || model.run.archive != nil {
                sidebarDestination("Live run", icon: "play.rectangle", selected: page == .run) { page = .run; model.showingRun = true }
            }
            sidebarDestination("Past runs", icon: "clock.arrow.circlepath", selected: page == .history) { page = .history; if let base = model.bundleURL { model.run.refreshHistory(base: base) } }
            sidebarDestination("Resources", icon: "square.stack.3d.up", selected: page == .resources) { page = .resources }
            Divider()
            Button("Add folder", systemImage: "folder.badge.plus", action: model.addCategory)
                .buttonStyle(.plain).font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary).padding(16).disabled(model.project == nil)
        }.background(WorkbenchStyle.sidebar)
    }
    private func sidebarTest(_ test: ProjectDomain.TestCase) -> some View {
        Button {
            model.selection = test.id; model.showingRun = false; page = .test
        } label: {
            Label(test.name, systemImage: "doc.text")
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 30)
                .padding(.horizontal, 10)
                .background(page == .test && model.selection == test.id ? WorkbenchStyle.selected : Color.clear, in: WorkbenchStyle.shape(8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).rightClickMenu(testMenu(test))
    }
    private func sidebarDestination(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9).padding(.horizontal, 10)
                .background(selected ? WorkbenchStyle.selected : Color.clear, in: WorkbenchStyle.shape(8))
        }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 2)
    }
    private func expansion(_ id: UUID, in values: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { expanded in
            if expanded { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }
    @ViewBuilder private var mainContent: some View {
        switch page {
        case .test:
            if let test = model.selectedTest {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(test.name).font(WorkbenchStyle.font(.title2, weight: .bold))
                            Text(model.project?.name ?? "").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("New test", systemImage: "plus") {
                            if let suite = model.project?.categories.flatMap(\.suites).first(where: { $0.tests.contains { $0.id == test.id } }) { model.addTest(suite) }
                        }.buttonStyle(.bordered)
                        Button("Details", systemImage: "sidebar.right") { model.showingTestInspector.toggle() }.buttonStyle(.bordered)
                        Button(test.effectiveExecutionMode == .goal ? "Run goal" : "Run steps", systemImage: "play.fill") {
                            model.startRun(.test(test.id))
                        }.buttonStyle(.borderedProminent)
                            .disabled(model.run.active || (test.effectiveExecutionMode == .goal && test.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }.padding(.horizontal, 24).padding(.vertical, 15)
                    Divider()
                    HStack(spacing: 0) {
                        TestAuthoringView(model: model, testID: test.id).id(test.id)
                        if model.showingTestInspector {
                            Divider()
                            AuthoringInspector(model: model, testID: test.id).frame(width: 320)
                        }
                    }
                }
            } else { ContentUnavailableView("Choose a test", systemImage: "doc.text", description: Text("Create a testing project, then add folders and tests.")) }
        case .run: RunExperienceView(model: model)
        case .history: PastRunsView(model: model) { url in
            do { try model.run.open(url, retryBase: model.bundleURL); model.showingRun = true; page = .run } catch { model.report(error) }
        }
        case .resources: ProjectResourcesView(model: model)
        }
    }
    var projectMenuItems: [RightClickItem] {
        [
            .section("Project"),
            .button("New Project…", systemImage: "plus", action: model.newProject),
            .button("Open Project…", systemImage: "folder", action: model.open),
            .button("Save", systemImage: "square.and.arrow.down", enabled: model.project != nil && model.isDirty) { model.save() },
            .divider,
            .button("Project Settings…", systemImage: "gearshape", enabled: model.project != nil, action: model.configureProject),
            .button("Dependencies…", systemImage: "link", enabled: model.project != nil && !model.run.active) { model.showingDependencies = true },
            .button("Recovery Settings…", systemImage: "shield", enabled: model.project != nil) { model.showingRecovery = true },
            .button("Create Test from Linear Ticket…", systemImage: "ticket", enabled: model.project != nil && !model.run.active) { showingLinearImport = true },
            .divider,
            .button("Open Run…", systemImage: "clock.arrow.circlepath", enabled: !model.run.active) {
                do { try model.run.chooseArchive(); model.showingRun = true } catch { model.report(error) }
            },
            .button("Export Project…", systemImage: "square.and.arrow.up", enabled: model.project != nil && !model.run.active) { model.showingExport = true },
        ]
    }
    @ViewBuilder func operations(_ id: UUID, _ name: String) -> some View {
        Button("Rename…") { renameID = id; renameText = name }
        Button("Duplicate") { model.duplicate(id) }
        Button("Move Up") { model.move(id, by: -1) }
        Button("Move Down") { model.move(id, by: 1) }
        Button("Delete", role: .destructive) { model.edit { $0.deleting(id) }; if model.selection == id { model.selection = nil } }
    }

    var runMenuItems: [RightClickItem] {
        [
            .button("Run a Goal…", systemImage: "sparkles") { showingGoalRun = true },
            .divider,
            .button("Run Selected Test", systemImage: "play.fill", enabled: model.selectedTest != nil) {
                if let test = model.selectedTest { model.startRun(.test(test.id)) }
            },
            .button("Run Selected Set (\(model.runSet.count))", systemImage: "checklist", enabled: !model.runSet.isEmpty) {
                model.startRun(.selection(model.runSet))
            },
            .button("Run All", systemImage: "play") { model.startRun(.all) },
        ]
    }

    func testMenu(_ test: ProjectDomain.TestCase) -> [RightClickItem] {
        var items: [RightClickItem] = [
            .button("Run Test", systemImage: "play.fill", enabled: !model.run.active) { model.startRun(.test(test.id)) },
            .button(
                model.runSet.contains(test.id) ? "Remove from Run Set" : "Add to Run Set",
                systemImage: model.runSet.contains(test.id) ? "minus.circle" : "plus.circle"
            ) {
                if !model.runSet.insert(test.id).inserted { model.runSet.remove(test.id) }
            },
            .divider,
        ]
        items.append(contentsOf: operationItems(test.id, test.name))
        return items
    }

    func suiteMenu(_ suite: ProjectDomain.TestSuite) -> [RightClickItem] {
        var items: [RightClickItem] = [
            .button("Run Suite", systemImage: "play.fill", enabled: !model.run.active) { model.startRun(.suite(suite.id)) },
            .button("Add Test", systemImage: "plus") { model.addTest(suite) },
            .divider,
        ]
        items.append(contentsOf: operationItems(suite.id, suite.name))
        return items
    }

    func categoryMenu(_ category: ProjectDomain.Category) -> [RightClickItem] {
        var items: [RightClickItem] = [
            .button("Run Category", systemImage: "play.fill", enabled: !model.run.active) { model.startRun(.category(category.id)) },
            .button("Add Test", systemImage: "doc.badge.plus", enabled: category.suites.count == 1) { if let suite = category.suites.first { model.addTest(suite) } },
            .button("Add Suite", systemImage: "plus") { model.addSuite(category) },
            .divider,
        ]
        items.append(contentsOf: operationItems(category.id, category.name))
        return items
    }

    func operationItems(_ id: UUID, _ name: String) -> [RightClickItem] {
        [
            .button("Rename…", systemImage: "pencil") { renameID = id; renameText = name },
            .button("Duplicate", systemImage: "square.on.square") { model.duplicate(id) },
            .button("Move Up", systemImage: "arrow.up") { model.move(id, by: -1) },
            .button("Move Down", systemImage: "arrow.down") { model.move(id, by: 1) },
            .divider,
            .button("Delete", systemImage: "trash", destructive: true) {
                model.edit { $0.deleting(id) }
                if model.selection == id { model.selection = nil }
            },
        ]
    }
}

struct ProjectSetupView: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WorkbenchSheetHeader(title: model.editingSetup ? "Project settings" : "Create a testing project", subtitle: "Chooses the Xcode app and simulator used by every run in this project.")
            Form {
                TextField("Name", text: $model.name)
                LabeledContent("Xcode project") { Button(model.path.isEmpty ? "Choose project or workspace…" : URL(fileURLWithPath: model.path).lastPathComponent, action: model.chooseContainer) }
                Picker("Scheme", selection: $model.scheme) { ForEach(model.schemes, id: \.self) { Text($0) } }
                Picker("Configuration", selection: $model.configuration) { ForEach(model.configurations, id: \.self) { Text($0) } }
                Button("Discover App Products") { Task { model.busy = true; defer { model.busy = false }; do { try await model.refreshProducts() } catch { model.report(error) } } }.disabled(model.scheme.isEmpty)
                Picker("App product", selection: $model.productID) { ForEach(model.products) { Text("\($0.name) · \($0.bundleIdentifier)").tag($0.id) } }
                Picker("Simulator", selection: $model.deviceID) { ForEach(model.devices) { Text("\($0.name) · \($0.runtime)").tag($0.id) } }
                Button("Refresh Simulators") { Task { await model.refreshDevices() } }
            }.formStyle(.grouped).disabled(model.busy)
            if model.busy { ProgressView("Reading Xcode project…") }
            HStack { Button("Cancel") { model.showingSetup = false }.workbenchSheetButtons(); Spacer(); Button(model.editingSetup ? "Apply Settings" : "Create Project", action: model.create).buttonStyle(WorkbenchButtonStyle(prominent: true)).disabled(model.busy || model.name.trimmingCharacters(in: .whitespaces).isEmpty || model.productID.isEmpty || model.deviceID.isEmpty) }
        }.padding(WorkbenchStyle.sheetPadding).frame(width: 650, height: 570).task { await model.refreshDevices() }
        .onChange(of: model.scheme) { model.products = []; model.productID = "" }
        .onChange(of: model.configuration) { model.products = []; model.productID = "" }
    }
}
