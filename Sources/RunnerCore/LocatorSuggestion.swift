import Foundation
import ProjectDomain

/// A proposed edit to an authored locator. The action completed and a fresh
/// capture was obtained, but only the test's assertions establish correctness.
public struct LocatorSuggestion: Codable, Sendable, Equatable {
    public let blockID: UUID
    public let sourceCaptureID: CaptureID
    public let postActionCaptureID: CaptureID
    public let originalTargets: [TargetStrategy]
    public let proposedTarget: TargetStrategy
    public let matchedStrategyIndex: Int

    public init(blockID: UUID, sourceCaptureID: CaptureID, postActionCaptureID: CaptureID,
                originalTargets: [TargetStrategy], proposedTarget: TargetStrategy, matchedStrategyIndex: Int) {
        self.blockID = blockID
        self.sourceCaptureID = sourceCaptureID
        self.postActionCaptureID = postActionCaptureID
        self.originalTargets = originalTargets
        self.proposedTarget = proposedTarget
        self.matchedStrategyIndex = matchedStrategyIndex
    }
}

struct PendingLocatorSuggestion: Sendable {
    let blockID: UUID
    let sourceCaptureID: CaptureID
    let originalTargets: [TargetStrategy]
    let proposedTarget: TargetStrategy
    let matchedStrategyIndex: Int

    func completed(after captureID: CaptureID) -> LocatorSuggestion {
        .init(blockID: blockID, sourceCaptureID: sourceCaptureID,
              postActionCaptureID: captureID, originalTargets: originalTargets,
              proposedTarget: proposedTarget, matchedStrategyIndex: matchedStrategyIndex)
    }
}

extension ExecutionContext {
    func locatorSuggestion(for element: UIElement, targets: [TargetStrategy], matchedIndex: Int,
                           snapshot: UISnapshot, blockID: UUID) -> PendingLocatorSuggestion? {
        guard let first = targets.first, !exactMatch(first, element: element) || matchedIndex > 0 else { return nil }
        let proposed: TargetStrategy
        if let id = element.identifier, !id.isEmpty,
           snapshot.elements.filter({ $0.identifier == id }).count == 1 {
            proposed = .identifier(id)
        } else if let label = element.label, !label.isEmpty,
                  snapshot.elements.filter({ $0.role == element.role && $0.label == label }).count == 1 {
            proposed = .semantic(role: element.role, label: label, value: nil)
        } else {
            return nil
        }
        guard !targets.contains(proposed) else { return nil }
        return .init(blockID: blockID, sourceCaptureID: snapshot.captureID,
                     originalTargets: targets, proposedTarget: proposed, matchedStrategyIndex: matchedIndex)
    }

    private func exactMatch(_ target: TargetStrategy, element: UIElement) -> Bool {
        switch target {
        case .identifier(let id): return element.identifier == id
        case .text(let text): return element.label == text || element.value == text
        case .semantic(let role, let label, let value):
            return (role == nil || role == element.role)
                && (label == nil || label == element.label)
                && (value == nil || value == element.value)
        }
    }
}
