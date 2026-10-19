import SwiftUI
import ProjectDomain
import ModelProviders
import UniformTypeIdentifiers

struct DraftReviewView: View {
    @Bindable var model: WorkspaceModel
    let testID: UUID
    let initialPrompt: String
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var sourceProjectID: UUID?
    @State private var sourceTest: TestCase?
    @State private var draft: DraftPlan?
    @State private var selectedID: UUID?
    @GestureState private var draggedID: UUID?
    @State private var dragLocation: CGPoint?
    @State private var blockFrames: [UUID: CGRect] = [:]
    @State private var viewport = CGRect.zero
    @State private var endDropID = UUID()
    @State private var dragScope = UUID().uuidString
    var insertion: BlockInsertion? { guard draggedID != nil, let dragLocation else { return nil }; return BlockDragLayout.insertion(at: dragLocation, ids: draft?.blocks.map(\.id) ?? [], frames: blockFrames, endID: endDropID, viewport: viewport) }
    @State private var append = true
    @State private var error: String?
    @State private var generation: Task<Void, Never>?
    @State private var token = UUID()
    @State private var availability = ApplePlanGenerator().availability
    let provider = ApplePlanGenerator()
    var sourceValid: Bool { model.project?.id == sourceProjectID && model.selection == testID && model.test(testID) == sourceTest && sourceTest != nil }
    var validationError: String? { guard let draft else { return nil }; do { try draft.validate(); return nil } catch { return error.localizedDescription } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) { WorkbenchSheetHeader(title: "Draft a test", subtitle: "Apple on-device model · Text only · Review before applying"); Spacer(); Button("Close") { cancel(); dismiss() }.workbenchSheetButtons() }
            TextField("Describe the steps and exact target identifiers where known…", text: $prompt, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
            HStack {
                if generation != nil { ProgressView().controlSize(.small); Text("Generating a typed draft…").workbenchInfo(); Button("Cancel Generation", action: cancel) }
                else { Button("Generate Draft", systemImage: "sparkles", action: generate).buttonStyle(WorkbenchButtonStyle(prominent: true)).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || availability != .available || !sourceValid) }
                Spacer()
                Button("Refresh Model Availability") { availability = provider.availability }
            }.workbenchSheetButtons()
            if case .unavailable(let reason) = availability { Text(reason).workbenchInfo() }
            if !sourceValid { WorkbenchNotice(text: "The source test or project changed. Close this draft and generate from the current test.", kind: .warning) }
            if let error { WorkbenchNotice(text: error, kind: .danger) }
            if let draft {
                Rectangle().fill(WorkbenchStyle.hairline).frame(height: 1)
                HStack {
                    WorkbenchSectionLabel("Review \(draft.blocks.count) proposed blocks")
                    Spacer()
                    CustomMenu(
                        items: BlockKind.allCases.map { kind in
                            .button(kind.rawValue, systemImage: kind.icon) {
                                let block = TestBlock(title: kind.rawValue, action: kind.action)
                                self.draft?.blocks.append(block)
                                selectedID = block.id
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
                Text("Proposed targets have not been checked against your app. Select any block to edit it. Saved preconditions, final assertions and policies stay attached to this test.").workbenchInfo()
                HSplitView {
                    GeometryReader { viewportProxy in
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(Array(draft.blocks.enumerated()), id: \.element.id) { i, block in
                                BlockCard(block: block, index: i, selected: selectedID == block.id, drag: dragGesture(block.id), select: { selectedID = block.id }, edit: { edit in update(block.id, edit) }, duplicate: { guard let index = self.draft?.blocks.firstIndex(where: { $0.id == block.id }) else { return }; let copy = block.duplicated(); self.draft?.blocks.insert(copy, at: index + 1); selectedID = copy.id }, delete: { self.draft?.blocks.removeAll { $0.id == block.id } })
                                    .blockFrame(block.id, space: dragScope).insertionMarker(insertion == .before(block.id)).opacity(draggedID == block.id ? 0.65 : 1)
                            }
                            Text("Drop to move to end").workbenchInfo().frame(maxWidth: .infinity).padding(12).background(WorkbenchStyle.inset, in: WorkbenchStyle.shape(WorkbenchStyle.rowRadius)).overlay(WorkbenchStyle.shape(WorkbenchStyle.rowRadius).strokeBorder(WorkbenchStyle.hairline, lineWidth: 1)).blockFrame(endDropID, space: dragScope).insertionMarker(insertion == .end)
                        }.padding(4).onPreferenceChange(BlockFramesPreference.self) { blockFrames = $0 }
                    }.coordinateSpace(name: dragScope)
                    .onAppear { viewport = CGRect(origin: .zero, size: viewportProxy.size) }
                    .onChange(of: viewportProxy.size) { viewport = CGRect(origin: .zero, size: viewportProxy.size) }
                    }.frame(minWidth: 370)
                    if let id = selectedID, let fallback = draft.blocks.first(where: { $0.id == id }) {
                        Form { BlockConfiguration(block: Binding(get: { self.draft?.blocks.first { $0.id == id } ?? fallback }, set: { value in update(id) { _ in value } })) }.formStyle(.grouped).frame(width: 300)
                    } else { Text("Select a draft block to edit its configuration.").foregroundStyle(.secondary).frame(width: 280) }
                }
                if let validationError { WorkbenchNotice(text: "Draft needs attention: \(validationError)", kind: .danger) }
                HStack {
                    Picker("Apply as", selection: $append) { Text("Append to current blocks").tag(true); Text("Replace current blocks").tag(false) }.frame(width: 350)
                    Spacer()
                    Button(append ? "Append Reviewed Draft" : "Replace with Reviewed Draft", action: apply).buttonStyle(WorkbenchButtonStyle(prominent: true)).disabled(validationError != nil || !sourceValid || generation != nil)
                }
                Text(append ? "Adds these blocks after the latest saved or unsaved blocks." : "Replaces only this test’s blocks. Its identity, goal, preconditions, final assertions, timeout and recovery policy are preserved.").workbenchInfo()
            } else { ContentUnavailableView("Your draft appears here", systemImage: "sparkles", description: Text("Generation does not change the test. You decide when to apply the reviewed blocks.")) }
        }.padding(WorkbenchStyle.sheetPadding).frame(width: 930, height: 730)
        .onAppear { prompt = initialPrompt; sourceProjectID = model.project?.id; sourceTest = model.test(testID) }
        .onChange(of: prompt) { cancel(); draft = nil }
        .onChange(of: model.selection) { cancel(); dragLocation = nil }
        .onChange(of: model.project?.id) { cancel() }
        .onChange(of: model.test(testID)) { cancel() }
        .onDisappear { cancel() }
    }
    func cancel() { token = UUID(); generation?.cancel(); generation = nil }
    func generate() {
        cancel(); error = nil; draft = nil
        guard let sourceProjectID, let sourceTest, sourceValid else { return }
        let current = token, request = prompt
        let sourceBundleURL = model.bundleURL
        let context = DraftRequestContext(projectID: sourceProjectID, source: sourceTest, prompt: request, token: current)
        generation = Task { @MainActor in
            do {
                let generated = try await provider.generate(prompt: request)
                guard !Task.isCancelled, context.matches(projectID: model.project?.id, selection: model.selection, test: model.test(testID), prompt: prompt, token: token) else { return }
                draft = generated; selectedID = generated.blocks.first?.id; generation = nil
            } catch {
                guard token == current else { return }
                if !(error is CancellationError) {
                    self.error = error.localizedDescription
                    do { let directory = try PlanningDiagnostics.store(prompt: request, failure: error, bundleURL: sourceBundleURL); self.error = "\(error.localizedDescription)\nPlanning diagnostics: \(directory.path)" }
                    catch { self.error = "\(self.error ?? "Planning failed")\nCould not save diagnostics: \(error.localizedDescription)" }
                }
                generation = nil
            }
        }
    }
    func update(_ id: UUID, _ edit: (TestBlock) -> TestBlock) { guard let i = draft?.blocks.firstIndex(where: { $0.id == id }), let block = draft?.blocks[i] else { return }; draft?.blocks[i] = edit(block) }
    func move(_ id: UUID, _ destination: UUID?) { guard draft?.blocks.contains(where: { $0.id == id }) == true else { DragTrace.record("draft-move-rejected", ["source": id.uuidString]); return }; let before = draft?.blocks.map { $0.id.uuidString }.joined(separator: ",") ?? ""; draft?.blocks = draft?.blocks.moving(id, before: destination) ?? []; selectedID = id; DragTrace.record("draft-move-result", ["source": id.uuidString, "before": before, "after": draft?.blocks.map { $0.id.uuidString }.joined(separator: ",") ?? ""]) }
    func dragGesture(_ id: UUID) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(dragScope)).updating($draggedID) { _, state, _ in state = id }.onChanged { value in dragLocation = value.location; DragTrace.record("draft-local-changed", ["source": id.uuidString]) }.onEnded { value in
            defer { dragLocation = nil }
            DragTrace.record("draft-local-drop-geometry", ["source": id.uuidString, "location": String(describing: value.location), "viewport": String(describing: viewport), "sourceValid": String(sourceValid), "sourceExists": String(draft?.blocks.contains(where: { $0.id == id }) == true), "frames": blockFrames.map { "\($0.key.uuidString)=\($0.value)" }.sorted().joined(separator: ";"), "endID": endDropID.uuidString])
            guard sourceValid, draft?.blocks.contains(where: { $0.id == id }) == true,
                  let target = BlockDragLayout.insertion(at: value.location, ids: draft?.blocks.map(\.id) ?? [], frames: blockFrames, endID: endDropID, viewport: viewport) else { DragTrace.record("draft-local-outside-cancelled", ["source": id.uuidString]); return }
            switch target { case .before(let destination): move(id, destination); case .end: move(id, nil) }
            DragTrace.record("draft-local-ended", ["source": id.uuidString])
        })
    }
    func apply() {
        guard sourceValid, let draft, let latest = model.test(testID) else { return }
        do {
            let applied = try draft.applying(to: latest, append: append)
            guard let project = model.project else { return }
            try project.updatingTest(testID) { _ in applied }.validate()
            model.updateTest(testID) { current in current.replacing(blocks: applied.blocks) }; model.selectedBlockID = draft.blocks.first?.id; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
