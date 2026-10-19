import SwiftUI
import AppKit
import AVKit
import ProjectDomain
import RunnerCore
import ArtifactStore
import PerceptionCore
import ModelProviders

struct RunDashboard: View {
    @Bindable var model: WorkspaceModel
    var run: RunWorkspace { model.run }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchStyle.sectionSpacing) {
                VStack(alignment: .leading, spacing: WorkbenchStyle.spacing) {
                    Text(run.status).font(WorkbenchStyle.titleFont).textSelection(.enabled)
                    if let recovery = run.archive?.recovery {
                        WorkbenchNotice(text: recovery.incomplete ? "Recovered incomplete archive. No execution resumed and no completed outcome was created. Observed test results below are historical evidence only." : "Explicitly imported Phase1 legacy evidence. Original ISO bytes and date conversion provenance are preserved.", kind: .warning)
                        DisclosureGroup("Recovery provenance and diagnostics") { Text(recovery.diagnostics.joined(separator: "\n")).font(WorkbenchStyle.monoFont).textSelection(.enabled); Text("Original files: \(recovery.originalManifest.count) · Events: \(recovery.eventCount) · Omitted tail bytes: \(recovery.omittedTailBytes) · Date conversions: \(recovery.dateConversions.count)").font(WorkbenchStyle.infoFont) }
                    }
                    if run.diagnosisSource != nil && (run.diagnosis != nil || run.diagnosisError != nil) {
                        WorkbenchSectionLabel("Interrupted or unsupported archive")
                        WorkbenchNotice(text: run.diagnosis?.summary ?? run.diagnosisError ?? "", kind: .warning)
                        WorkbenchNotice(text: "Recovery creates a separate archive and preserves all original bytes. It never resumes actions or cleans up processes. Retry requires a new run.", kind: .info)
                        HStack {
                            Button("Recover into New Archive…") { do { try run.recoverArchive() } catch { model.report(error) } }.disabled(run.active || run.diagnosis?.matchingLiveOwner == true)
                            Button("Import Phase1 ISO Archive…") { do { try run.recoverArchive(legacy: true) } catch { model.report(error) } }.disabled(run.active)
                        }.workbenchSheetButtons()
                    }
                    if let error = run.persistenceFailure { WorkbenchNotice(text: error, kind: .danger) }
                    if let warning = run.indexWarning { WorkbenchNotice(text: warning, kind: .info) }
                    HStack {
                        if run.active {
                            if !run.goalNavigation {
                                if run.state == .paused { Button("Resume", action: run.resume); Button("Step One Block", action: run.step) }
                                else { Button("Pause", action: run.pause).disabled(run.state == .stopping) }
                            }
                            Button("Stop", role: .destructive, action: run.stop).buttonStyle(WorkbenchButtonStyle(destructive: true))
                        } else {
                            Button("Retry This Snapshot") {
                                do {
                                    try run.retry()
                                } catch { model.report(error) }
                            }.disabled(run.snapshot == nil || run.baseDirectory == nil)
                            Button("Export Run…") { do { try run.export() } catch { model.report(error) } }.disabled(run.directory == nil)
                        }
                    }.workbenchSheetButtons()
                    if run.selectedSequence != nil { Button(run.active ? "Return to Live Preview" : "Show Latest Capture", action: run.returnToLive).workbenchSheetButtons() }
                    if let test = run.currentTest { Text("Test: \(run.title(test))").workbenchInfo() }
                    if let block = run.currentBlock, !run.goalNavigation { Text("Block: \(run.title(block))").workbenchInfo() }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let first = run.events.first { Text(String(format: "Elapsed %.1f s", (run.active ? context.date : run.events.last?.timestamp ?? first.timestamp).timeIntervalSince(first.timestamp))).font(WorkbenchStyle.font(.caption).monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .workbenchCard()
                if let player = run.player {
                    NativeRunVideoPlayer(player: player).frame(height: 240).clipShape(WorkbenchStyle.shape())
                        .workbenchCard(padding: WorkbenchStyle.cardPadding)
                }
                if let anchor = run.anchor { Text(String(format: "Video seeks use recording acknowledgement; startup uncertainty ≤ %.3f s.", anchor.markerObservedAt.timeIntervalSince(anchor.processStartedAt))).workbenchInfo() }
                else if !run.active && run.player != nil { Text("Recording anchor unavailable; use video controls to inspect manually.").workbenchInfo() }
                if let id = run.latestCapture {
                    CaptureImage(run: run, id: id).frame(maxHeight: 330).clipShape(WorkbenchStyle.shape())
                        .workbenchCard(padding: WorkbenchStyle.cardPadding)
                }
                if let review = run.review {
                    HStack(spacing: 14) {
                        ForEach([RunOutcome.passed, .failed, .blocked, .needsReview, .cancelled], id: \.rawValue) { outcome in
                            HStack(spacing: 5) {
                                Circle().fill(outcomeColor(outcome)).frame(width: 6, height: 6)
                                Text(outcome.displayName).font(WorkbenchStyle.rowFont).foregroundStyle(.secondary)
                                Text("\(review.count(outcome))").font(WorkbenchStyle.font(.caption).monospacedDigit())
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(review.tests) { test in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(run.events.filter { envelope in
                                        switch envelope.event { case .goalAssessment(let value): return value.testID == test.id; case .failureSummary(let value): return value.source.testID == test.id; default: return false }
                                    }, id: \.sequence) { envelope in
                                        WorkbenchRow(title: eventLabel(envelope.event, run: run), isHighlighted: run.selectedSequence == envelope.sequence, titleLineLimit: 2, action: { run.inspect(envelope) })
                                    }
                                    ForEach(test.blocks) { block in
                                        WorkbenchRow(
                                            title: block.title,
                                            subtitle: "\(block.skipped ? "Skipped" : block.outcome?.displayName ?? "Pending")\(block.duration.map { String(format: " · %.2fs", $0) } ?? "")",
                                            titleLineLimit: 2,
                                            action: { if let sequence = block.firstSequence, let event = run.events.first(where: { $0.sequence == sequence }) { run.inspect(event) } }
                                        )
                                        if let reason = block.reason { Text(reason).font(WorkbenchStyle.infoFont).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 10).padding(.bottom, 4) }
                                    }
                                }
                                .padding(WorkbenchStyle.cardPadding)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text("\(test.categoryName) / \(test.suiteName) / \(test.name)").font(WorkbenchStyle.rowFont)
                                    Text("\(test.outcome?.displayName ?? "Pending")\(test.duration.map { String(format: " · %.2fs", $0) } ?? "")").font(WorkbenchStyle.font(.caption2)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .workbenchCard()
                }
                DisclosureGroup {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(run.events, id: \.sequence) { envelope in
                            WorkbenchRow(
                                title: eventLabel(envelope.event, run: run),
                                leading: "\(envelope.sequence)",
                                isHighlighted: run.selectedSequence == envelope.sequence,
                                titleLineLimit: 2,
                                trailing: { Text(String(format: "%.2fs", envelope.timestamp.timeIntervalSince(run.events.first?.timestamp ?? envelope.timestamp))).font(WorkbenchStyle.font(.caption).monospacedDigit()).foregroundStyle(.secondary) },
                                action: { run.inspect(envelope) }
                            )
                        }
                    }
                    .padding(.top, WorkbenchStyle.spacing)
                } label: {
                    Text("Event timeline · \(run.events.count)").font(WorkbenchStyle.rowFont)
                }
                .workbenchCard()
            }.padding(WorkbenchStyle.pagePadding)
        }
        .workbenchCanvas()
        .alert("Automatic choice unavailable", isPresented: Binding(get: { run.providerAlert != nil }, set: { if !$0 { run.providerAlert = nil } })) {
            Button("OK", role: .cancel) { run.providerAlert = nil }
        } message: {
            Text("Recovery continues with the saved safe choice. You can review this run's details if the result needs attention.")
        }
    }
}

private func outcomeColor(_ outcome: RunOutcome) -> Color {
    switch outcome {
    case .passed: .green
    case .failed: .red
    case .blocked: .orange
    case .needsReview: .yellow
    case .cancelled: .secondary
    }
}

/// Native AVKit avoids the SwiftUI VideoPlayer responder crash when results appear.
struct NativeRunVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

@MainActor func eventLabel(_ event: ExecutionEvent, run: RunWorkspace) -> String {
    switch event {
    case .candidateDecision(let value): return "Candidate provider: \(value.reason)"
    case .providerFallback(let value): return "Provider fallback (\(value.fallback)): \(value.reason)"
    case .goalAssessment(let value): return "Goal \(value.outcome.displayName.lowercased()): \(value.reason)"
    case .failureSummary(let value): return "Explanatory summary (\(value.provider)): \(value.text)"
    case .captureProvenance: return "Capture timing and geometry"
    case .perception(let value): return "OCR: \(value.regions.count) text regions"
    case .visualComparison(let value): return "Visual reference \(value.matchesReference ? "matched" : "differed"): \(String(format: "%.2f%%", value.changedPixelFraction * 100)) changed pixels"
    case .perceptionWarmup: return "OCR prewarm completed"
    case .recovery(let value): return "Recovery \(value.status.rawValue): \(value.reason)"
    case .locatorSuggestion: return "Locator update suggested for review"
    case .phase(let phase): return phase.displayName
    case .state(let state): return state.rawValue.capitalized
    case .diagnostic(let text): return text
    case .blocker(.missingSecret(.appleAccountPassword(let account))): return "Missing stored Apple Account password for \(account)"
    case .blocker(.credentialAccessRequired(.appleAccountPassword(let account))): return "Keychain access required for stored Apple Account password for \(account)"
    case .blocker(.secureInputUnavailable): return "Apple Account password field is unavailable to automation"
    case .blocker(.secureInputUnverified): return "Apple Account password input could not be verified"
    case .blocker(.authenticationChallenge(let reason)): return "Authentication needs attention: \(reason)"
    case .blocker(.legalConsentRequired(let reason)): return "Approval required: \(reason)"
    case .blocker(.humanAttestationRequired(let reason)): return "Personal attestation required: \(reason)"
    case .suiteStarted(let id): return "Suite started: \(run.snapshot?.categories.flatMap(\.suites).first { $0.id == id }?.name ?? "Untitled suite")"
    case .testStarted(let id): return "Test started: \(run.title(id))"
    case .blockStarted(let id): return run.blocks.contains { $0.id == id } ? "Started: \(run.title(id))" : "Preparing next action"
    case .blockSkipped(let id): return "Skipped: \(run.title(id))"
    case .attempt(let id, let count): return "\(run.title(id)): attempt \(count)"
    case .blockFinished(let id, let outcome, let duration, let reason):
        if run.blocks.contains(where: { $0.id == id }) {
            return "\(run.title(id)): \(outcome.displayName.lowercased()) (\(String(format: "%.2fs", duration))) \(reason ?? "")"
        }
        return reason ?? "Action \(outcome.displayName.lowercased())"
    case .capture(let snapshot): return "Capture \(snapshot.captureID.description) · \(snapshot.elements.count) visible nodes"
    case .actionStarted(_, let action): return "In progress: \(actionDescription(action))"
    case .action(_, let action): return "Performed: \(actionDescription(action))"
    case .assertion(let assertion, let passed): return "Assertion \(passed ? "passed" : "failed"): \(assertion.summary)"
    case .testFinished(let id, let outcome): return "Test \(run.title(id)): \(outcome.displayName.lowercased())"
    case .suiteFinished(_, let outcome): return "Suite finished: \(outcome.displayName.lowercased())"
    case .finished(let report): return "Engine finished: \(report.outcome.displayName.lowercased())"
    }
}

/// Describe the operation without exposing typed content or secure input.
func actionDescription(_ action: DrivenAction) -> String {
    func target(_ element: UIElement) -> String {
        let name = [element.label, element.identifier].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return name.map { "“\($0)”" } ?? "\(element.role) control"
    }
    switch action {
    case .tap(let identifier): return "Tap “\(identifier)”"
    case .tapElement(let element), .recoveryTap(_, let element): return "Tap \(target(element))"
    case .textTap(_, _, let text, _, _): return "Tap visible text “\(text)”"
    case .visualTextTap(_, _, let text, _, _, _): return "Tap control around “\(text)”"
    case .secureTextTap: return "Enter stored Apple Account password"
    case .typeText(_, let identifier): return "Enter text in “\(identifier)”"
    case .typeTextElement(_, let element): return "Enter text in \(target(element))"
    case .swipe(let direction, _), .swipeElement(let direction, _): return "Swipe \(direction.rawValue)"
    case .relaunch: return "Relaunch app"
    case .device(let operation):
        switch operation {
        case .openURL: return "Open deep link"
        case .setLocation: return "Set simulated location"
        case .clearLocation: return "Clear simulated location"
        case .permission(let service, let decision): return "\(decision.rawValue.capitalized) \(service.rawValue) permission"
        case .background(let seconds): return "Background app for \(String(format: "%.1f", seconds)) seconds"
        }
    }
}

struct CaptureImage: View {
    let run: RunWorkspace
    let id: CaptureID
    var body: some View {
        if let url = run.captureURL(id), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Run screenshot \(id.description)") }
        else { Text("Screenshot unavailable").foregroundStyle(.secondary) }
    }
}

struct RunEvidenceInspector: View {
    @Bindable var model: WorkspaceModel
    @State private var repairRequest: TargetRepairRequest?
    @State private var visualQuestion = ""
    @State private var visualAssessment: ImageAssessment?
    @State private var visualAnalysisError: String?
    @State private var analyzingVisual = false
    var run: RunWorkspace { model.run }
    var envelope: ExecutionEnvelope? { run.events.first { $0.sequence == run.selectedSequence } }
    var capture: UISnapshot? {
        guard let id = run.latestCapture else { return nil }
        return run.events.compactMap { if case .capture(let s) = $0.event, s.captureID == id { return s }; return nil }.first
    }
    var referenceCapture: ScreenCapture? {
        guard let capture,
              let provenance = run.events.compactMap({ envelope -> CompanionCapture? in
                  if case .captureProvenance(let value) = envelope.event, value.snapshot.captureID == capture.captureID { return value }
                  return nil
              }).first,
              provenance.screenshotName == "\(capture.captureID.description).png",
              provenance.pixelWidth > 0, provenance.pixelHeight > 0 else { return nil }
        return ScreenCapture(id: capture.captureID, createdAt: capture.capturedAt,
            pixelSize: PixelSize(width: provenance.pixelWidth, height: provenance.pixelHeight),
            screenshotRelativePath: "captures/\(provenance.screenshotName)")
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchStyle.sectionSpacing) {
                Text("Run evidence").font(WorkbenchStyle.titleFont)
                if let directory = run.directory, let diagnostics = SimulatorDiagnosticsManifest.read(in: directory) {
                    VStack(alignment: .leading, spacing: 8) {
                        WorkbenchSectionLabel("Device diagnostics")
                        if let cause = diagnostics.suspectedCause {
                            WorkbenchNotice(text: cause, kind: .warning)
                        }
                        Text("Simulator log: \(diagnostics.deviceLogStatus)").font(WorkbenchStyle.infoFont)
                        if let log = run.archive?.evidenceURL(relativePath: "device.log"),
                           let contents = try? String(contentsOf: log, encoding: .utf8) {
                            DisclosureGroup("Device log") { Text(contents).font(WorkbenchStyle.monoFont).textSelection(.enabled) }
                        }
                        ForEach(diagnostics.crashReports, id: \.self) { path in
                            if let url = run.archive?.evidenceURL(relativePath: path),
                               let contents = try? String(contentsOf: url, encoding: .utf8) {
                                DisclosureGroup("Crash report: \(url.lastPathComponent)") {
                                    Text(contents).font(WorkbenchStyle.monoFont).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .workbenchCard()
                }
                ForEach(["app-build.log", "companion-build.log", "companion.log", "recording.log", "cleanup.log"], id: \.self) { name in
                    if let url = run.archive?.evidenceURL(relativePath: name), let contents = try? String(contentsOf: url, encoding: .utf8) { DisclosureGroup { Text(contents).font(WorkbenchStyle.monoFont).textSelection(.enabled) } label: { Text(name).font(WorkbenchStyle.rowFont) } }
                }
                if let envelope {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(eventLabel(envelope.event, run: run)).font(WorkbenchStyle.rowFont).textSelection(.enabled)
                        StructuredEvidence(event: envelope.event, run: run)
                        if case .locatorSuggestion(let suggestion) = envelope.event {
                            Button("Review Suggested Target…") { review(suggestion) }
                                .buttonStyle(WorkbenchButtonStyle())
                                .disabled(run.active || model.project == nil || model.selectedTest?.blocks.contains(where: { $0.id == suggestion.blockID }) != true)
                        }
                        if let bytes = try? JSONEncoder().encode(envelope), let text = String(data: bytes, encoding: .utf8) { DisclosureGroup { Text(text).font(WorkbenchStyle.monoFont).textSelection(.enabled) } label: { Text("Raw event").font(WorkbenchStyle.rowFont) } }
                        if let id = blockID(envelope.event) {
                            if let before = run.evidence(for: id).before { Text("Before").workbenchInfo(); CaptureImage(run: run, id: before).clipShape(WorkbenchStyle.shape(WorkbenchStyle.rowRadius)) }
                            if let after = run.evidence(for: id).after { Text("After").workbenchInfo(); CaptureImage(run: run, id: after).clipShape(WorkbenchStyle.shape(WorkbenchStyle.rowRadius)) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .workbenchCard()
                }
                if let capture {
                    CaptureImage(run: run, id: capture.captureID)
                        .frame(maxHeight: 330)
                        .clipShape(WorkbenchStyle.shape())
                    if referenceCapture != nil, !run.active {
                        VStack(alignment: .leading, spacing: 8) {
                            WorkbenchSectionLabel("Ask about this screenshot")
                            TextField("What should be visible?", text: $visualQuestion)
                            Button(analyzingVisual ? "Analyzing…" : "Analyze Screenshot") { analyzeScreenshot() }
                                .buttonStyle(WorkbenchButtonStyle())
                                .disabled(analyzingVisual || visualQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Text("Checks this saved screenshot to answer your question.")
                                .font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
                            if let visualAssessment {
                                Text("\(visualAssessment.verdict.rawValue): \(visualAssessment.reason) (confidence \(String(format: "%.0f%%", visualAssessment.confidence * 100)))")
                                    .font(WorkbenchStyle.infoFont).textSelection(.enabled)
                            }
                            if let visualAnalysisError { WorkbenchNotice(text: visualAnalysisError, kind: .warning) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .workbenchCard()
                    }
                    if referenceCapture != nil, model.selectedTest != nil, model.bundleURL != nil,
                       run.snapshot?.id == model.project?.id {
                        Button("Add Visual Assertion from This Screenshot") { approveVisualReference() }
                            .buttonStyle(WorkbenchButtonStyle())
                            .disabled(run.active)
                        Text("Copies this run screenshot into the project as an approved reference for the selected test.")
                            .font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
                    }
                    WorkbenchSectionLabel("\(capture.elements.count) captured semantic nodes")
                    if let url = run.captureURL(capture.captureID, raw: true), let raw = try? String(contentsOf: url, encoding: .utf8) { DisclosureGroup { Text(raw).font(WorkbenchStyle.monoFont).textSelection(.enabled) } label: { Text("Raw capture JSON").font(WorkbenchStyle.rowFont) } }
                    ForEach(Array(capture.elements.enumerated()), id: \.offset) { _, node in
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(node.identifier ?? node.label ?? node.role).font(WorkbenchStyle.rowFont)
                                Text("\(node.role) · \(node.label ?? "") · \(node.value ?? "")").font(WorkbenchStyle.font(.caption2)).foregroundStyle(.secondary)
                            }
                            Button("Use This Target…") {
                                guard let project = model.project, let test = model.selectedTest else { return }
                                repairRequest = TargetRepairRequest(projectID: project.id, test: test, captureID: capture.captureID, node: node, initialBlockID: model.selectedBlockID)
                            }
                            .buttonStyle(WorkbenchButtonStyle())
                            .disabled(model.selectedTest == nil || run.active || node.originBundleIdentifier == "com.apple.springboard")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .workbenchInset()
                    }
                }
                Text(run.directory?.path ?? "No run").font(WorkbenchStyle.font(.caption2)).foregroundStyle(.tertiary).textSelection(.enabled)
            }.padding(WorkbenchStyle.pagePadding)
        }
        .workbenchCanvas()
        .sheet(item: $repairRequest) { request in TargetRepairSheet(model: model, request: request) }
    }
    func analyzeScreenshot() {
        guard !run.active, let capture = referenceCapture,
              let imageURL = run.captureURL(capture.id) else { return }
        let question = visualQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        visualAssessment = nil; visualAnalysisError = nil; analyzingVisual = true
        Task { @MainActor in
            defer { analyzingVisual = false }
            do {
                let image = try Data(contentsOf: imageURL)
                let request = ImageAssessmentRequest(capture: capture, imageData: image,
                    question: question, deadline: Date().addingTimeInterval(30), purpose: .archivedReadOnly)
                let primary: any ImageAssessing = ScreenshotProvider.selected == .jev ? JevVisionProvider() : ClefVisionProvider()
                let fallback: any ImageAssessing = ScreenshotProvider.selected == .jev ? ClefVisionProvider() : JevVisionProvider()
                visualAssessment = try await ImageAssessmentRouter(primary: primary,
                    fallback: fallback, primaryMinimumConfidence: 0.4,
                    fallbackMinimumConfidence: 0)
                    .assess(request, choice: .allowRemoteForThisRun)
            } catch { visualAnalysisError = error.localizedDescription }
        }
    }
    func approveVisualReference() {
        guard !run.active, let capture = referenceCapture, let runDirectory = run.directory,
              let projectDirectory = model.bundleURL, let project = model.project,
              run.snapshot?.id == project.id, let test = model.selectedTest else { return }
        do {
            let reference = try VisualReferenceStore().approve(capture: capture,
                runDirectory: runDirectory, projectDirectory: projectDirectory)
            let assertion = AssertionDefinition.imageMatches(referenceID: reference.id,
                referenceSHA256: reference.sha256,
                maximumMeanChannelDifference: 0.02, maximumChangedPixelFraction: 0.01)
            model.updateTest(test.id) { $0.replacing(assertions: $0.assertions + [assertion]) }
            _ = model.save()
        } catch { model.report(error) }
    }
    func blockID(_ event: ExecutionEvent) -> UUID? { switch event { case .blockStarted(let id), .blockFinished(let id, _, _, _), .action(let id, _), .actionStarted(let id, _), .attempt(let id, _): return id; default: return nil } }
    func review(_ suggestion: LocatorSuggestion) {
        guard let project = model.project, let test = model.selectedTest,
              test.blocks.contains(where: { $0.id == suggestion.blockID }),
              let snapshot = run.events.compactMap({ if case .capture(let value) = $0.event, value.captureID == suggestion.sourceCaptureID { return value }; return nil }).first else { return }
        let nodes = snapshot.elements.filter { node in
            switch suggestion.proposedTarget {
            case .identifier(let id): return node.identifier == id
            case .semantic(let role, let label, let value): return node.role == role && node.label == label && node.value == value
            case .text(let text): return node.label == text || node.value == text
            }
        }
        guard nodes.count == 1, nodes[0].originBundleIdentifier != "com.apple.springboard" else { return }
        repairRequest = TargetRepairRequest(projectID: project.id, test: test, captureID: suggestion.sourceCaptureID, node: nodes[0], initialBlockID: suggestion.blockID, suggestedTarget: suggestion.proposedTarget)
    }
}

struct TargetRepairRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let test: ProjectDomain.TestCase
    let captureID: CaptureID
    let node: UIElement
    let initialBlockID: UUID?
    var suggestedTarget: TargetStrategy? = nil
}

struct TargetRepairSheet: View {
    @Bindable var model: WorkspaceModel
    let request: TargetRepairRequest
    @Environment(\.dismiss) private var dismiss
    @State private var blockID: UUID?
    init(model: WorkspaceModel, request: TargetRepairRequest) {
        self.model = model; self.request = request
        _blockID = State(initialValue: request.test.blocks.first { $0.id == request.initialBlockID && Self.isTargetAction($0.action) }?.id)
    }
    var target: TargetStrategy {
        if let suggested = request.suggestedTarget { return suggested }
        if let id = request.node.identifier, !id.isEmpty { return .identifier(id) }
        return .semantic(role: request.node.role, label: request.node.label, value: request.node.value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkbenchSheetHeader(title: "Review target update", subtitle: "Choose the saved block to update from this captured node. Applying changes only its target; save the project to retain the edit.")
            VStack(alignment: .leading, spacing: 12) {
                Text("Test: \(request.test.name)").font(WorkbenchStyle.rowFont)
                Picker("Block", selection: $blockID) {
                    Text("Choose block").tag(nil as UUID?)
                    ForEach(request.test.blocks.filter { Self.isTargetAction($0.action) }) { Text($0.title).tag(Optional($0.id)) }
                }
                Rectangle().fill(WorkbenchStyle.hairline).frame(height: 1)
                Text(target.summary).font(WorkbenchStyle.infoFont).textSelection(.enabled)
                Text("Capture: \(request.captureID.description)").font(WorkbenchStyle.font(.caption2)).foregroundStyle(.secondary)
            }.workbenchCard()
            HStack { Button("Cancel") { dismiss() }.workbenchSheetButtons(); Spacer(); Button("Apply Target Update", action: applyRepair).buttonStyle(WorkbenchButtonStyle(prominent: true)).disabled(blockID == nil) }
        }.padding(WorkbenchStyle.sheetPadding).frame(width: 460)
    }
    static func isTargetAction(_ action: BlockAction) -> Bool { switch action { case .tap, .typeText, .swipe: return true; default: return false } }
    func applyRepair() {
        guard request.node.originBundleIdentifier != "com.apple.springboard" else { model.error = "System alert nodes are read-only and cannot become input targets."; return }
        let test = request.test
        guard let project = model.project, project.id == request.projectID, model.test(test.id) == test, let id = blockID, let block = test.blocks.first(where: { $0.id == id }) else { model.error = "The test changed during review. Close and review the target update again."; return }
        let targets = [target]
        let action: BlockAction
        switch block.action { case .tap: action = .tap(targets: targets); case .typeText(let text, _): action = .typeText(text, targets: targets); case .swipe(let direction, _): action = .swipe(direction, targets: targets); default: return }
        let updated = test.replacing(blocks: test.blocks.map { $0.id == id ? $0.replacing(action: action) : $0 })
        do { try project.updatingTest(test.id) { _ in updated }.validate(); model.updateTest(updated); dismiss() } catch { model.report(error) }
    }
}
