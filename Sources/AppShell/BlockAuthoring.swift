import SwiftUI
import UniformTypeIdentifiers
import ProjectDomain
import ModelProviders
import SimulatorControl

enum BlockKind: String, CaseIterable, Identifiable {
    case tap = "Tap", type = "Type text", swipe = "Swipe", wait = "Wait", relaunch = "Relaunch", assertion = "Assert", device = "Device control"
    var id: String { rawValue }
    var icon: String { switch self { case .tap: "hand.tap"; case .type: "keyboard"; case .swipe: "hand.draw"; case .wait: "hourglass"; case .relaunch: "arrow.clockwise"; case .assertion: "checkmark.seal"; case .device: "iphone.gen3.radiowaves.left.and.right" } }
    var action: BlockAction { switch self { case .tap: .tap(targets: [.identifier("element.identifier")]); case .type: .typeText("", targets: [.identifier("element.identifier")]); case .swipe: .swipe(.up, targets: []); case .wait: .wait(.exists(.identifier("element.identifier"))); case .relaunch: .relaunch; case .assertion: .assertion(.exists(.identifier("element.identifier"))); case .device: .device(.openURL("myapp://")) } }
    init(_ action: BlockAction) { switch action { case .tap: self = .tap; case .typeText: self = .type; case .swipe: self = .swipe; case .wait: self = .wait; case .relaunch: self = .relaunch; case .assertion: self = .assertion; case .device: self = .device } }
}
extension TargetStrategy {
    var summary: String { switch self { case .identifier(let s): s; case .text(let s): "“\(s)”"; case .semantic(let r, let l, let v): [r,l,v].compactMap { $0 }.joined(separator: " · ") } }
}
extension AssertionDefinition {
    var summary: String { switch self { case .exists(let t): "Exists: \(t.summary)"; case .doesNotExist(let t): "Absent: \(t.summary)"; case .valueEquals(let t, let s): "\(t.summary) = \(s)"; case .valueContains(let t, let s): "\(t.summary) contains \(s)"; case .textVisible(let s): "Visible: “\(s)”"; case .imageMatches(let id, _, _, _): "Matches approved screenshot \(id.uuidString.prefix(8))" } }
}
extension BlockAction {
    var summary: String { switch self { case .tap(let t): t.first?.summary ?? "Choose a target"; case .typeText(let s, let t): "“\(s)” → \(t.first?.summary ?? "Choose a target")"; case .swipe(let d, let t): "\(d.rawValue.capitalized) · \(t.first?.summary ?? "Entire app")"; case .wait(let a), .assertion(let a): a.summary; case .relaunch: "Terminate, then launch the configured app"; case .device(let action): action.summary } }
    var targets: [TargetStrategy] { switch self { case .tap(let t), .typeText(_, let t), .swipe(_, let t): t; default: [] } }
    func withTargets(_ targets: [TargetStrategy]) -> Self { switch self { case .tap: .tap(targets: targets); case .typeText(let s, _): .typeText(s, targets: targets); case .swipe(let d, _): .swipe(d, targets: targets); default: self } }
}
extension DeviceAction {
    var summary: String {
        switch self {
        case .openURL(let url): "Open \(url)"
        case .setLocation(let latitude, let longitude): "Location \(latitude), \(longitude)"
        case .clearLocation: "Clear simulated location"
        case .permission(let service, let decision): "\(decision.rawValue.capitalized) \(service.rawValue) permission"
        case .background(let seconds): "Background app for \(seconds) seconds"
        }
    }
}

struct TestAuthoringView: View {
    @Bindable var model: WorkspaceModel
    let testID: UUID
    @State private var showingDraft = false
    @State private var titleTask: Task<Void, Never>?
    @GestureState private var draggedID: UUID?
    @State private var dragLocation: CGPoint?
    @State private var blockFrames: [UUID: CGRect] = [:]
    @State private var viewport = CGRect.zero
    @State private var endDropID = UUID()
    var dragSpace: String { "test-blocks-\(testID)" }
    var insertion: BlockInsertion? { guard draggedID != nil, let dragLocation else { return nil }; return BlockDragLayout.insertion(at: dragLocation, ids: test?.blocks.map(\.id) ?? [], frames: blockFrames, endID: endDropID, viewport: viewport) }
    var test: TestCase? { model.test(testID) }
    var titleSource: String {
        guard let test else { return "" }
        return ([test.goal, test.successCriteria] + test.blocks.map { "\($0.title): \($0.action.summary)" }).joined(separator: "\n")
    }
    var body: some View {
        if let test {
            GeometryReader { viewportProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchStyle.sectionSpacing) {
                    VStack(alignment: .leading, spacing: WorkbenchStyle.spacing) {
                        WorkbenchSectionLabel("TEST")
                        TextField("Test name", text: field(\.name) { $0.replacing(name: $1) }).font(WorkbenchStyle.titleFont).textFieldStyle(.plain)
                        // Replay authoring is paused while the creation flow focuses on goals.
                        #if false
                        Picker("How to run", selection: Binding(get: { test.effectiveExecutionMode }, set: { mode in
                            model.updateTest(testID) { $0.replacing(executionMode: mode) }
                            model.selectedBlockID = nil
                        })) {
                            Text("Follow a goal").tag(TestExecutionMode.goal)
                            Text("Replay steps").tag(TestExecutionMode.scripted)
                        }.pickerStyle(.segmented)
                        #endif
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ACCOMPLISH").font(WorkbenchStyle.font(.caption, weight: .semibold)).foregroundStyle(.secondary)
                            TextField("What should the app do?", text: field(\.goal) { $0.replacing(goal: $1) }, axis: .vertical)
                                .lineLimit(3...6)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(WorkbenchStyle.inset, in: WorkbenchStyle.shape(WorkbenchStyle.rowRadius))
                            Text("Describe the task in plain language, for example, create an account and sign in.").workbenchInfo()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text("GOAL").font(WorkbenchStyle.font(.caption, weight: .semibold)).foregroundStyle(.secondary)
                                Text("OPTIONAL").font(WorkbenchStyle.font(.caption2)).foregroundStyle(.tertiary)
                            }
                            TextField("What should be visible when it succeeds?", text: field(\.successCriteria) { $0.replacing(successCriteria: $1) }, axis: .vertical)
                                .lineLimit(3...5)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(WorkbenchStyle.inset, in: WorkbenchStyle.shape(WorkbenchStyle.rowRadius))
                            Text("Give a clear finish state when the task could have several outcomes.").workbenchInfo()
                        }
                        HStack {
                            #if false
                            if test.effectiveExecutionMode == .scripted {
                                Button("Draft Steps…", systemImage: "sparkles") { showingDraft = true }.workbenchSheetButtons()
                            }
                            #endif
                            Spacer()
                            Button("Test Settings", systemImage: "slider.horizontal.3") { model.selectedBlockID = nil; model.showingTestInspector = true }.workbenchSheetButtons()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).workbenchCard()
                    if let issue = validationIssue(test) { WorkbenchNotice(text: issue, kind: .warning) }
                    #if false
                    if test.effectiveExecutionMode == .scripted {
                    HStack { WorkbenchSectionLabel("STEPS"); Text("\(test.blocks.count)").font(WorkbenchStyle.rowFont).foregroundStyle(.secondary); Spacer(); addMenu }
                    if test.blocks.isEmpty { ContentUnavailableView("Build your first step", systemImage: "square.stack.3d.up", description: Text("Add a deterministic block or generate an editable draft.")) }
                    ForEach(Array(test.blocks.enumerated()), id: \.element.id) { index, block in
                        BlockCard(block: block, index: index, selected: model.selectedBlockID == block.id, drag: dragGesture(block.id), select: { model.selectedBlockID = block.id; model.showingTestInspector = true }, edit: { transform in model.updateTest(testID) { $0.updatingBlock(block.id, transform) } }, duplicate: {
                            let copy = block.duplicated(); model.updateTest(testID) { value in var blocks = value.blocks; if let i = blocks.firstIndex(where: { $0.id == block.id }) { blocks.insert(copy, at: i + 1) }; return value.replacing(blocks: blocks) }; model.selectedBlockID = copy.id
                        }, delete: { model.updateTest(testID) { $0.replacing(blocks: $0.blocks.filter { $0.id != block.id }) } })
                        .blockFrame(block.id, space: dragSpace).insertionMarker(insertion == .before(block.id)).opacity(draggedID == block.id ? 0.65 : 1)
                    }
                    Text("Drop here to move a step to the end").workbenchInfo().frame(maxWidth: .infinity).padding(12).background(WorkbenchStyle.inset, in: WorkbenchStyle.shape(WorkbenchStyle.rowRadius)).overlay(WorkbenchStyle.shape(WorkbenchStyle.rowRadius).strokeBorder(WorkbenchStyle.hairline, lineWidth: 1))
                        .blockFrame(endDropID, space: dragSpace).insertionMarker(insertion == .end)
                    }
                    #endif
                }.padding(WorkbenchStyle.pagePadding).onPreferenceChange(BlockFramesPreference.self) { blockFrames = $0 }
            }
            .workbenchCanvas()
            .coordinateSpace(name: dragSpace)
            .onAppear { viewport = CGRect(origin: .zero, size: viewportProxy.size) }
            .onChange(of: viewportProxy.size) { viewport = CGRect(origin: .zero, size: viewportProxy.size) }
            .sheet(isPresented: $showingDraft) { DraftReviewView(model: model, testID: testID, initialPrompt: test.goal) }
            .onChange(of: testID) { model.selectedBlockID = nil }
            .onChange(of: model.selection) { dragLocation = nil }
            .onAppear { scheduleTitle() }
            .onChange(of: titleSource) { scheduleTitle() }
            .onDisappear { titleTask?.cancel() }
            }
        }
    }
    var addMenu: some View {
        CustomMenu(
            items: BlockKind.allCases.map { kind in
                .button(kind.rawValue, systemImage: kind.icon) {
                    let block = TestBlock(title: kind.rawValue, action: kind.action)
                    model.updateTest(testID) { $0.replacing(blocks: $0.blocks + [block]) }
                    model.selectedBlockID = block.id; model.showingTestInspector = true
                }
            },
            width: 200
        ) {
            Label("Add Block", systemImage: "plus")
                .font(WorkbenchStyle.rowFont)
                .foregroundStyle(Color.primary.opacity(0.86))
                .padding(.horizontal, 12)
                .frame(height: WorkbenchStyle.controlHeight)
                .background(WorkbenchStyle.hover, in: WorkbenchStyle.shape(WorkbenchStyle.rowRadius))
                .overlay(WorkbenchStyle.shape(WorkbenchStyle.rowRadius).strokeBorder(WorkbenchStyle.border, lineWidth: 1))
        }
    }
    func field(_ key: KeyPath<TestCase, String>, _ set: @escaping (TestCase, String) -> TestCase) -> Binding<String> { Binding(get: { model.test(testID)?[keyPath: key] ?? "" }, set: { text in model.updateTest(testID) { set($0, text) } }) }
    func scheduleTitle() {
        titleTask?.cancel()
        guard let test, test.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || test.name == "New test",
              !titleSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        titleTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await model.generateTitleIfNeeded(testID)
        }
    }
    func move(_ id: UUID, _ destination: UUID?) {
        guard test?.blocks.contains(where: { $0.id == id }) == true else { DragTrace.record("move-rejected", ["source": id.uuidString]); return }
        let before = test?.blocks.map { $0.id.uuidString }.joined(separator: ",") ?? ""
        model.updateTest(testID) { $0.replacing(blocks: $0.blocks.moving(id, before: destination)) }; model.selectedBlockID = id
        DragTrace.record("move-result", ["source": id.uuidString, "before": before, "after": test?.blocks.map { $0.id.uuidString }.joined(separator: ",") ?? ""])
    }
    func dragGesture(_ id: UUID) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(dragSpace)).updating($draggedID) { _, state, _ in state = id }.onChanged { value in
            dragLocation = value.location
            DragTrace.record("local-changed", ["scope": testID.uuidString, "source": id.uuidString])
        }.onEnded { value in
            defer { dragLocation = nil }
            DragTrace.record("local-drop-geometry", ["source": id.uuidString, "location": String(describing: value.location), "viewport": String(describing: viewport), "selectionMatches": String(model.selection == testID), "sourceExists": String(test?.blocks.contains(where: { $0.id == id }) == true), "frames": blockFrames.map { "\($0.key.uuidString)=\($0.value)" }.sorted().joined(separator: ";"), "endID": endDropID.uuidString])
            guard model.selection == testID, test?.blocks.contains(where: { $0.id == id }) == true,
                  let target = BlockDragLayout.insertion(at: value.location, ids: test?.blocks.map(\.id) ?? [], frames: blockFrames, endID: endDropID, viewport: viewport) else { DragTrace.record("local-outside-cancelled", ["source": id.uuidString]); return }
            switch target { case .before(let destination): move(id, destination); case .end: move(id, nil) }
            DragTrace.record("local-ended", ["source": id.uuidString])
        })
    }
    func validationIssue(_ test: TestCase) -> String? {
        if test.effectiveExecutionMode == .scripted {
            for (index, block) in test.blocks.enumerated() {
                do { try DraftPlan(blocks: [block]).validate() } catch { return "Block \(index + 1) “\(block.title)” needs attention: \(error.localizedDescription) Correct it before saving or running." }
            }
        } else if test.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a goal before running this test."
        }
        do { try model.project?.validate() } catch { return "Test settings need attention: \(error.localizedDescription) Your last saved definition is unchanged." }
        return nil
    }
}

struct BlockCard: View {
    let block: TestBlock
    let index: Int
    let selected: Bool
    let drag: AnyGesture<DragGesture.Value>
    let select: () -> Void
    let edit: (@escaping (TestBlock) -> TestBlock) -> Void
    let duplicate: () -> Void
    let delete: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "line.3.horizontal").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary).frame(width: 18, height: 38).contentShape(Rectangle()).help("Drag to reorder").accessibilityLabel("Drag \(block.title)").gesture(drag)
            HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", index + 1)).font(WorkbenchStyle.font(.caption).monospacedDigit()).foregroundStyle(.tertiary).frame(width: 22, alignment: .leading).padding(.top, 5)
            Image(systemName: BlockKind(block.action).icon).font(WorkbenchStyle.font(size: 15, weight: .semibold)).foregroundStyle(block.enabled ? Color.accentColor : Color.secondary).frame(width: 34, height: 34).background(Color.accentColor.opacity(0.10), in: WorkbenchStyle.shape(WorkbenchStyle.rowRadius))
            VStack(alignment: .leading, spacing: 6) {
                Text(block.title).font(WorkbenchStyle.font(.subheadline, weight: .semibold))
                Text(block.action.summary).font(WorkbenchStyle.infoFont).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) { Text(BlockKind(block.action).rawValue); if !block.enabled { Text("Disabled") }; if block.breakpoint { Label("Breakpoint", systemImage: "pause.circle.fill").foregroundStyle(.orange) } }.font(WorkbenchStyle.font(.caption2)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            }.contentShape(Rectangle()).onTapGesture(perform: select)
            CustomMenu(items: cardMenuItems, width: 200, alignment: .trailing) {
                Image(systemName: "ellipsis")
                    .font(WorkbenchStyle.font(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(WorkbenchStyle.inset, in: WorkbenchStyle.shape(WorkbenchStyle.rowRadius))
            }
        }.padding(WorkbenchStyle.panelPadding).background(selected ? WorkbenchStyle.selected : WorkbenchStyle.panel, in: WorkbenchStyle.shape()).overlay(WorkbenchStyle.shape().strokeBorder(selected ? WorkbenchStyle.accent : WorkbenchStyle.border, lineWidth: selected ? 1.5 : 1)).opacity(block.enabled ? 1 : 0.65)
    }

    var cardMenuItems: [RightClickItem] {
        [
            .button("Enabled", systemImage: "checkmark.circle", selected: block.enabled) {
                edit { $0.replacing(enabled: !block.enabled) }
            },
            .button("Breakpoint", systemImage: "pause.circle", selected: block.breakpoint) {
                edit { $0.replacing(breakpoint: !block.breakpoint) }
            },
            .divider,
            .button("Duplicate", systemImage: "square.on.square", action: duplicate),
            .button("Delete", systemImage: "trash", destructive: true, action: delete),
        ]
    }
}


struct AuthoringInspector: View {
    @Bindable var model: WorkspaceModel
    let testID: UUID
    var body: some View {
        if let test = model.test(testID) {
            if let id = model.selectedBlockID, let selected = test.blocks.first(where: { $0.id == id }) {
                Form { BlockConfiguration(block: Binding(get: { model.test(testID)?.blocks.first { $0.id == id } ?? selected }, set: { value in model.updateTest(testID) { $0.updatingBlock(id) { _ in value } } })) }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .workbenchCanvas()
            } else {
                Form {
                    Section("Test") {
                        TextField("Timeout (seconds)", value: Binding(get: { model.test(testID)?.timeoutSeconds ?? 120 }, set: { value in model.updateTest(testID) { $0.replacing(timeoutSeconds: value) } }), format: .number)
                        Text(Self.timeoutSummary(test.timeoutSeconds))
                            .font(WorkbenchStyle.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Section("Starting state") {
                        Text("Choose what the Simulator keeps before this test starts.")
                            .font(WorkbenchStyle.font(.caption))
                            .foregroundStyle(.secondary)
                        StartingStateEditor(state: Binding(get: { model.test(testID)?.startingState ?? .init() }, set: { value in model.updateTest(testID) { $0.replacing(startingState: value) } }))
                    }
                    if test.effectiveExecutionMode == .goal {
                        Section("Apple Account") { AppleCredentialEditor() }
                        Section("System prompts") {
                            Toggle("Automatically accept clear system prompts", isOn: Binding(
                                get: { model.project?.defaultRecoveryPolicy?.allowSystemDismiss ?? true },
                                set: { enabled in model.edit { project in
                                    project.replacing(defaultRecoveryPolicy: (project.defaultRecoveryPolicy ?? .init()).replacing(allowSystemDismiss: enabled))
                                } }
                            ))
                            Text("Accepts a system prompt when it has one clear accept action. Apple Account sign-in prompts are closed. Applies to every goal test in this project.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
                        }
                    }
                    Section("More settings") {
                        if test.effectiveExecutionMode == .scripted {
                        DisclosureGroup("Preconditions · \(test.preconditions.count)") {
                            AssertionList(values: testArray(preconditions: true))
                        }
                        DisclosureGroup("Final assertions · \(test.assertions.count)") {
                            AssertionList(values: testArray(preconditions: false))
                        }
                        }
                        DisclosureGroup("Goal assessment") {
                            GoalPolicyEditor(policy: Binding(get: { model.test(testID)?.goalAssessmentPolicy ?? .init() }, set: { value in model.updateTest(testID) { $0.replacing(goalAssessmentPolicy: value) } }))
                        }
                        if test.effectiveExecutionMode == .scripted {
                        DisclosureGroup("Recovery policy") {
                            Toggle("Use project recovery default", isOn: Binding(get: { model.test(testID)?.useProjectRecoveryPolicy == true }, set: { value in model.updateTest(testID) { $0.replacing(useProjectRecoveryPolicy: value) } }))
                            if test.useProjectRecoveryPolicy == true {
                                Text(model.project?.defaultRecoveryPolicy == nil ? "No project default saved; this test’s existing policy is effective." : "Project default is effective. Turn inheritance off to edit this test’s override.").font(WorkbenchStyle.font(.caption))
                            }
                            RecoveryPolicyEditor(policy: Binding(get: { model.project?.recoveryPolicy(for: model.test(testID) ?? test) ?? test.recoveryPolicy }, set: { value in model.updateTest(testID) { $0.replacing(recoveryPolicy: value) } }), definitions: model.project?.reviewedAlertPolicies ?? []).disabled(test.useProjectRecoveryPolicy == true)
                            Button("Edit Project Recovery Settings") { model.showingRecovery = true }
                        }
                        } else {
                            DisclosureGroup("Recovery policy") {
                                Text("Goal runs use the project recovery settings.").font(WorkbenchStyle.font(.caption))
                                Button("Edit Project Recovery Settings") { model.showingRecovery = true }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .workbenchCanvas()
            }
        }
    }
    func testArray(preconditions: Bool) -> Binding<[AssertionDefinition]> { Binding(get: { guard let test = model.test(testID) else { return [] }; return preconditions ? test.preconditions : test.assertions }, set: { value in model.updateTest(testID) { preconditions ? $0.replacing(preconditions: value) : $0.replacing(assertions: value) } }) }
    func recovery<T>(_ key: KeyPath<RecoveryPolicy, T>, _ set: @escaping (RecoveryPolicy, T) -> RecoveryPolicy) -> Binding<T> { Binding(get: { (model.test(testID)?.recoveryPolicy ?? .init())[keyPath: key] }, set: { value in model.updateTest(testID) { $0.replacing(recoveryPolicy: set($0.recoveryPolicy, value)) } }) }
    private static func timeoutSummary(_ seconds: Double) -> String {
        guard seconds > 0 else { return "Enter a timeout greater than zero." }
        guard seconds.truncatingRemainder(dividingBy: 60) == 0 else { return "\(seconds.formatted()) seconds per test." }
        let minutes = Int(seconds / 60)
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes") per test."
    }
}

private struct SettingChoiceRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    selection = option.value
                } label: {
                    if selection == option.value {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(options.first(where: { $0.value == selection })?.title ?? "")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(WorkbenchStyle.font(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(options.first(where: { $0.value == selection })?.title ?? "")")
    }
}

private struct StartingStateEditor: View {
    @Binding var state: TestStartingState
    var body: some View {
        SettingChoiceRow(title: "App data", selection: field(\.appData) { TestStartingState(appData: $0, permissions: state.permissions, appearance: state.appearance, keychain: state.keychain, location: state.location) }, options: [
            ("Keep current data", .preserve),
            ("Reinstall app before test", .reinstall),
        ])
        if state.appData == .reinstall {
            Text("Removes the target app and its local data from the selected Simulator, then installs the freshly built app.")
                .font(WorkbenchStyle.font(.caption)).foregroundStyle(.orange)
        }
        SettingChoiceRow(title: "Permissions", selection: field(\.permissions) { TestStartingState(appData: state.appData, permissions: $0, appearance: state.appearance, keychain: state.keychain, location: state.location) }, options: [
            ("Keep current permissions", .preserve),
            ("Ask again on next use", .reset),
        ])
        SettingChoiceRow(title: "Appearance", selection: field(\.appearance) { TestStartingState(appData: state.appData, permissions: state.permissions, appearance: $0, keychain: state.keychain, location: state.location) }, options: [
            ("Keep current appearance", .unchanged),
            ("Light", .light),
            ("Dark", .dark),
        ])
        Toggle("Reset Simulator keychain", isOn: Binding(get: { state.keychain == .resetSimulator }, set: { reset in
            state = TestStartingState(appData: state.appData, permissions: state.permissions, appearance: state.appearance, keychain: reset ? .resetSimulator : .preserve, location: state.location)
        }))
        Text("Clears all credentials in the selected Simulator before each test, including those for other apps. This Mac’s Keychain is unaffected.")
            .font(WorkbenchStyle.font(.caption))
            .foregroundStyle(state.keychain == .resetSimulator ? .orange : .secondary)
    }
    private func field<Value>(_ key: KeyPath<TestStartingState, Value>, _ set: @escaping (Value) -> TestStartingState) -> Binding<Value> {
        Binding(get: { state[keyPath: key] }, set: { state = set($0) })
    }
}

private struct AppleCredentialEditor: View {
    @AppStorage("appleCredentialAccount") private var account = ""
    @State private var password = ""
    @State private var saved = false
    @State private var message: String?
    private let store = AppleAccountSecretStore()

    var body: some View {
        Text("Use a saved account when a test reaches Apple sign-in.")
            .font(WorkbenchStyle.font(.caption))
            .foregroundStyle(.secondary)
        TextField("Apple Account email", text: $account)
            .textContentType(.username)
            .onChange(of: account) { refresh() }
        SecureField("Password", text: $password)
            .textContentType(.password)
        HStack {
            Button("Save to Keychain") {
                do {
                    try store.save(password, for: account)
                    password = ""
                    saved = true
                    message = "Saved in this Mac’s Keychain."
                } catch { message = error.localizedDescription }
            }.disabled(account.isEmpty || password.isEmpty)
            if saved {
                Button("Remove") {
                    do { try store.remove(for: account); saved = false; message = "Removed from Keychain." }
                    catch { message = error.localizedDescription }
                }
            }
        }
        if account.isEmpty || password.isEmpty {
            Text(saved ? "Password saved in this Mac’s Keychain." : "Enter an email and password to save them in this Mac’s Keychain.")
                .font(WorkbenchStyle.font(.caption))
                .foregroundStyle(.secondary)
        }
        if let message { Text(message).font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary) }
        Text("The password is never saved in the test project or run evidence.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
            .onAppear { refresh() }
    }

    private func refresh() {
        saved = (try? store.password(for: account)) != nil
        message = nil
    }
}

struct BlockConfiguration: View {
    @Binding var block: TestBlock
    var body: some View {
        Section("Block") {
            TextField("Title", text: field(\.title) { $0.replacing(title: $1) })
            Picker("Action", selection: Binding(get: { BlockKind(block.action) }, set: { block = block.replacing(action: $0.action) })) { ForEach(BlockKind.allCases) { Text($0.rawValue).tag($0) } }
            Toggle("Enabled", isOn: field(\.enabled) { $0.replacing(enabled: $1) })
            Toggle("Breakpoint", isOn: field(\.breakpoint) { $0.replacing(breakpoint: $1) })
        }
        switch block.action {
        case .typeText:
            Section("Text entry") { TextField("Literal text", text: Binding(get: { if case .typeText(let s, _) = block.action { return s }; return "" }, set: { block = block.replacing(action: .typeText($0, targets: block.action.targets)) }), axis: .vertical) }
        case .swipe:
            Section("Swipe") { Picker("Direction", selection: Binding(get: { if case .swipe(let d, _) = block.action { return d }; return .up }, set: { block = block.replacing(action: .swipe($0, targets: block.action.targets)) })) { ForEach([SwipeDirection.up, .down, .left, .right], id: \.self) { Text($0.rawValue.capitalized).tag($0) } } }
        case .wait, .assertion:
            Section("Condition") { AssertionEditor(value: Binding(get: { switch block.action { case .wait(let a), .assertion(let a): a; default: .textVisible("") } }, set: { value in if case .wait = block.action { block = block.replacing(action: .wait(value)) } else { block = block.replacing(action: .assertion(value)) } })) }
        case .relaunch: Section { Text("Relaunches the configured app without clearing its data.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary) }
        case .device(let action): DeviceActionEditor(action: Binding(get: { if case .device(let current) = block.action { current } else { action } }, set: { block = block.replacing(action: .device($0)) }))
        default: EmptyView()
        }
        if [.tap, .type, .swipe].contains(BlockKind(block.action)) {
            Section("Ranked targets") {
                Text("Tried from top to bottom. These are configured locators, not verified live matches. An empty swipe target list means the entire app.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
                TargetList(values: Binding(get: { block.action.targets }, set: { block = block.replacing(action: block.action.withTargets($0)) }))
            }
        }
        Section("Retries & timing") {
            TextField("Maximum attempts", value: retry(\.maximumAttempts) { .init(maximumAttempts: $1, delaySeconds: $0.delaySeconds, timeoutSeconds: $0.timeoutSeconds) }, format: .number)
            TextField("Retry delay (seconds)", value: retry(\.delaySeconds) { .init(maximumAttempts: $0.maximumAttempts, delaySeconds: $1, timeoutSeconds: $0.timeoutSeconds) }, format: .number)
            TextField("Timeout (seconds)", value: retry(\.timeoutSeconds) { .init(maximumAttempts: $0.maximumAttempts, delaySeconds: $0.delaySeconds, timeoutSeconds: $1) }, format: .number)
            Text("Only failures confirmed not dispatched can be retried.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
        }
    }
    func field<T>(_ key: KeyPath<TestBlock,T>, _ set: @escaping (TestBlock,T) -> TestBlock) -> Binding<T> { Binding(get: { block[keyPath: key] }, set: { block = set(block, $0) }) }
    func retry<T>(_ key: KeyPath<RetryPolicy,T>, _ set: @escaping (RetryPolicy,T) -> RetryPolicy) -> Binding<T> { Binding(get: { block.retryPolicy[keyPath: key] }, set: { block = block.replacing(retryPolicy: set(block.retryPolicy, $0)) }) }
}

struct DeviceActionEditor: View {
    @Binding var action: DeviceAction
    private var kind: Int {
        switch action {
        case .openURL: 0
        case .setLocation: 1
        case .clearLocation: 2
        case .permission: 3
        case .background: 4
        }
    }
    var body: some View {
        Section("Simulator control") {
            Picker("Control", selection: Binding(get: { kind }, set: { value in
                switch value {
                case 0: action = .openURL("myapp://")
                case 1: action = .setLocation(latitude: 0, longitude: 0)
                case 2: action = .clearLocation
                case 3: action = .permission(service: .location, decision: .grant)
                default: action = .background(seconds: 2)
                }
            })) {
                Text("Open deep link").tag(0)
                Text("Set location").tag(1)
                Text("Clear location").tag(2)
                Text("Set permission").tag(3)
                Text("Background and return").tag(4)
            }
            switch action {
            case .openURL(let url):
                TextField("URL", text: Binding(get: { url }, set: { action = .openURL($0) }))
                Text("Enter the app's registered URL scheme or a universal link.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
            case .setLocation(let latitude, let longitude):
                TextField("Latitude", value: Binding(get: { latitude }, set: { action = .setLocation(latitude: $0, longitude: longitude) }), format: .number)
                TextField("Longitude", value: Binding(get: { longitude }, set: { action = .setLocation(latitude: latitude, longitude: $0) }), format: .number)
            case .clearLocation:
                Text("Removes the simulated location override.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
            case .permission(let service, let decision):
                Picker("Permission", selection: Binding(get: { service }, set: { action = .permission(service: $0, decision: decision) })) {
                    ForEach(SimulatorPermission.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Decision", selection: Binding(get: { decision }, set: { action = .permission(service: service, decision: $0) })) {
                    ForEach(PermissionDecision.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            case .background(let seconds):
                TextField("Seconds before returning", value: Binding(get: { seconds }, set: { action = .background(seconds: $0) }), format: .number)
                Text("Returns to the app automatically after the delay.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
            }
        }
    }
}

struct TargetList: View {
    @Binding var values: [TargetStrategy]
    var body: some View {
        ForEach(values.indices, id: \.self) { i in
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("\(i + 1). Target").font(WorkbenchStyle.font(.caption, weight: .bold)); Spacer(); Button { values.swapAt(i, i - 1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0); Button { values.swapAt(i, i + 1) } label: { Image(systemName: "arrow.down") }.disabled(i == values.count - 1); Button(role: .destructive) { values.remove(at: i) } label: { Image(systemName: "minus.circle") } }.buttonStyle(.borderless)
                TargetEditor(value: Binding(get: { values.indices.contains(i) ? values[i] : .identifier("") }, set: { if values.indices.contains(i) { values[i] = $0 } }))
            }.padding(.vertical, 6)
        }
        Button("Add Target", systemImage: "plus") { values.append(.identifier("element.identifier")) }
    }
}
struct TargetEditor: View {
    @Binding var value: TargetStrategy
    var kind: Int { switch value { case .identifier: 0; case .semantic: 1; case .text: 2 } }
    var body: some View {
        Picker("Strategy", selection: Binding(get: { kind }, set: { value = $0 == 0 ? .identifier("") : $0 == 1 ? .semantic(role: nil, label: nil, value: nil) : .text("") })) { Text("Identifier").tag(0); Text("Semantic").tag(1); Text("Text").tag(2) }
        if kind == 1 { TextField("Role (optional)", text: semantic(0)); TextField("Label (optional)", text: semantic(1)); TextField("Value (optional)", text: semantic(2)) }
        else { TextField(kind == 0 ? "Accessibility identifier" : "Visible text", text: Binding(get: { switch value { case .identifier(let s), .text(let s): s; default: "" } }, set: { value = kind == 0 ? .identifier($0) : .text($0) })) }
    }
    func semantic(_ index: Int) -> Binding<String> { Binding(get: { if case .semantic(let r, let l, let v) = value { return [r,l,v][index] ?? "" }; return "" }, set: { text in if case .semantic(let r, let l, let v) = value { var parts = [r,l,v]; parts[index] = text.isEmpty ? nil : text; value = .semantic(role: parts[0], label: parts[1], value: parts[2]) } }) }
}
struct AssertionEditor: View {
    @Binding var value: AssertionDefinition
    var kind: Int { switch value { case .exists: 0; case .doesNotExist: 1; case .valueEquals: 2; case .valueContains: 3; case .textVisible: 4; case .imageMatches: 5 } }
    var target: TargetStrategy { switch value { case .exists(let t), .doesNotExist(let t), .valueEquals(let t,_), .valueContains(let t,_): t; default: .identifier("element.identifier") } }
    var text: String { switch value { case .valueEquals(_,let s), .valueContains(_,let s), .textVisible(let s): s; default: "" } }
    func changed(_ kind: Int, _ target: TargetStrategy, _ text: String) -> AssertionDefinition { switch kind { case 0: .exists(target); case 1: .doesNotExist(target); case 2: .valueEquals(target,text); case 3: .valueContains(target,text); case 5: value; default: .textVisible(text) } }
    var body: some View {
        Picker("Check", selection: Binding(get: { kind }, set: { value = changed($0,target,text) })) { Text("Exists").tag(0); Text("Does not exist").tag(1); Text("Value equals").tag(2); Text("Value contains").tag(3); Text("Text visible").tag(4); if kind == 5 { Text("Approved screenshot").tag(5) } }
        if kind < 4 { TargetEditor(value: Binding(get: { target }, set: { value = changed(kind,$0,text) })) }
        if (2...4).contains(kind) { TextField("Expected text", text: Binding(get: { text }, set: { value = changed(kind,target,$0) })) }
        if case .imageMatches(let id, _, let mean, let fraction) = value {
            Text("Reference \(id.uuidString) · mean difference ≤ \(String(format: "%.1f%%", mean * 100)) · changed pixels ≤ \(String(format: "%.1f%%", fraction * 100))").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
        }
    }
}
struct AssertionList: View {
    @Binding var values: [AssertionDefinition]
    var body: some View {
        ForEach(values.indices, id: \.self) { i in
            DisclosureGroup("\(i + 1). \(values[i].summary)") { AssertionEditor(value: Binding(get: { values.indices.contains(i) ? values[i] : .textVisible("") }, set: { if values.indices.contains(i) { values[i] = $0 } })); Button("Remove Assertion", role: .destructive) { values.remove(at: i) } }
        }
        Button("Add Assertion", systemImage: "plus") { values.append(.exists(.identifier("element.identifier"))) }
    }
}
