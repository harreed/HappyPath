import SwiftUI
import AVKit
import AppKit
import ArtifactStore
import RunnerCore
import ProjectDomain

private struct PastRun: Identifiable, Sendable {
    let id: URL
    let title: String
    let outcome: String
    let resultCounts: String?
    let date: Date
    let duration: TimeInterval
    init?(url: URL) {
        guard let summary = try? ExecutionArchiveSummary(directory: url) else { return nil }
        id = url
        title = summary.title
        outcome = summary.outcome
        resultCounts = summary.resultCounts
        date = summary.date
        duration = summary.duration
    }
}

struct PastRunsView: View {
    @Bindable var model: WorkspaceModel
    let open: (URL) -> Void
    @State private var selected: Set<URL> = []
    @State private var selectionAnchor: URL?
    @State private var items: [PastRun] = []
    @State private var loading = true
    @State private var deleting = false
    @State private var confirmingDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Past runs").font(WorkbenchStyle.font(.largeTitle, weight: .bold))
                Text("Saved results for \(model.project?.name ?? "this project")").foregroundStyle(.secondary)
            }.padding(32)
            if loading {
                ProgressView("Loading past runs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView("No saved runs yet", systemImage: "clock.arrow.circlepath", description: Text("Runs will appear here after you start a test."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 30, height: 1)
                        Text("TEST").frame(maxWidth: .infinity, alignment: .leading)
                        Text("RESULT").frame(width: 105, alignment: .leading)
                        Text("DATE").frame(width: 175, alignment: .leading)
                        Text("DURATION").frame(width: 90, alignment: .trailing)
                        Button("Select All") {
                            selected = Set(items.map(\.id))
                            selectionAnchor = items.first?.id
                        }.buttonStyle(.plain).foregroundStyle(WorkbenchStyle.accent).frame(width: 64, alignment: .trailing)
                    }.font(WorkbenchStyle.font(.caption2, weight: .bold)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 12)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                HStack(spacing: 0) {
                                    Toggle("Select \(item.title)", isOn: Binding(
                                        get: { selected.contains(item.id) },
                                        set: { isSelected in
                                            if isSelected { selected.insert(item.id) } else { selected.remove(item.id) }
                                            selectionAnchor = item.id
                                        }
                                    )).labelsHidden().toggleStyle(.checkbox).frame(width: 30)
                                    Button { select(item.id) } label: {
                                        HStack(spacing: 0) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(item.title)
                                                if let counts = item.resultCounts {
                                                    Text(counts).font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
                                                }
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                            Label(item.outcome, systemImage: "circle.fill")
                                                .labelStyle(.titleAndIcon)
                                                .foregroundStyle(item.outcome == "Passed" ? .green : item.outcome == "Failed" ? .red : .orange)
                                                .frame(width: 105, alignment: .leading)
                                            Text(item.date.formatted(date: .abbreviated, time: .shortened)).frame(width: 175, alignment: .leading)
                                            Text(duration(item.duration)).monospacedDigit().frame(width: 90, alignment: .trailing)
                                            Color.clear.frame(width: 64, height: 1)
                                        }.padding(.vertical, 18)
                                            .frame(maxWidth: .infinity)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }.padding(.horizontal, 18)
                                    .frame(maxWidth: .infinity)
                                    .background(Rectangle().fill(selected.contains(item.id) ? WorkbenchStyle.selected : Color.clear))
                                Divider()
                            }
                        }
                    }
                }.background(WorkbenchStyle.panel, in: WorkbenchStyle.shape())
                    .overlay(WorkbenchStyle.shape().strokeBorder(WorkbenchStyle.border))
                    .padding(.horizontal, 32)
                if !selected.isEmpty {
                    HStack {
                        if selected.count == 1, let item = items.first(where: { selected.contains($0.id) }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(WorkbenchStyle.font(.headline, weight: .semibold))
                                Text("\(item.outcome) · \(item.date.formatted(date: .abbreviated, time: .shortened)) · \(duration(item.duration))")
                                    .font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("\(selected.count) runs selected").font(WorkbenchStyle.font(.headline, weight: .semibold))
                        }
                        Spacer()
                        if deleting { ProgressView("Deleting…") }
                        if selected.count == 1, let item = items.first(where: { selected.contains($0.id) }) {
                            Button("View run", action: { open(item.id) }).buttonStyle(.borderedProminent)
                        }
                        Button("Delete Selected", role: .destructive) { confirmingDelete = true }
                            .disabled(deleting || model.run.active)
                    }.padding(24).background(WorkbenchStyle.panel)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).workbenchCanvas()
            .alert("Delete \(selected.count) \(selected.count == 1 ? "run" : "runs")?", isPresented: $confirmingDelete) {
                Button(selected.count == 1 ? "Delete Run" : "Delete Runs", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes the selected runs and all their videos, captures, and reports.")
            }
            .task(id: model.run.history) {
                loading = true
                let urls = model.run.history
                let worker = Task.detached(priority: .userInitiated) {
                    var rows: [PastRun] = []
                    for url in urls {
                        guard !Task.isCancelled else { break }
                        if let row = PastRun(url: url) { rows.append(row) }
                    }
                    return rows.sorted { $0.date > $1.date }
                }
                let loaded = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                items = loaded
                selected.formIntersection(Set(loaded.map(\.id)))
                if selected.isEmpty, let first = loaded.first?.id { selected = [first] }
                if selectionAnchor.map({ !selected.contains($0) }) ?? true { selectionAnchor = loaded.first?.id }
                loading = false
            }
    }
    private func select(_ id: URL) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let start = items.firstIndex(where: { $0.id == anchor }),
           let end = items.firstIndex(where: { $0.id == id }) {
            selected = Set(items[min(start, end)...max(start, end)].map(\.id))
        } else if modifiers.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            selectionAnchor = id
        } else {
            selected = [id]
            selectionAnchor = id
        }
    }
    private func deleteSelected() {
        guard let base = model.bundleURL, !model.run.active, !selected.isEmpty else { return }
        let targets = Array(selected)
        deleting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                RunArchiveDeletion.delete(targets, projectURL: base)
            }.value
            if model.bundleURL == base { model.run.didDeleteRuns(result.deleted, base: base) }
            selected.subtract(result.deleted)
            if !result.failures.isEmpty { model.error = result.failures.joined(separator: "\n") }
            deleting = false
        }
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }
}

struct RunExperienceView: View {
    @Bindable var model: WorkspaceModel
    @State private var activityMode = 0
    @State private var rightPanel = 0
    @State private var resultFilter = 0
    @State private var showingEvidence = false
    @State private var showingAttestation = false
    private var run: RunWorkspace { model.run }
    private var visibleTests: [ReviewedTest] {
        guard let tests = run.review?.tests else { return [] }
        switch resultFilter {
        case 1: return tests.filter { $0.outcome == .passed }
        case 2: return tests.filter { $0.outcome == .failed }
        case 3: return tests.filter { $0.outcome == .needsReview }
        case 4: return tests.filter { $0.outcome == .blocked || $0.outcome == .cancelled || $0.outcome == nil }
        default: return tests
        }
    }
    private var runTitle: String {
        if let id = run.currentTest { return run.title(id) }
        if let selected = try? run.snapshot?.selectedTests(run.selection), selected.count == 1 { return selected[0].test.name }
        if let snapshot = run.snapshot {
            switch run.selection {
            case .suite(let id):
                return snapshot.categories.flatMap(\.suites).first(where: { $0.id == id })?.name ?? snapshot.name
            case .category(let id):
                return snapshot.categories.first(where: { $0.id == id })?.name ?? snapshot.name
            default: break
            }
        }
        return run.snapshot?.name ?? "Run"
    }
    private var activity: [ExecutionEnvelope] {
        let completedActions = Set(run.events.compactMap { envelope -> UUID? in
            if case .action(let id, _) = envelope.event { return id }
            return nil
        })
        return run.events.filter { envelope in
            switch envelope.event {
            case .actionStarted(let id, _): return activityMode == 1 || !completedActions.contains(id)
            case .blockStarted: return activityMode == 1
            case .phase, .state, .testStarted, .action, .assertion, .blocker,
                 .testFinished, .candidateDecision, .providerFallback, .goalAssessment,
                 .failureSummary, .recovery, .finished: return true
            case .attempt, .blockFinished, .blockSkipped, .capture, .perception, .suiteStarted,
                 .suiteFinished: return activityMode == 1
            default: return false
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(runTitle).font(WorkbenchStyle.font(.title2, weight: .bold)).lineLimit(1)
                    Text(run.status).font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if run.active {
                    Label(run.state == .paused ? "Paused" : "Running", systemImage: "circle.fill")
                        .font(WorkbenchStyle.font(.caption, weight: .semibold))
                        .foregroundStyle(run.state == .paused ? .orange : .green)
                    if run.state == .paused {
                        if run.pendingAttestation != nil {
                            Button("Review declaration") { showingAttestation = true }.buttonStyle(.borderedProminent)
                        } else {
                            Button(run.status.hasPrefix("Approval required:") ? "Continue with Apple" : "Resume", action: run.resume)
                                .buttonStyle(.bordered)
                        }
                    }
                    else if !run.goalNavigation { Button("Pause", action: run.pause).buttonStyle(.bordered) }
                    Button("Stop run", role: .destructive, action: run.stop).buttonStyle(.borderedProminent)
                } else {
                    Text(run.report?.outcome.displayName ?? "Saved run").font(WorkbenchStyle.font(.caption, weight: .semibold))
                }
                if run.selectedSequence != nil { Button("Return to live", action: run.returnToLive).buttonStyle(.bordered) }
                Button(showingEvidence ? "Overview" : "Full evidence", systemImage: showingEvidence ? "rectangle" : "list.bullet.rectangle") { showingEvidence.toggle() }.buttonStyle(.bordered)
            }.padding(.horizontal, 24).padding(.vertical, 15)
            .sheet(isPresented: $showingAttestation) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Confirm this declaration").font(WorkbenchStyle.font(.title2, weight: .bold))
                    Text(run.pendingAttestation ?? "The declaration is no longer available.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Only continue if this statement is true for the person using the test account.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { showingAttestation = false }
                        Spacer()
                        Button("I confirm and accept") {
                            showingAttestation = false
                            run.approveHumanAttestation()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(run.pendingAttestation == nil)
                    }
                }
                .padding(24)
                .frame(width: 520)
            }
            Divider()
            if !run.active, let groups = run.review?.needsReviewExplanationGroups, !groups.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.explanations.count == 1
                                 ? (group.explanations[0].stepName.map { "Needs review in \(group.explanations[0].testName) · \($0)" }
                                    ?? "Needs review in \(group.explanations[0].testName)")
                                 : "Needs review in \(group.explanations.count) tests")
                                .font(WorkbenchStyle.font(.headline, weight: .semibold))
                                .foregroundStyle(.orange)
                            Text(group.reason)
                                .font(WorkbenchStyle.font(.title3, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if group.explanations.count > 1 {
                                Text(group.explanations.map(\.testName).joined(separator: " · "))
                                    .font(WorkbenchStyle.font(.body))
                                    .foregroundStyle(.secondary)
                            }
                            if let fix = group.suggestedFix {
                                Text("What to try: \(fix)")
                                    .font(WorkbenchStyle.font(.body))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.3)))
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                Divider()
            }
            if showingEvidence {
                HSplitView {
                    RunDashboard(model: model).frame(minWidth: 450)
                    RunEvidenceInspector(model: model).frame(minWidth: 290, idealWidth: 330)
                }
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        ZStack {
                            WorkbenchStyle.simulatorField
                            SimulatorDotMatrix()
                            if run.selectedSequence != nil, let capture = run.latestCapture {
                                CaptureImage(run: run, id: capture).simulatorScreenCorners().padding(12)
                            } else if run.active, let image = run.liveImage {
                                Image(nsImage: image).resizable().scaledToFit().simulatorScreenCorners().padding(12)
                            } else if !run.active, let player = run.player {
                                NativeRunVideoPlayer(player: player)
                                    .aspectRatio(9.0 / 19.5, contentMode: .fit)
                                    .simulatorScreenCorners()
                                    .padding(12)
                            } else if let capture = run.latestCapture {
                                CaptureImage(run: run, id: capture).simulatorScreenCorners().padding(12)
                            } else {
                                VStack(spacing: 10) {
                                    Image(systemName: "iphone.gen3").font(WorkbenchStyle.font(size: 44)).foregroundStyle(.secondary)
                                    Text(run.active ? "Connecting to Simulator…" : "No video available").foregroundStyle(.secondary)
                                }
                            }
                            if run.active {
                                VStack { HStack { Label("LIVE", systemImage: "circle.fill").font(WorkbenchStyle.font(.caption, weight: .bold)).padding(7).background(WorkbenchStyle.badgeBackground.opacity(0.92), in: Capsule()).foregroundStyle(.white); Spacer() }; Spacer() }.padding(15)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(WorkbenchStyle.shape(12))
                        HStack {
                            Image(systemName: "waveform.path")
                            Text(run.currentBlock.flatMap { id in run.blocks.contains { $0.id == id } ? run.title(id) : nil } ?? run.status).lineLimit(1)
                            Spacer()
                            Text("\(run.events.count) events").monospacedDigit()
                        }.font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    runSidePanel.frame(width: 340)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).workbenchCanvas()
            }
        }
    }

    private var runSidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Run panel", selection: $rightPanel) {
                Text("Test results").tag(0)
                Text("Activity").tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            if rightPanel == 0 { testResultsPanel }
            else { activityPanel }
        }.padding(20).frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var testResultsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let review = run.review {
                Text("\(review.completedCount) of \(review.tests.count) tests complete")
                    .font(WorkbenchStyle.font(.headline, weight: .semibold))
                HStack(spacing: 8) {
                    resultCount("Passed", count: review.count(.passed), color: .green)
                    resultCount("Failed", count: review.count(.failed), color: .red)
                    resultCount("Review", count: review.count(.needsReview), color: .orange)
                }
                Picker("Show results", selection: $resultFilter) {
                    Text("All").tag(0)
                    Text("Passed").tag(1)
                    Text("Failed").tag(2)
                    Text("Needs review").tag(3)
                    Text("Other / pending").tag(4)
                }.labelsHidden()
                if visibleTests.isEmpty {
                    Text("No tests in this group.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(visibleTests.enumerated()), id: \.element.id) { index, test in
                                if index == 0 || visibleTests[index - 1].suiteID != test.suiteID {
                                    Text("\(test.categoryName) / \(test.suiteName)")
                                        .font(WorkbenchStyle.font(.caption, weight: .bold)).foregroundStyle(.secondary)
                                        .padding(.top, index == 0 ? 4 : 18).padding(.bottom, 6)
                                }
                                Button { inspect(test) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: resultSymbol(test.outcome))
                                            .foregroundStyle(resultColor(test.outcome)).frame(width: 16)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(test.name).font(WorkbenchStyle.font(.subheadline, weight: .medium)).foregroundStyle(.primary)
                                                .multilineTextAlignment(.leading)
                                            Text(test.outcome?.displayName ?? (run.currentTest == test.id ? "Running" : "Pending"))
                                                .font(WorkbenchStyle.font(.caption)).foregroundStyle(resultColor(test.outcome))
                                        }
                                        Spacer(minLength: 0)
                                        if let duration = test.duration {
                                            Text(String(format: "%.0fs", duration)).font(WorkbenchStyle.font(.caption).monospacedDigit()).foregroundStyle(.secondary)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }
                Text("Select a test to inspect its latest capture. Use Full evidence for its event timeline.")
                    .font(WorkbenchStyle.font(.caption2)).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("No test results", systemImage: "checklist", description: Text("Start or open a run to see its tests."))
            }
        }
    }

    private func resultCount(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count) \(title)")
        }.font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
    }

    private func resultColor(_ outcome: RunOutcome?) -> Color {
        switch outcome {
        case .passed: .green
        case .failed: .red
        case .needsReview, .blocked: .orange
        case .cancelled, nil: .secondary
        }
    }

    private func resultSymbol(_ outcome: RunOutcome?) -> String {
        switch outcome {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .needsReview, .blocked: "exclamationmark.circle.fill"
        case .cancelled: "minus.circle.fill"
        case nil: "circle.dotted"
        }
    }

    private func inspect(_ test: ReviewedTest) {
        guard let start = run.events.lastIndex(where: {
            if case .testStarted(let id) = $0.event { return id == test.id }
            return false
        }) else { return }
        let end = run.events[start...].firstIndex(where: {
            if case .testFinished(let id, _) = $0.event { return id == test.id }
            return false
        }) ?? run.events.endIndex
        let testEvents = run.events[start..<end]
        let event = testEvents.last(where: {
            switch $0.event {
            case .capture, .goalAssessment, .failureSummary: return true
            default: return false
            }
        }) ?? run.events[start]
        run.inspect(event)
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent activity").font(WorkbenchStyle.font(.headline, weight: .semibold))
            Picker("Activity", selection: $activityMode) {
                Text("Summary").tag(0)
                Text("Details").tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(activity.suffix(activityMode == 0 ? 30 : 100), id: \.sequence) { envelope in
                        Button { run.inspect(envelope) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: activitySymbol(envelope.event))
                                    .font(WorkbenchStyle.font(.caption)).foregroundStyle(activityColor(envelope.event))
                                    .frame(width: 16).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(eventLabel(envelope.event, run: run))
                                        .font(WorkbenchStyle.font(.caption, weight: .medium)).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                    Text(envelope.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(WorkbenchStyle.font(.caption2).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            Text("Recorded actions and explanations when available. Private model reasoning is not shown.")
                .font(WorkbenchStyle.font(.caption2)).foregroundStyle(.secondary)
        }
    }

    private func activitySymbol(_ event: ExecutionEvent) -> String {
        switch event {
        case .action: return "checkmark.circle.fill"
        case .actionStarted, .blockStarted: return "circle.dotted"
        case .blocker: return "exclamationmark.circle.fill"
        case .finished, .testFinished, .assertion: return "checkmark.seal"
        default: return "circle.fill"
        }
    }

    private func activityColor(_ event: ExecutionEvent) -> Color {
        switch event {
        case .action: return .green
        case .blocker: return .orange
        case .actionStarted, .blockStarted: return WorkbenchStyle.accent
        default: return .secondary
        }
    }
}

private extension View {
    func simulatorScreenCorners() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
    }
}
