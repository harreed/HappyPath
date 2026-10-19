import Foundation
import RunnerCore

/// Read-only presentation binding. Verification captures never replace source evidence.
public extension ExecutionEvent {
    var sourceCaptureID: CaptureID? {
        switch self {
        case .capture(let value): return value.captureID
        case .captureProvenance(let value): return value.snapshot.captureID
        case .perception(let value): return value.captureID
        case .recovery(let value): return value.captureID
        case .locatorSuggestion(let value): return value.sourceCaptureID
        case .candidateDecision(let value): return value.accepted ? value.captureID : nil
        case .providerFallback(let value): return value.captureID
        case .goalAssessment(let value): return value.request?.captureID
        default: return nil
        }
    }
}

public enum EvidencePresentation {
    /// Screenshot pixels and OCR boxes both have a top-left origin. Return a
    /// letterboxed display box; reject malformed input rather than drawing it.
    public static func overlayBox(_ box: CGRectValue, pixels: PixelSize, width: Double, height: Double) -> CGRectValue? {
        guard pixels.width > 0, pixels.height > 0, [width,height,box.x,box.y,box.width,box.height].allSatisfy(\.isFinite), width > 0, height > 0,
              box.x >= 0, box.y >= 0, box.width > 0, box.height > 0, box.x + box.width <= Double(pixels.width), box.y + box.height <= Double(pixels.height) else { return nil }
        let scale = min(width / Double(pixels.width), height / Double(pixels.height))
        return .init(x: (width - Double(pixels.width) * scale) / 2 + box.x * scale, y: (height - Double(pixels.height) * scale) / 2 + box.y * scale, width: box.width * scale, height: box.height * scale)
    }
    public static func timestamp(_ value: Date?) -> String { guard let value else { return "Unknown (not recorded)" }; let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return formatter.string(from: value) }
    public static func sourceCapture(for envelope: ExecutionEnvelope, events: [ExecutionEnvelope]) -> CaptureID? {
        if case .candidateDecision(let decision) = envelope.event, !decision.accepted {
            for previous in events.reversed() where previous.sequence < envelope.sequence {
                switch previous.event {
                case .capture(let snapshot): return snapshot.captureID
                case .testStarted, .suiteStarted: return nil
                default: continue
                }
            }
            return nil
        }
        return envelope.event.sourceCaptureID
    }
    public static func detail(_ event: ExecutionEvent) -> String? {
        func encoded<T: Encodable>(_ value: T) -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970; return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "Unavailable" }
        switch event {
        case .captureProvenance(let p): return "Original capture: \(p.snapshot.captureID)\nScreenshot acquisition: \(timestamp(p.snapshot.capturedAt)) → \(timestamp(p.screenshotCompletedAt))\nSemantic acquisition: \(timestamp(p.semanticStartedAt)) → \(timestamp(p.semanticCompletedAt))\nSequential intervals, not an atomic snapshot.\n\n" + encoded(p)
        case .perception(let p): return "OCR provider: \(p.provider)\nSource: \(p.captureID)\nImage SHA256: \(p.imageSHA256)\nOriginal screenshot: \(timestamp(p.screenshotStartedAt))\nRecognition: \(timestamp(p.recognitionStartedAt)) → \(timestamp(p.recognitionCompletedAt)) (\(p.recognitionMilliseconds) ms)\nPixels: \(p.geometry.pixels.width) × \(p.geometry.pixels.height); boxes use top-left pixel origin.\n" + p.regions.enumerated().map { "ocr-\($0.offset): \($0.element.text) | confidence \($0.element.confidence) | box \(encoded($0.element.pixelBox))" }.joined(separator: "\n")
        case .recovery(let r): return "Recovery \(r.status.rawValue) — \(r.reason)\nTrigger: \(r.origin?.rawValue ?? "interruption")\nSource: \(r.captureID)\nVerification source: \(r.verificationCaptureID?.description ?? "none")\nProvider: \(r.provider)\nActions: \(r.actionCount)/\(r.maximumActions); recaptures: \(r.recaptureCount); confidence threshold: \(r.minimumConfidence); maximum capture age: \(r.maximumCaptureAge)s\nStarted: \(timestamp(r.recoveryStartedAt)); deadline: \(timestamp(r.deadline))\nComplete candidates:\n" + r.candidates.map { "\($0.id): \($0.title); locally safe: \($0.isSafeForAutomaticExecution); capture: \($0.captureID); action: \(encoded($0.action))" }.joined(separator: "\n") + "\nChoice: \(r.choice.map(encoded) ?? "none")"
        case .locatorSuggestion(let s): return "Proposed locator edit for block \(s.blockID)\nOriginal targets: \(encoded(s.originalTargets))\nProposed target: \(encoded(s.proposedTarget))\nMatched strategy index: \(s.matchedStrategyIndex)\nSource capture: \(s.sourceCaptureID)\nPost-action capture: \(s.postActionCaptureID)\nAction completed; only test assertions establish correctness. Saved tests were not changed."
        case .candidateDecision(let c):
            return "Candidate provider: \(c.provider)\nLocal structural acceptance: \(c.accepted) (not action permission)\nReason: \(c.reason)\nClaimed capture: \(c.captureID)\nRequest: \(c.requestID)\nSelected: \(c.selectedID ?? "none"); confidence: \(c.confidence.map(String.init(describing:)) ?? "not supplied")\nOptions / probabilities:\n" + c.optionIDs.map { "\($0): \(c.probabilities?[$0].map(String.init(describing:)) ?? "not supplied")" }.joined(separator: "\n") + "\nOriginal invalid metadata: \(c.invalidNumericValues?.description ?? "none")\nOriginal accepted: \(c.originalAccepted.map(String.init(describing:)) ?? "not supplied")\nRaw typed evidence:\n" + encoded(c)
        case .providerFallback(let f): return "Provider fallback: \(f.provider) → \(f.fallback)\nReason: \(f.reason)\nSource: \(f.captureID)\nBlock: \(f.blockID)\nThe locally reviewed safe choice was used; hosted choice is best-effort only.\n" + encoded(f)
        case .goalAssessment(let g):
            var text = "Goal assessment: \(g.outcome.rawValue)\nAuthoritative assessment reason: \(g.reason)\nGoal: \(g.goal)\nProvider: \(g.provider); threshold: \(g.minimumConfidence)\nEvidence mode: \(g.request?.mode.rawValue ?? "unavailable")\nDeterministic failures retain precedence.\n"
            if let request = g.request {
                text += "Source: \(request.captureID)\nRequest: \(request.requestID)\nCaptured: \(timestamp(request.capturedAt)); requested: \(timestamp(request.requestedAt)); deadline: \(timestamp(request.deadline))\n"
                if let assessment = g.assessment {
                    text += "Typed verdict: \(assessment.verdict.rawValue); confidence: \(assessment.confidence); requires image: \(assessment.requiresImage)\nModel reason: \(assessment.reason)\nCitations:\n"
                    text += assessment.evidenceIDs.map { id in "\(id): \(request.evidence.first { $0.id == id }?.text ?? "UNKNOWN REFERENCE")" }.joined(separator: "\n")
                }
                if let image = g.imageAssessment {
                    text += "Screenshot verdict: \(image.verdict.rawValue); confidence: \(image.confidence)\nImage SHA256: \(image.imageSHA256)\nProcessing: \(image.processingLocation.rawValue)\nModel reason: \(image.reason)\n"
                }
            }
            return text + "\nOriginal invalid metadata: \(g.invalidNumericValues?.description ?? "none")\nRaw typed evidence:\n" + encoded(g)
        case .failureSummary(let s): return "Established outcome: \(s.source.outcome.rawValue)\nAuthoritative recorded reason: \(s.source.reason)\nExplanatory summary (\(s.provider)): \(s.text)\nThis explanation cannot change the result or saved test.\n" + encoded(s)
        default: return nil
        }
    }
}
