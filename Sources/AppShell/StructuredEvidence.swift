import SwiftUI
import RunnerCore
import ArtifactStore

struct EvidenceField: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(WorkbenchStyle.sectionFont).foregroundStyle(.secondary); Text(value).font(WorkbenchStyle.infoFont).textSelection(.enabled) } }
}
struct StructuredEvidence: View {
    let event: ExecutionEvent
    let run: RunWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch event {
            case .goalAssessment(let value): goal(value)
            case .recovery(let value): recovery(value)
            case .locatorSuggestion(let value):
                EvidenceField("Suggested locator update", "Block \(value.blockID.uuidString)\n\(value.proposedTarget.summary)")
                source(value.sourceCaptureID)
                source(value.postActionCaptureID, title: "Post-action capture")
                Text("The action completed. Check the test assertions and both captures before updating the saved target.").font(WorkbenchStyle.font(.caption))
            case .candidateDecision(let value): decision(value)
            case .providerFallback(let value):
                EvidenceField("Provider fallback · \(value.provider) → \(value.fallback)", "\(value.reason)\nCapture: \(value.captureID.description)")
                Text("The locally reviewed safe choice was used. Provider unavailability never blocks deterministic execution.").font(WorkbenchStyle.font(.caption))
            case .perception(let value): perception(value)
            case .captureProvenance(let value):
                EvidenceField("Original capture", value.snapshot.captureID.description)
                EvidenceField("Screenshot acquisition", "\(stamp(value.snapshot.capturedAt)) → \(stamp(value.screenshotCompletedAt))")
                EvidenceField("Semantic acquisition", "\(stamp(value.semanticStartedAt)) → \(stamp(value.semanticCompletedAt))")
                Text("Sequential intervals; pixels and semantic state are not atomic.").font(WorkbenchStyle.font(.caption))
            case .failureSummary(let value):
                EvidenceField("Established outcome", value.source.outcome.displayName)
                EvidenceField("Authoritative recorded reason", value.source.reason)
                EvidenceField("Explanatory summary · \(value.provider)", value.text)
                Text("May be imperfect. Cannot change outcome, target or saved test.").font(WorkbenchStyle.font(.caption)).foregroundStyle(.secondary)
                if let raw = value.rawResponse { rawText("Raw typed summary", raw) }
            default: EmptyView()
            }
        }
    }
    func stamp(_ date: Date?) -> String { EvidencePresentation.timestamp(date) }
    @ViewBuilder func rawText(_ title: String, _ text: String) -> some View { DisclosureGroup { Text(text).font(WorkbenchStyle.monoFont).textSelection(.enabled) } label: { Text(title).font(WorkbenchStyle.rowFont) } }
    @ViewBuilder func source(_ id: CaptureID, title: String = "Exact source capture") -> some View {
        EvidenceField(title, id.description)
        Button("Inspect \(title.lowercased())") { if let event = run.events.first(where: { if case .capture(let s) = $0.event { return s.captureID == id }; return false }) { run.inspect(event) } }.buttonStyle(WorkbenchButtonStyle())
    }
    @ViewBuilder func goal(_ value: GoalAssessmentEvidence) -> some View {
        EvidenceField("Goal assessment · \(value.outcome.displayName)", value.reason)
        EvidenceField("Goal", value.goal)
        EvidenceField("Provider / evidence mode", "\(value.provider) · \(value.request?.mode.rawValue ?? "unavailable")")
        Text("Text assessment does not see pixels. Required deterministic failures retain precedence.").font(WorkbenchStyle.font(.caption))
        EvidenceField("Local confidence threshold", String(value.minimumConfidence))
        if let request = value.request {
            source(request.captureID)
            EvidenceField("Request", request.requestID.uuidString)
            EvidenceField("Capture / request / deadline", "\(stamp(request.capturedAt))\n\(stamp(request.requestedAt))\n\(stamp(request.deadline))")
            if let assessment = value.assessment {
                EvidenceField("Typed verdict / confidence", "\(assessment.verdict.rawValue) · \(assessment.confidence)")
                EvidenceField("Model reason (subject to local validation)", assessment.reason)
                EvidenceField("Requires image", String(assessment.requiresImage))
                EvidenceField("Citations", assessment.evidenceIDs.joined(separator: ", "))
                ForEach(Array(assessment.evidenceIDs.enumerated()), id: \.offset) { _, id in
                    EvidenceField(id, request.evidence.first { $0.id == id }?.text ?? "UNKNOWN REFERENCE — no matching source row")
                }
                if let raw = assessment.rawResponse { rawText("Raw typed assessment", raw) }
            }
            DisclosureGroup { ForEach(request.evidence, id: \.id) { EvidenceField($0.id, $0.text) } } label: { Text("All \(request.evidence.count) supplied evidence rows").font(WorkbenchStyle.rowFont) }
        }
        invalid(value.invalidNumericValues)
    }
    @ViewBuilder func invalid(_ values: [String:String]?) -> some View {
        if let values, !values.isEmpty { EvidenceField("Original invalid metadata — refused", values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")).foregroundStyle(.red) }
    }
    @ViewBuilder func decision(_ value: CandidateDecisionEvidence) -> some View {
        EvidenceField("Provider decision · \(value.provider)", value.reason)
        EvidenceField("Structural acceptance", "\(value.accepted). This is not permission to act.")
        if let original = value.originalAccepted { EvidenceField("Original provider acceptance", String(original)) }
        if value.accepted { source(value.captureID) }
        else {
            EvidenceField("Rejected provider capture claim (not authoritative)", value.captureID.description)
            Text("The displayed screenshot is the preceding local capture. A mismatched claim never selects another screenshot.").font(WorkbenchStyle.font(.caption))
        }
        EvidenceField("Local request", value.requestID.uuidString)
        if let response = value.responseCaptureID { EvidenceField("Response capture binding", response.description) }
        EvidenceField("Selected option / confidence", "\(value.selectedID ?? "none") · \(value.confidence.map(String.init(describing:)) ?? "unavailable")")
        ForEach(Array(value.optionIDs.enumerated()), id: \.offset) { _, id in EvidenceField(id, "Probability: \(value.probabilities?[id].map(String.init(describing:)) ?? "not supplied")") }
        Text("Probability concentration is not a guarantee of correctness. Local policy, confidence, age and progress checks remain required.").font(WorkbenchStyle.font(.caption))
        invalid(value.invalidNumericValues)
    }
    @ViewBuilder func recovery(_ value: RecoveryEvidence) -> some View {
        EvidenceField("Recovery · \(value.status.rawValue)", value.reason)
        EvidenceField("Trigger", value.origin?.rawValue ?? "interruption")
        source(value.captureID)
        EvidenceField("Observed interruption", "\(value.interruption.kind.rawValue): \(value.interruption.reason)")
        EvidenceField("Provider / limits", "\(value.provider)\nActions \(value.actionCount)/\(value.maximumActions) · recaptures \(value.recaptureCount)\nConfidence ≥ \(value.minimumConfidence) · age < \(value.maximumCaptureAge)s\n\(stamp(value.recoveryStartedAt)) → \(stamp(value.deadline))")
        WorkbenchSectionLabel("Complete candidate table (\(value.candidates.count))")
        ForEach(value.candidates) { candidate in
            VStack(alignment: .leading, spacing: 6) {
                EvidenceField(candidate.title, candidate.id.uuidString)
                Text("Locally safe: \(candidate.isSafeForAutomaticExecution ? "yes" : "no") · selected: \(candidate.id == value.choice?.candidateID ? "yes" : "no")").font(WorkbenchStyle.font(.caption))
                EvidenceField("Candidate capture", candidate.captureID.description)
                if case .tapAlertButton(let node) = candidate.action { EvidenceField("Exact button", "Identifier: \(node.identifier ?? "missing (nil)")\nLabel: \(node.label ?? "missing")\nContext: \(node.containingAlertContext ?? "missing")") }
                else { EvidenceField("Bound action", String(describing: candidate.action)) }
            }.frame(maxWidth: .infinity, alignment: .leading).workbenchInset()
        }
        if let choice = value.choice { EvidenceField("Chosen confidence / rationale", "\(choice.confidence) · \(choice.rationale ?? "none")"); if let metadata = choice.providerEvidence { DisclosureGroup { decision(metadata) } label: { Text("Provider distribution").font(WorkbenchStyle.rowFont) } } }
        if let verification = value.verificationCaptureID { source(verification, title: "Separate verification capture"); CaptureImage(run: run, id: verification).frame(maxHeight: 220).clipShape(WorkbenchStyle.shape(WorkbenchStyle.rowRadius)) }
        DisclosureGroup { ForEach(Array(value.interruption.elements.enumerated()), id: \.offset) { _, node in EvidenceField(node.label ?? node.role, "Identifier: \(node.identifier ?? "missing (nil)")\nOrigin: \(node.originBundleIdentifier ?? "unknown")\nContext: \(node.containingAlertContext ?? "none")") } } label: { Text("Observed nodes and exact alert context").font(WorkbenchStyle.rowFont) }
    }
    @ViewBuilder func perception(_ value: TextPerception) -> some View {
        source(value.captureID)
        EvidenceField("OCR provider", value.provider)
        EvidenceField("Original screenshot / recognition interval", "\(stamp(value.screenshotStartedAt))\n\(stamp(value.recognitionStartedAt)) → \(stamp(value.recognitionCompletedAt))\n\(value.recognitionMilliseconds) ms")
        EvidenceField("Image SHA256", value.imageSHA256)
        OCRCaptureOverlay(run: run, perception: value).frame(height: 310)
        Text("Top-left pixel boxes · \(value.geometry.pixels.width) × \(value.geometry.pixels.height). OCR is text recognition, not image interpretation.").font(WorkbenchStyle.font(.caption))
        ForEach(Array(value.regions.enumerated()), id: \.offset) { index, region in
            EvidenceField("ocr-\(index) · \(region.confidence)", "\(region.text)\nBox: \(region.pixelBox.x), \(region.pixelBox.y), \(region.pixelBox.width), \(region.pixelBox.height)")
        }
    }
}

struct OCRCaptureOverlay: View {
    let run: RunWorkspace
    let perception: TextPerception
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                CaptureImage(run: run, id: perception.captureID).frame(width: geometry.size.width, height: geometry.size.height)
                ForEach(Array(perception.regions.enumerated()), id: \.offset) { index, region in
                    if let box = EvidencePresentation.overlayBox(region.pixelBox, pixels: perception.geometry.pixels, width: geometry.size.width, height: geometry.size.height) {
                        Rectangle().stroke(.orange, lineWidth: 1.5).frame(width: box.width, height: box.height).overlay(alignment: .topLeading) { Text("\(index)").font(WorkbenchStyle.font(size: 9, weight: .bold)).foregroundStyle(.black).background(.orange) }.offset(x: box.x, y: box.y)
                    }
                }
            }
        }.accessibilityLabel("OCR boxes on exact capture \(perception.captureID.description)")
    }
}
