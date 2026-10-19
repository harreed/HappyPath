import AppKit
import SwiftUI
import SwiftData
import AVKit
import ProjectDomain
import RunnerCore
import SimulatorControl
import ArtifactStore

@Model final class RunIndexEntry {
    @Attribute(.unique) var path: String
    var projectName: String
    var outcome: String
    var date: Date
    init(path: String, projectName: String, outcome: String, date: Date) {
        self.path = path; self.projectName = projectName; self.outcome = outcome; self.date = date
    }
}

@Model final class ProjectIndexEntry {
    @Attribute(.unique) var path: String
    var projectID: UUID
    var name: String
    var lastOpened: Date
    init(path: String, projectID: UUID, name: String) { self.path = path; self.projectID = projectID; self.name = name; lastOpened = Date() }
}

@MainActor @Observable final class RunWorkspace {
    var active = false
    var state: ExecutionState = .finished
    var status = "No run selected"
    var events: [ExecutionEnvelope] = []
    var archive: ExecutionArchive?
    var snapshot: TestProject?
    var selection: RunSelection = .all
    var directory: URL?
    var baseDirectory: URL?
    var report: ExecutionReport?
    var persistenceFailure: String?
    var providerAlert: String?
    var selectedSequence: Int?
    var currentBlock: UUID?
    var currentTest: UUID?
    var latestCapture: CaptureID?
    var liveCapture: CaptureID?
    var indexWarning: String?
    var player: AVPlayer?
    var liveImage: NSImage?
    var anchor: RecordingAnchor?
    var history: [URL] = []
    var diagnosis: ArchiveDiagnosis?
    var diagnosisSource: URL?
    var diagnosisError: String?
    var goalNavigation = false
    private var savedInputs: [GoalSavedInput] = []
    private var handle: ExecutionHandle?
    private var worker: Task<Void, Never>?
    private var previewWorker: Task<Void, Never>?
    private var index: ModelContainer?
    init() {
        do { index = try ModelContainer(for: RunIndexEntry.self, ProjectIndexEntry.self) }
        catch { indexWarning = "Metadata index is unavailable. Project definitions and run evidence remain available from files." }
    }
    var review: ExecutionReview? { guard let snapshot else { return nil }; return try? ExecutionReview(project: snapshot, selection: selection, events: events) }
    var blocks: [TestBlock] { snapshot?.categories.flatMap(\.suites).flatMap { $0.setup + $0.tests.flatMap(\.blocks) + $0.teardown } ?? [] }
    func title(_ id: UUID) -> String { blocks.first { $0.id == id }?.title ?? snapshot?.categories.flatMap(\.suites).flatMap(\.tests).first { $0.id == id }?.name ?? "Untitled action" }
    private var lastBlocker: ExecutionBlocker?
    var pendingAttestation: String? {
        guard active, state == .paused, case .humanAttestationRequired(let statement) = lastBlocker else { return nil }
        return statement
    }
    func start(project: TestProject, selection: RunSelection, base: URL, goalNavigation: Bool = false,
               savedInputs: [GoalSavedInput] = [], imageDisclosureChoice: ImageDisclosureChoice = .allowRemoteForThisRun) throws {
        guard !active else { return }
        let chosen = try project.selectedTests(selection)
        guard !chosen.isEmpty else { throw NSError(domain: "Run", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose at least one test to run."]) }
        guard !chosen.contains(where: { $0.test.effectiveExecutionMode == .goal && $0.test.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NSError(domain: "Run", code: 2, userInfo: [NSLocalizedDescriptionKey: "Add a goal to each selected goal test before running."])
        }
        let url = base.appendingPathComponent("runs").appendingPathComponent(UUID().uuidString)
        let store = try ExecutionArtifactStore(directory: url, project: project, selection: selection)
        self.snapshot = project; self.selection = selection; baseDirectory = base; directory = url
        self.goalNavigation = goalNavigation || (chosen.count == 1 && chosen[0].test.effectiveExecutionMode == .goal)
        self.savedInputs = savedInputs
        archive = nil; events = []; report = nil; persistenceFailure = nil; providerAlert = nil; selectedSequence = nil; lastBlocker = nil
        currentBlock = nil; currentTest = nil; latestCapture = nil; liveCapture = nil; player = nil; liveImage = nil; anchor = nil
        active = true; state = .preparing; status = "Preparing run"
        let diagnosticsStartedAt = Date()
        startLivePreview(simulatorID: project.simulator.deviceID)
        let engine = RunEngineFactory.make(base: base, artifacts: url, savedInputs: savedInputs,
                                           imageDisclosureChoice: imageDisclosureChoice)
        let handle = goalNavigation ? engine.startGoal(project: project) : engine.start(project: project, selection: selection)
        self.handle = handle
        worker = Task {
            do {
                let completed = try await DurableExecution.consume(handle, persistence: store) { envelope in
                    await self.present(envelope)
                }
                report = completed
                archive = try ExecutionArchive(directory: url)
                loadVideo()
                if completed.outcome == .needsReview, let lastBlocker {
                    status = Self.status(for: lastBlocker)
                } else {
                    status = completed.outcome.displayName
                }
                recordIndex()
            } catch {
                handle.cancel()
                _ = await handle.task.value
                await store.closeAfterFailure()
                persistenceFailure = "Run evidence could not be saved: \(error.localizedDescription). Execution stopped and cleanup completed."
                status = "Evidence persistence failed"
                report = nil
            }
            let diagnosticsEndedAt = Date()
            _ = await Task.detached(priority: .utility) {
                try? SimulatorDiagnosticsCollector().collect(in: url, project: project,
                                                            startedAt: diagnosticsStartedAt, endedAt: diagnosticsEndedAt)
            }.value
            active = false; self.handle = nil; state = .finished
            previewWorker?.cancel(); previewWorker = nil; liveImage = nil
            refreshHistory(base: base)
        }
    }
    private func present(_ envelope: ExecutionEnvelope) {
        events.append(envelope)
        receive(envelope.event)
    }
    func receive(_ event: ExecutionEvent) {
        switch event {
        case .phase(let phase): status = phase.displayName
        case .state(let value): state = value; if value == .paused && !status.hasPrefix("Action required:") && !status.hasPrefix("Approval required:") { status = "Paused at a safe boundary" }
        case .diagnostic(let value): status = value
        case .blocker(let value):
            lastBlocker = value
            status = Self.status(for: value)
        case .testStarted(let id): currentTest = id
        case .blockStarted(let id): currentBlock = id; status = blocks.contains { $0.id == id } ? "Running \(title(id))" : "Preparing next action"
        case .actionStarted(_, let action): status = actionDescription(action)
        case .blockFinished: currentBlock = nil
        case .testFinished: currentTest = nil
        case .capture(let capture): liveCapture = capture.captureID; if selectedSequence == nil { latestCapture = capture.captureID }
        case .providerFallback(let value): providerAlert = value.reason
        default: break
        }
    }
    private static func status(for blocker: ExecutionBlocker) -> String {
        switch blocker {
        case .missingSecret(.appleAccountPassword(let account)):
            return "Missing stored Apple Account password for \(account). Add it in Test Settings."
        case .credentialAccessRequired(.appleAccountPassword(let account)):
            return "Allow HappyPath to access the stored Apple Account password for \(account) in macOS Keychain, then rerun."
        case .secureInputUnavailable:
            return "iOS did not expose the Apple Account password field. Complete Apple Account verification in Simulator, then rerun."
        case .secureInputUnverified:
            return "Apple Account password input could not be verified. Complete verification in Simulator, then rerun."
        case .authenticationChallenge(let reason): return reason
        case .legalConsentRequired(let reason), .humanAttestationRequired(let reason): return "Approval required: \(reason)"
        }
    }
    func pause() { guard let handle else { return }; status = "Pause requested; waiting for current block"; Task { await handle.control.pause() } }
    func resume() { guard let handle else { return }; Task { await handle.control.resume() } }
    func approveHumanAttestation() {
        guard pendingAttestation != nil, let handle else { return }
        status = "Continuing after your declaration"
        Task { await handle.control.approveHumanAttestation() }
    }
    func step() { guard let handle else { return }; Task { await handle.control.step() } }
    func stop() { status = "Stopping and retaining evidence…"; handle?.cancel() }
    func retry(imageDisclosureChoice: ImageDisclosureChoice = .allowRemoteForThisRun) throws {
        guard !active, let snapshot, let baseDirectory else { return }
        let oneOff = snapshot.categories.count == 1 && snapshot.categories.first?.name == "Goal run" &&
            snapshot.categories.first?.suites.first?.name == "Live navigation"
        try start(project: snapshot, selection: selection, base: baseDirectory, goalNavigation: oneOff,
            savedInputs: savedInputs, imageDisclosureChoice: imageDisclosureChoice)
    }
    func refreshHistory(base: URL) {
        history = ((try? FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("runs"), includingPropertiesForKeys: [.creationDateKey])) ?? []).filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("events.jsonl").path) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func didDeleteRuns(_ urls: [URL], base: URL) {
        if let directory, urls.contains(where: { $0.standardizedFileURL.path == directory.standardizedFileURL.path }) { resetView() }
        if let index {
            let context = index.mainContext
            for url in urls {
                let path = url.path
                let descriptor = FetchDescriptor<RunIndexEntry>(predicate: #Predicate { $0.path == path })
                if let entries = try? context.fetch(descriptor) {
                    for entry in entries { context.delete(entry) }
                }
            }
            do { try context.save() } catch { indexWarning = "Deleted runs were removed, but the metadata index could not be updated." }
        }
        refreshHistory(base: base)
    }
    func resetView() {
        guard !active else { return }
        player?.pause()
        archive = nil; snapshot = nil; directory = nil; baseDirectory = nil; report = nil
        events = []; currentBlock = nil; currentTest = nil; latestCapture = nil; liveCapture = nil
        selectedSequence = nil; player = nil; liveImage = nil; anchor = nil; goalNavigation = false
        savedInputs = []
        diagnosis = nil; diagnosisSource = nil; diagnosisError = nil; providerAlert = nil
        persistenceFailure = nil; status = "No run selected"
    }
    private func startLivePreview(simulatorID: String) {
        previewWorker?.cancel()
        previewWorker = Task { [weak self] in
            guard let self else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HappyPathPreview-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            while !Task.isCancelled && self.active {
                let output = folder.appendingPathComponent("frame.png")
                let data = await Task.detached(priority: .utility) { () -> Data? in
                    try? FileManager.default.removeItem(at: output)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                    process.arguments = ["simctl", "io", simulatorID, "screenshot", "--type=png", output.path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    guard (try? process.run()) != nil else { return nil }
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { return nil }
                    return try? Data(contentsOf: output)
                }.value
                if let data, let image = NSImage(data: data) { liveImage = image }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func open(_ url: URL, retryBase: URL? = nil) throws {
        guard !active else { return }
        let archive: ExecutionArchive
        do { archive = try ExecutionArchive(directory: url) }
        catch {
            diagnosisSource = url
            diagnosis = try? ArchiveRecovery.diagnose(url)
            diagnosisError = diagnosis == nil ? error.localizedDescription : nil
            status = "Archive diagnosis — explicit recovery required"
            self.archive = nil; snapshot = nil; events = []; report = nil; directory = nil; player = nil; liveImage = nil
            baseDirectory = retryBase
            return
        }
        diagnosisSource = url
        diagnosis = archive.report == nil && archive.recovery == nil ? try? ArchiveRecovery.diagnose(url) : nil
        diagnosisError = nil
        baseDirectory = retryBase; currentBlock = nil; currentTest = nil; state = .finished
        let oneOff = archive.project.categories.count == 1 && archive.project.categories.first?.name == "Goal run" &&
            archive.project.categories.first?.suites.first?.name == "Live navigation"
        goalNavigation = oneOff || ((try? archive.project.selectedTests(archive.selection)).map {
            $0.count == 1 && $0[0].test.effectiveExecutionMode == .goal
        } ?? false)
        self.archive = archive; snapshot = archive.project; selection = archive.selection; events = archive.events
        savedInputs = []
        directory = url; report = archive.report; selectedSequence = nil; persistenceFailure = nil
        latestCapture = events.reversed().compactMap { if case .capture(let s) = $0.event { return s.captureID }; return nil }.first
        liveCapture = latestCapture
        status = archive.recovery.map { $0.incomplete ? "Recovered / incomplete — no terminal result" : "Imported legacy evidence — \(report?.outcome.displayName ?? "incomplete")" } ?? (report?.outcome.displayName ?? "Incomplete run — terminal result unavailable")
        loadVideo(); recordIndex()
    }
    func chooseArchive() throws {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { try open(url) }
    }
    func recoverArchive(legacy: Bool = false) throws {
        guard !active, let source = diagnosisSource ?? directory else { return }
        let mode: ArchiveRecoveryMode = legacy ? .legacyISOImport : .nativePrefix
        let checked = try ArchiveRecovery.diagnose(source, mode: mode)
        diagnosis = checked; diagnosisError = nil
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Recovered-" + UUID().uuidString; panel.canCreateDirectories = true
        if let baseDirectory { panel.directoryURL = baseDirectory.appendingPathComponent("runs") }
        if panel.runModal() == .OK, let destination = panel.url {
            _ = try ArchiveRecovery.recover(source, to: destination, mode: mode)
            try open(destination, retryBase: baseDirectory)
            if let baseDirectory { refreshHistory(base: baseDirectory) }
        }
    }
    func export() throws {
        guard !active, let directory else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Run-\(directory.lastPathComponent)"; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { try ExecutionArtifactStore.export(directory: directory, to: url) }
    }
    func captureURL(_ id: CaptureID, raw: Bool = false) -> URL? {
        if let archive { return raw ? archive.rawSnapshotURL(for: id) : archive.screenshotURL(for: id) }
        guard let directory else { return nil }
        let url = directory.appendingPathComponent("captures/\(id.description).\(raw ? "json" : "png")")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func loadVideo() {
        player = archive?.videoURL.map(AVPlayer.init(url:))
        anchor = nil
        if let url = archive?.evidenceURL(relativePath: "recording-anchor.json") {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            anchor = try? decoder.decode(RecordingAnchor.self, from: Data(contentsOf: url))
        }
    }
    func inspect(_ envelope: ExecutionEnvelope) {
        selectedSequence = envelope.sequence
        let prefix = events.filter { $0.sequence <= envelope.sequence }
        let boundary = prefix.lastIndex { if case .blockStarted = $0.event { return true }; if case .testStarted = $0.event { return true }; if case .suiteStarted = $0.event { return true }; return false } ?? 0
        latestCapture = prefix.dropFirst(boundary).reversed().compactMap { if case .capture(let s) = $0.event { return s.captureID }; return nil }.first
        if case .blockStarted(let id) = envelope.event { latestCapture = evidence(for: id).before ?? evidence(for: id).captures.first }
        let sourceID = EvidencePresentation.sourceCapture(for: envelope, events: events)
        if let bound = sourceID { latestCapture = bound }
        let instant = sourceID.flatMap { id in events.compactMap { if case .capture(let capture) = $0.event, capture.captureID == id { return capture.capturedAt }; return nil }.first } ?? envelope.timestamp
        switch envelope.event { case .suiteStarted, .suiteFinished, .testStarted, .testFinished, .state, .finished, .phase: latestCapture = nil; case .goalAssessment(let value) where value.request == nil: latestCapture = nil; default: break }
        if let anchor { player?.seek(to: CMTime(seconds: max(0, instant.timeIntervalSince(anchor.markerObservedAt)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    }
    func returnToLive() { selectedSequence = nil; latestCapture = liveCapture }
    func indexProject(_ project: TestProject, at url: URL) {
        guard let index else { return }
        let path = url.path
        let context = index.mainContext
        if let row = try? context.fetch(FetchDescriptor<ProjectIndexEntry>(predicate: #Predicate { $0.path == path })).first { row.name = project.name; row.projectID = project.id; row.lastOpened = Date() }
        else { context.insert(ProjectIndexEntry(path: path, projectID: project.id, name: project.name)) }
        do { try context.save() } catch { indexWarning = "Metadata index could not be updated; canonical files are saved." }
    }
    func evidence(for id: UUID) -> (before: CaptureID?, after: CaptureID?, captures: [CaptureID]) {
        var inside = false; var before: CaptureID?; var after: CaptureID?; var captures: [CaptureID] = []; var awaitingAfter = false
        for envelope in events {
            switch envelope.event {
            case .blockStarted(let block): inside = block == id
            case .capture(let s) where inside:
                captures.append(s.captureID)
                if awaitingAfter { after = s.captureID; awaitingAfter = false }
            case .action(let block, _) where inside && block == id: before = captures.last; after = nil; awaitingAfter = true
            case .blockFinished(let block, _, _, _) where block == id: inside = false
            default: break
            }
        }
        return (before, after, captures)
    }
    private func recordIndex() {
        guard let index, let directory, let snapshot else { return }
        let context = index.mainContext
        let path = directory.path
        let descriptor = FetchDescriptor<RunIndexEntry>(predicate: #Predicate { $0.path == path })
        if let existing = try? context.fetch(descriptor).first { existing.outcome = report?.outcome.rawValue ?? "incomplete" }
        else { context.insert(RunIndexEntry(path: path, projectName: snapshot.name, outcome: report?.outcome.rawValue ?? "incomplete", date: events.first?.timestamp ?? Date())) }
        try? context.save()
    }
}

extension ExecutionPhase {
    var displayName: String {
        switch self {
        case .preparingSimulator: return "Preparing Simulator"
        case .building: return "Building app or companion"
        case .installing: return "Installing app"
        case .startingCompanion: return "Starting automation companion"
        case .launching: return "Launching app"
        case .recording: return "Starting recording"
        case .resolving: return "Resolving saved target"
        case .performing: return "Performing action"
        case .verifying: return "Verifying evidence"
        case .finalizing: return "Finalizing artifacts and cleanup"
        }
    }
}
