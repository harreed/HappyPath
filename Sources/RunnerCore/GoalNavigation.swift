import Foundation
import ProjectDomain

public struct GoalSavedInput: Sendable {
    public let name: String
    public let value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

public struct GoalNavigationCandidate: Codable, Sendable {
    public let id: String
    public let label: String
    public let elementIndex: Int?
    public let isKeyboard: Bool
    public let isOCR: Bool
    public init(id: String, label: String, elementIndex: Int?, isKeyboard: Bool = false, isOCR: Bool = false) {
        self.id = id; self.label = label; self.elementIndex = elementIndex
        self.isKeyboard = isKeyboard; self.isOCR = isOCR
    }
}

public struct GoalNavigationRequest: Codable, Sendable {
    public let goal: String
    public let successCriteria: String
    public let captureID: CaptureID
    public let screen: [GoalEvidenceItem]
    public let candidates: [GoalNavigationCandidate]
    public let recentActions: [String]
    public let failedActionsOnThisScreen: [String]
    public let imageData: Data?
    private enum CodingKeys: String, CodingKey {
        case goal, successCriteria, captureID, screen, candidates, recentActions, failedActionsOnThisScreen
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        goal = try values.decode(String.self, forKey: .goal)
        successCriteria = try values.decode(String.self, forKey: .successCriteria)
        captureID = try values.decode(CaptureID.self, forKey: .captureID)
        screen = try values.decode([GoalEvidenceItem].self, forKey: .screen)
        candidates = try values.decode([GoalNavigationCandidate].self, forKey: .candidates)
        recentActions = try values.decode([String].self, forKey: .recentActions)
        failedActionsOnThisScreen = try values.decodeIfPresent([String].self, forKey: .failedActionsOnThisScreen) ?? []
        imageData = nil
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(goal, forKey: .goal)
        try values.encode(successCriteria, forKey: .successCriteria)
        try values.encode(captureID, forKey: .captureID)
        try values.encode(screen, forKey: .screen)
        try values.encode(candidates, forKey: .candidates)
        try values.encode(recentActions, forKey: .recentActions)
        try values.encode(failedActionsOnThisScreen, forKey: .failedActionsOnThisScreen)
    }
    public init(goal: String, successCriteria: String = "", snapshot: UISnapshot, candidates: [GoalNavigationCandidate], recentActions: [String], suppressedLabels: Set<String> = [], recognizedText: [String] = [], imageData: Data? = nil) {
        self.goal = goal; self.successCriteria = successCriteria
        captureID = snapshot.captureID; self.candidates = candidates; self.recentActions = recentActions
        failedActionsOnThisScreen = suppressedLabels.sorted()
        self.imageData = imageData
        let accessibilityScreen: [GoalEvidenceItem] = snapshot.elements.enumerated().prefix(120).compactMap { index, element in
            if ["button", "link", "cell"].contains(element.role), let label = element.label,
               suppressedLabels.contains(label) { return nil }
            return GoalEvidenceItem(id: "element-\(index)", text: "role=\(element.role); identifier=\(element.identifier ?? ""); label=\(element.label ?? ""); value=\(element.value ?? "")")
        }
        screen = accessibilityScreen + recognizedText.prefix(max(0, 120 - accessibilityScreen.count)).enumerated().map { index, text in
            GoalEvidenceItem(id: "ocr-\(index)", text: "screenshot OCR text: \(text)")
        }
    }
}

public struct GoalNavigationDecision: Sendable {
    public enum Kind: Sendable, Equatable { case act, complete, blocked }
    public let captureID: CaptureID
    public let kind: Kind
    public let candidateID: String?
    public let confidence: Double
    public let reason: String
    public init(captureID: CaptureID, kind: Kind, candidateID: String? = nil, confidence: Double, reason: String) {
        self.captureID = captureID; self.kind = kind; self.candidateID = candidateID; self.confidence = confidence; self.reason = reason
    }
}

struct GoalNavigationResult: Sendable {
    let outcome: RunOutcome
    let reason: String
}

public protocol GoalNavigating: Sendable {
    func decide(_ request: GoalNavigationRequest) async throws -> GoalNavigationDecision
}

public struct UnavailableGoalNavigator: GoalNavigating {
    public init() {}
    public func decide(_ request: GoalNavigationRequest) async throws -> GoalNavigationDecision { throw ProviderFailure.unavailable }
}

public enum GoalNavigationSafety {
    /// Match a saved value to one empty, visible app text field.
    public static func savedInputTarget(in snapshot: UISnapshot, inputs: [GoalSavedInput],
                                        appBundleID: String) -> (UIElement, GoalSavedInput)? {
        guard !restrictedScreen(snapshot) else { return nil }
        func matches(_ text: String, key: String) -> Bool {
            let compact = TargetTextMatching.normalize(text).filter { $0.isLetter || $0.isNumber }
            return [key, "your\(key)", "enter\(key)", "\(key)field", "\(key)textfield", "\(key)input"].contains(compact)
        }
        let matches = snapshot.elements.flatMap { element -> [(UIElement, GoalSavedInput)] in
            guard element.role == "textField", element.isEnabled == true, element.isHittable == true,
                  element.originBundleIdentifier == appBundleID,
                  element.containingAlertContext == nil else { return [] }
            return inputs.compactMap { input in
                let key = TargetTextMatching.normalize(input.name).filter { $0.isLetter || $0.isNumber }
                let value = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
                let directlyNamed = [element.label, element.identifier, element.value]
                    .compactMap { $0 }.contains { matches($0, key: key) }
                let nearbyPrompt = snapshot.elements.contains { prompt in
                    guard prompt.role == "staticText", prompt.originBundleIdentifier == appBundleID,
                          let label = prompt.label, let promptFrame = prompt.frame, let fieldFrame = element.frame,
                          label.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(Substring(key)) else { return false }
                    let gap = fieldFrame.y - (promptFrame.y + promptFrame.height)
                    let overlap = min(promptFrame.x + promptFrame.width, fieldFrame.x + fieldFrame.width) - max(promptFrame.x, fieldFrame.x)
                    return gap >= 0 && gap <= 120 && overlap > 0
                }
                guard !key.isEmpty, !value.isEmpty, value.count <= 200,
                      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      directlyNamed || nearbyPrompt,
                      element.value.map({ $0.isEmpty || matches($0, key: key) }) ?? true else { return nil }
                return (element, input)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func visibleTimer(in snapshot: UISnapshot) -> (text: String, seconds: Int)? {
        let text = snapshot.elements.filter { element in
            element.role == "staticText" && element.frame != nil &&
                (element.label?.allSatisfy { $0.isNumber || $0 == ":" } == true)
        }.sorted { ($0.frame?.x ?? 0) < ($1.frame?.x ?? 0) }.compactMap(\.label).joined()
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ $0.count <= 2 }),
              let minutes = Int(parts[0]), let seconds = Int(parts[1]),
              minutes >= 0, seconds >= 0, seconds < 60 else { return nil }
        return (text, minutes * 60 + seconds)
    }
    public static func restrictedScreen(_ snapshot: UISnapshot) -> Bool {
        humanAttestationReason(in: snapshot) != nil || snapshot.elements.contains { element in
            ["button", "link", "cell", "alert"].contains(element.role) &&
                TargetTextMatching.irreversibleIntent([element])
        }
    }
    public static func humanAttestationReason(in snapshot: UISnapshot) -> String? {
        guard snapshot.elements.contains(where: {
            $0.role == "button" && ($0.label.map { label in
                let normalized = TargetTextMatching.normalize(label)
                return normalized.contains("accept") || normalized.contains("agree") || normalized.contains("confirm")
            } ?? false)
        }) else { return nil }
        return snapshot.elements.compactMap(\.label).first(where: { label in
            let normalized = TargetTextMatching.normalize(label)
            return ["i confirm", "i certify", "i declare", "i affirm", "i accept full responsibility"].contains(where: normalized.contains)
        })
    }

    public static func candidates(in snapshot: UISnapshot, appBundleID: String) -> [GoalNavigationCandidate] {
        let restrictedScreen = restrictedScreen(snapshot)
        return snapshot.elements.enumerated().compactMap { index, element in
            guard index < 120, ["button", "link", "cell"].contains(element.role),
                  element.isEnabled == true, element.isHittable == true,
                  element.originBundleIdentifier == nil || element.originBundleIdentifier == appBundleID,
                  element.containingAlertContext == nil,
                  let label = element.label ?? element.identifier, !label.isEmpty,
                  !TargetTextMatching.irreversibleIntent([element]),
                  !["sign up", "signup", "register", "create account"].contains(where: { TargetTextMatching.normalize(label).contains($0) }),
                  !restrictedScreen || TargetTextMatching.dismissalAffordance(label) || TargetTextMatching.dismissalAffordance(element.identifier) else { return nil }
            return GoalNavigationCandidate(id: "element-\(index)", label: label, elementIndex: index,
                isKeyboard: keyboardControl(element, in: snapshot))
        }
    }

    /// OCR supplies text locations when the app does not expose tappable
    /// accessibility controls. These IDs remain bound to one capture.
    public static func ocrCandidates(_ perception: TextPerception, snapshot: UISnapshot,
                                     appBundleID: String) -> [GoalNavigationCandidate] {
        guard !restrictedScreen(snapshot),
              !snapshot.elements.contains(where: { $0.containingAlertContext != nil }),
              !snapshot.elements.contains(where: {
                  ["alert", "sheet"].contains($0.role) && $0.isHittable != false
              }),
              !snapshot.elements.contains(where: { element in
                  let origin = element.originBundleIdentifier
                  return origin != nil && origin != appBundleID &&
                      ["button", "sheet", "alert"].contains(element.role)
              }),
              let viewport = snapshot.elements.first(where: {
                  $0.role == "application" && $0.originBundleIdentifier == appBundleID
              })?.frame else { return [] }
        var seen = Set<String>()
        return perception.regions.enumerated().compactMap { index, region in
            guard index < 120, region.confidence >= 0.4 else { return nil }
            let label = region.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = TargetTextMatching.normalize(label)
            // If XCTest identifies the same glyphs as static text, OCR alone
            // does not turn a heading into an actionable control.
            guard !snapshot.elements.contains(where: {
                $0.role == "staticText" && $0.originBundleIdentifier == appBundleID &&
                TargetTextMatching.equals($0.label, label)
            }) else { return nil }
            guard let center = try? perception.geometry.screenPoint(for: region.center),
                  center.x >= viewport.x, center.x <= viewport.x + viewport.width,
                  center.y >= viewport.y, center.y <= viewport.y + viewport.height else { return nil }
            guard !key.isEmpty, seen.insert(key).inserted,
                  !TargetTextMatching.irreversibleIntent([UIElement(identifier: nil, role: "staticText",
                      label: label, value: nil, frame: nil, isEnabled: true)]) else { return nil }
            return GoalNavigationCandidate(id: "ocr-\(index)", label: label, elementIndex: nil, isOCR: true)
        }
    }

    /// A named goal with no relevant live control warrants one visual check.
    /// A unique forward or dismissal control is already a credible accessibility route.
    public static func shouldCheckOCR(goal: String, candidates: [GoalNavigationCandidate]) -> Bool {
        let clause = requestedActionClause(goal)
        // For an open-ended goal the navigator can still declare completion from
        // fresh evidence. A sparse completion screen is not an OCR requirement.
        guard ["tap ", "click ", "press ", "open ", "select ", "choose "]
            .contains(where: clause.hasPrefix) else { return false }
        return !candidates.contains { candidate in
            let label = TargetTextMatching.normalize(candidate.label)
            return !candidate.isKeyboard && (TargetTextMatching.progressAffordance(label) ||
                TargetTextMatching.dismissalAffordance(label) ||
                (label.count >= 3 && clause.contains(label)))
        }
    }

    public static func requestedOCRChoice(_ request: GoalNavigationRequest, snapshot: UISnapshot,
                                          appBundleID: String) -> GoalNavigationDecision? {
        guard request.captureID == snapshot.captureID,
              shouldCheckOCR(goal: request.goal, candidates: candidates(in: snapshot, appBundleID: appBundleID)) else { return nil }
        let goal = requestedActionClause(request.goal)
        let matches = request.candidates.filter { candidate in
            let label = TargetTextMatching.normalize(candidate.label)
            return candidate.isOCR && label.count >= 4 && goal.contains(label) &&
                !TargetTextMatching.irreversibleIntent([UIElement(identifier: nil, role: "staticText",
                    label: candidate.label, value: nil, frame: nil, isEnabled: true)])
        }
        guard matches.count == 1 else { return nil }
        return .init(captureID: snapshot.captureID, kind: .act, candidateID: matches[0].id,
            confidence: 1, reason: "Unique screenshot text names the requested action: \(matches[0].label)")
    }

    public static func unactionableRequestedHeading(goal: String, snapshot: UISnapshot,
                                                     appBundleID: String) -> String? {
        let clause = requestedActionClause(goal)
        let headings = snapshot.elements.filter {
            $0.role == "staticText" && $0.originBundleIdentifier == appBundleID &&
            $0.label.map { label in
                let normalized = TargetTextMatching.normalize(label)
                return normalized.count >= 4 && clause.contains(normalized)
            } == true
        }
        guard headings.count == 1, let label = headings[0].label,
              !candidates(in: snapshot, appBundleID: appBundleID).contains(where: {
                  TargetTextMatching.equals($0.label, label)
              }) else { return nil }
        return label
    }

    private static func requestedActionClause(_ goal: String) -> String {
        let normalized = TargetTextMatching.normalize(goal)
        return [" so ", " to show ", " until ", " then ", " and verify ", " and confirm "]
            .compactMap { normalized.range(of: $0)?.lowerBound }
            .min().map { String(normalized[..<$0]) } ?? normalized
    }

    public static func mismatchesExplicitTap(_ label: String, goal: String) -> Bool {
        let clause = requestedActionClause(goal)
        guard ["tap ", "click ", "press "].contains(where: clause.hasPrefix) else { return false }
        let candidate = TargetTextMatching.normalize(label)
        return candidate.count >= 2 && !clause.contains(candidate)
    }

    public static func literalVisibleSuccess(_ criteria: String, snapshot: UISnapshot,
                                             appBundleID: String) -> String? {
        guard !restrictedScreen(snapshot),
              !snapshot.elements.contains(where: { $0.containingAlertContext != nil }),
              let viewport = snapshot.elements.first(where: {
                  $0.role == "application" && $0.originBundleIdentifier == appBundleID
              })?.frame else { return nil }
        let normalized = TargetTextMatching.normalize(criteria)
        let suffixes = [" is visible", " appears", " is shown"]
        guard let suffix = suffixes.first(where: normalized.hasSuffix) else { return nil }
        let wanted = String(normalized.dropLast(suffix.count))
        guard wanted.count >= 4 else { return nil }
        let matches = snapshot.elements.filter { element in
            element.role == "staticText" && element.originBundleIdentifier == appBundleID &&
                TargetTextMatching.normalize(element.label ?? "") == wanted &&
                element.isHittable != false &&
                (element.frame.map { frame in
                    frame.width > 0 && frame.height > 0 &&
                    frame.x + frame.width / 2 >= viewport.x &&
                    frame.x + frame.width / 2 <= viewport.x + viewport.width &&
                    frame.y + frame.height / 2 >= viewport.y &&
                    frame.y + frame.height / 2 <= viewport.y + viewport.height
                } ?? false)
        }
        return matches.count == 1 ? matches[0].label : nil
    }

    /// Select the smallest plausible app control enclosing the recognized label.
    /// The frame is used only after fresh capture binding and live driver validation.
    public static func enclosingVisualControl(_ region: TextRegion, perception: TextPerception,
                                              snapshot: UISnapshot, appBundleID: String) -> UIElement? {
        guard let center = try? perception.geometry.screenPoint(for: region.center),
              let viewport = snapshot.elements.first(where: { $0.role == "application" && $0.originBundleIdentifier == appBundleID })?.frame else { return nil }
        let textWidth = region.pixelBox.width / Double(perception.geometry.pixels.width) * perception.geometry.screenFrame.width
        let textHeight = region.pixelBox.height / Double(perception.geometry.pixels.height) * perception.geometry.screenFrame.height
        let matches = snapshot.elements.filter { element in
            guard ["other", "button", "cell", "link"].contains(element.role),
                  element.originBundleIdentifier == appBundleID,
                  element.isEnabled != false, element.isHittable != false,
                  element.containingAlertContext == nil,
                  (element.label ?? "").isEmpty, (element.identifier ?? "").isEmpty,
                  let frame = element.frame,
                  frame.width >= max(24, textWidth), frame.height >= max(24, textHeight),
                  frame.width * frame.height < viewport.width * viewport.height * 0.25,
                  frame.x >= viewport.x, frame.y >= viewport.y,
                  frame.x + frame.width <= viewport.x + viewport.width,
                  frame.y + frame.height <= viewport.y + viewport.height else { return false }
            return center.x >= frame.x && center.x <= frame.x + frame.width &&
                center.y >= frame.y && center.y <= frame.y + frame.height
        }.sorted { ($0.frame!.width * $0.frame!.height) < ($1.frame!.width * $1.frame!.height) }
        guard let first = matches.first else { return nil }
        if matches.count > 1, let firstFrame = first.frame, let secondFrame = matches[1].frame,
           secondFrame.width * secondFrame.height < firstFrame.width * firstFrame.height * 1.2 { return nil }
        return first
    }

    private static func keyboardControl(_ element: UIElement, in snapshot: UISnapshot) -> Bool {
        guard let frame = element.frame else { return false }
        let centerX = frame.x + frame.width / 2, centerY = frame.y + frame.height / 2
        return snapshot.elements.contains { keyboard in
            guard keyboard.role == "keyboard", let bounds = keyboard.frame else { return false }
            return centerX >= bounds.x && centerX <= bounds.x + bounds.width &&
                centerY >= bounds.y && centerY <= bounds.y + bounds.height
        }
    }

    /// A visible app button may lack snapshot hittability when a keyboard key
    /// has the same label. A live tap still has to pass the companion's check.
    public static func unconfirmedProgressButton(in snapshot: UISnapshot, appBundleID: String) -> UIElement? {
        guard !restrictedScreen(snapshot),
              !snapshot.elements.contains(where: { $0.containingAlertContext != nil }),
              !snapshot.elements.contains(where: { element in
                  let origin = element.originBundleIdentifier
                  return origin != nil && origin != appBundleID &&
                      ["button", "sheet", "alert"].contains(element.role)
              }),
              let viewport = snapshot.elements.first(where: {
                  $0.role == "application" && $0.originBundleIdentifier == appBundleID
              })?.frame else { return nil }
        let matches = snapshot.elements.filter { element in
            guard element.role == "button", element.originBundleIdentifier == appBundleID,
                  element.isEnabled == true, element.isHittable == nil,
                  let label = element.label, TargetTextMatching.progressAffordance(label),
                  !TargetTextMatching.irreversibleIntent([element]),
                  let frame = element.frame, frame.width > 0, frame.height > 0 else { return false }
            let centerX = frame.x + frame.width / 2, centerY = frame.y + frame.height / 2
            return centerX >= viewport.x && centerX <= viewport.x + viewport.width &&
                centerY >= viewport.y && centerY <= viewport.y + viewport.height &&
                !keyboardControl(element, in: snapshot)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func selectedElement(_ decision: GoalNavigationDecision, request: GoalNavigationRequest, snapshot: UISnapshot, appBundleID: String) -> UIElement? {
        guard decision.kind == .act, decision.captureID == request.captureID,
              decision.confidence.isFinite, (0...1).contains(decision.confidence),
              let id = decision.candidateID,
              let candidate = request.candidates.first(where: { $0.id == id }),
              let index = candidate.elementIndex, snapshot.elements.indices.contains(index),
              candidates(in: snapshot, appBundleID: appBundleID).contains(where: { $0.id == id }) else { return nil }
        return snapshot.elements[index]
    }

    public static func reboundElement(_ previous: UIElement, in snapshot: UISnapshot, appBundleID: String) -> UIElement? {
        let matches = candidates(in: snapshot, appBundleID: appBundleID).compactMap { candidate -> UIElement? in
            guard let index = candidate.elementIndex, snapshot.elements.indices.contains(index) else { return nil }
            let element = snapshot.elements[index]
            guard element.role == previous.role,
                  element.label == previous.label,
                  element.identifier == previous.identifier,
                  element.originBundleIdentifier == previous.originBundleIdentifier else { return nil }
            return element
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// One visible app control can advance the run when the model cannot choose.
    /// Never infer a choice on a system overlay or a restricted screen.
    public static func obviousChoice(_ request: GoalNavigationRequest, snapshot: UISnapshot, appBundleID: String) -> GoalNavigationDecision? {
        guard request.captureID == snapshot.captureID,
              !snapshot.elements.contains(where: { element in
            let origin = element.originBundleIdentifier
            return origin != nil && origin != appBundleID && (["button", "sheet", "alert"].contains(element.role) || element.containingAlertContext != nil)
        }), !restrictedScreen(snapshot) else { return nil }
        let available = candidates(in: snapshot, appBundleID: appBundleID)
            .filter { candidate in request.candidates.contains(where: { $0.id == candidate.id }) }
            .filter { !$0.isKeyboard }
        // A Back button on an onboarding page is navigation history, not an
        // obstruction to dismiss. Choosing it here can undo a successful
        // sign-in while the page's next step is reached by scrolling.
        let dismissals = available.filter {
            TargetTextMatching.dismissalAffordance($0.label) &&
            TargetTextMatching.normalize($0.label) != "back"
        }
        let progress = available.filter { TargetTextMatching.progressAffordance($0.label) }
        let selected: GoalNavigationCandidate
        if dismissals.count == 1 { selected = dismissals[0] }
        else if dismissals.isEmpty && progress.count == 1 { selected = progress[0] }
        else if dismissals.isEmpty && progress.isEmpty,
                let screen = snapshot.elements.first(where: {
                    $0.role == "application" && $0.originBundleIdentifier == appBundleID
                })?.frame {
            // Carousels often mark neighbouring cards hittable even when their
            // centres are offscreen. Select only one large card entirely within
            // the app's visible bounds before exploring with more swipes.
            let cards = available.filter { candidate in
                guard let index = candidate.elementIndex,
                      snapshot.elements.indices.contains(index),
                      let frame = snapshot.elements[index].frame else { return false }
                return frame.width >= 120 && frame.height >= 120 &&
                    frame.x >= screen.x && frame.y >= screen.y &&
                    frame.x + frame.width <= screen.x + screen.width &&
                    frame.y + frame.height <= screen.y + screen.height
            }
            guard cards.count == 1 else { return nil }
            selected = cards[0]
        } else { return nil }
        return .init(captureID: snapshot.captureID, kind: .act, candidateID: selected.id, confidence: 1,
                     reason: "One enabled, visible control: \(selected.label)")
    }

    /// On an ordinary app question, choose a safe visible answer when the model
    /// has no usable choice. This avoids stopping on low-stakes onboarding steps.
    public static func questionChoice(_ request: GoalNavigationRequest, snapshot: UISnapshot, appBundleID: String) -> GoalNavigationDecision? {
        guard request.captureID == snapshot.captureID, !restrictedScreen(snapshot),
              !snapshot.elements.contains(where: { element in
                  let origin = element.originBundleIdentifier
                  return origin != nil && origin != appBundleID &&
                      (["button", "sheet", "alert"].contains(element.role) || element.containingAlertContext != nil)
              }),
              snapshot.elements.contains(where: { $0.role == "staticText" && $0.originBundleIdentifier == appBundleID && ($0.label?.contains("?") == true) }) else { return nil }
        let answers = candidates(in: snapshot, appBundleID: appBundleID).filter { candidate in
            request.candidates.contains(where: { $0.id == candidate.id }) && !candidate.isKeyboard &&
                candidate.elementIndex.flatMap { snapshot.elements.indices.contains($0) ? snapshot.elements[$0].originBundleIdentifier : nil } == appBundleID &&
                !TargetTextMatching.dismissalAffordance(candidate.label) &&
                !TargetTextMatching.progressAffordance(candidate.label) &&
                !["back", "cancel", "help", "settings"].contains(TargetTextMatching.normalize(candidate.label))
        }
        guard answers.count >= 2 else { return nil }
        return .init(captureID: snapshot.captureID, kind: .act, candidateID: answers[0].id, confidence: 1,
                     reason: "Choose a visible answer to continue: \(answers[0].label)")
    }

    /// An explicit "X tab is active" criterion can be established by a fresh,
    /// capture-bound tap when the app omits tab labels from accessibility.
    public static func requestedActiveTab(_ criteria: String) -> String? {
        let words = TargetTextMatching.normalize(criteria).split(separator: " ")
        guard let tab = words.firstIndex(of: "tab"), tab > words.startIndex,
              words.dropFirst(tab + 1).contains(where: { $0 == "active" || $0 == "selected" }) else { return nil }
        return String(words[tab - 1])
    }

    public static func isDiagnosticControl(_ label: String) -> Bool {
        let value = TargetTextMatching.normalize(label)
        return value.contains("debug") || value.contains("ladybug") || value.contains("developer tools")
    }

    public static func likelyTabBar(in snapshot: UISnapshot, appBundleID: String) -> Bool {
        guard !restrictedScreen(snapshot),
              let viewport = snapshot.elements.first(where: {
                  $0.role == "application" && $0.originBundleIdentifier == appBundleID
              })?.frame,
              !snapshot.elements.contains(where: { $0.role == "keyboard" }),
              !snapshot.elements.contains(where: { element in
                  element.containingAlertContext != nil || element.role == "alert" || element.role == "sheet" ||
                  (element.originBundleIdentifier != nil && element.originBundleIdentifier != appBundleID &&
                   ["button", "alert", "sheet"].contains(element.role))
              }) else { return false }
        let centers = snapshot.elements.compactMap { element -> Double? in
            guard ["button", "cell", "other"].contains(element.role), element.isHittable == true,
                  element.originBundleIdentifier == appBundleID, let frame = element.frame else { return nil }
            let x = frame.x + frame.width / 2, y = frame.y + frame.height / 2
            guard x >= viewport.x, x <= viewport.x + viewport.width,
                  y >= viewport.y + viewport.height * 0.8,
                  y <= viewport.y + viewport.height else { return nil }
            return x
        }.sorted()
        var distinct: [Double] = []
        for x in centers where distinct.last.map({ x - $0 >= 30 }) ?? true { distinct.append(x) }
        return distinct.count >= 3
    }

    public static func visibleTabText(_ tab: String, in perception: TextPerception,
                                      capture: ScreenCapture, snapshot: UISnapshot,
                                      appBundleID: String) -> Bool {
        guard let match = try? perception.uniqueMatch(text: tab, minimumConfidence: 0.4,
                                                      capture: capture, maximumAge: 8),
              TargetTextMatching.equals(match.text, tab),
              let point = try? perception.geometry.screenPoint(for: match.center) else { return false }
        let viewport = perception.geometry.screenFrame
        guard point.x >= viewport.x, point.x <= viewport.x + viewport.width,
              point.y >= viewport.y + viewport.height * 0.8,
              point.y <= viewport.y + viewport.height else { return false }
        return snapshot.elements.contains { element in
            guard ["button", "cell", "other"].contains(element.role), element.isHittable == true,
                  element.originBundleIdentifier == appBundleID, let frame = element.frame else { return false }
            return abs(point.x - (frame.x + frame.width / 2)) <= 40 &&
                abs(point.y - (frame.y + frame.height / 2)) <= 65
        }
    }

    static func emptyFieldBlocksContinue(in snapshot: UISnapshot, appBundleID: String) -> Bool {
        let appElements = snapshot.elements.filter {
            $0.originBundleIdentifier == nil || $0.originBundleIdentifier == appBundleID
        }
        let emptyField = appElements.contains {
            $0.role == "textField" && $0.isEnabled == true &&
                ($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let disabledContinue = appElements.contains {
            $0.role == "button" && $0.isEnabled == false && TargetTextMatching.equals($0.label ?? "", "Continue")
        }
        return emptyField && disabledContinue
    }
}

private enum GoalTransientFailure {
    case staleCapture, unavailableTarget

    init?(_ error: Error) {
        if let failure = error as? CompanionFailure {
            switch failure {
            case .staleCapture, .contextChanged: self = .staleCapture
            case .unavailableTarget, .absentTarget, .ambiguousTarget, .expired: self = .unavailableTarget
            default: return nil
            }
        } else if let failure = error as? PerceptionFailure, failure == .staleCapture {
            self = .staleCapture
        } else if let failure = error as? DriverFailure {
            switch failure {
            case .unavailable(let reason) where reason == "staleCapture" || reason == "contextChanged": self = .staleCapture
            case .notDispatched(let reason) where ["unavailableTarget", "absentTarget", "ambiguousTarget", "expired"].contains(reason): self = .unavailableTarget
            default: return nil
            }
        } else { return nil }
    }
}

private enum GoalExploreResult {
    case none, otherAction, swipe(SwipeDirection)
    var didAct: Bool { if case .none = self { return false }; return true }
}

extension ExecutionContext {
    private func goalExploreNext(snapshot: UISnapshot, attempts: inout [String: Int], deadline: Date) async throws -> GoalExploreResult {
        let key = snapshot.elements.compactMap { element -> String? in
            guard element.originBundleIdentifier == nil || element.originBundleIdentifier == bundleIdentifier,
                  ["button", "link", "cell", "staticText"].contains(element.role),
                  let label = element.label, !label.isEmpty else { return nil }
            return "\(element.role):\(label)"
        }.joined(separator: "|")
        let unconfirmedKey = "unconfirmed-progress:\(key)"
        if attempts[unconfirmedKey, default: 0] == 0,
           GoalNavigationSafety.unconfirmedProgressButton(in: snapshot, appBundleID: bundleIdentifier) != nil {
            attempts[unconfirmedKey] = 1
            let fresh = try await goalCapture(deadline)
            if let button = GoalNavigationSafety.unconfirmedProgressButton(in: fresh, appBundleID: bundleIdentifier),
               let label = button.label, let frame = button.frame,
               let provenance = await driver.provenance(for: fresh.captureID) {
                let perception = try? await driver.recognizeText(for: fresh.captureID,
                    deadline: min(deadline, Date().addingTimeInterval(10)))
                let capture = ScreenCapture(id: fresh.captureID, createdAt: fresh.capturedAt,
                    pixelSize: .init(width: provenance.pixelWidth, height: provenance.pixelHeight),
                    screenshotRelativePath: "captures/" + provenance.screenshotName)
                let validated = perception.flatMap { result in
                    (try? result.validate(capture: capture, now: Date(), maximumAge: 8)) != nil ? result : nil
                }
                let visualMatches = validated?.regions.filter { region in
                    guard TargetTextMatching.equals(region.text, label), region.confidence >= 0.4,
                          let point = try? provenance.screenPoint(for: region.center) else { return false }
                    return point.x >= frame.x && point.x <= frame.x + frame.width &&
                        point.y >= frame.y && point.y <= frame.y + frame.height
                }
                if visualMatches?.count == 1 {
                    let action = DrivenAction.tapElement(button)
                    let blockID = UUID()
                    events.yield(.blockStarted(blockID))
                    events.yield(.diagnostic("Rechecked the visible \(label) button before ending the test"))
                    events.yield(.actionStarted(blockID, action))
                    try await driver.perform(action, deadline: deadline)
                    events.yield(.action(blockID, action))
                    events.yield(.blockFinished(blockID, .passed, duration: 0, reason: "Selected visible \(label) button"))
                    return .otherAction
                }
            } else if GoalNavigationSafety.candidates(in: fresh, appBundleID: bundleIdentifier)
                .contains(where: { TargetTextMatching.progressAffordance($0.label) && !$0.isKeyboard }) {
                // Fresh accessibility evidence is now sufficient. Let the main
                // loop choose and verify the control normally.
                return .otherAction
            }
        }
        // Custom-drawn onboarding controls can expose only their text to XCTest.
        // A unique forward label is still a concrete visual target; bind the
        // tap to a fresh screenshot instead of swiping away from that page.
        let textKey = "visible-progress:\(key)"
        if attempts[textKey, default: 0] == 0,
           !GoalNavigationSafety.restrictedScreen(snapshot),
           !snapshot.elements.contains(where: { $0.containingAlertContext != nil }),
           snapshot.elements.filter({ element in
               element.role == "staticText" && element.isEnabled == true &&
               (element.originBundleIdentifier == nil || element.originBundleIdentifier == bundleIdentifier) &&
               ["begin", "continue", "next", "get started", "start"].contains(TargetTextMatching.normalize(element.label ?? ""))
           }).count == 1 {
            attempts[textKey] = 1
            let fresh = try await goalCapture(deadline)
            let labels = fresh.elements.filter { element in
                element.role == "staticText" && element.isEnabled == true &&
                (element.originBundleIdentifier == nil || element.originBundleIdentifier == bundleIdentifier) &&
                ["begin", "continue", "next", "get started", "start"].contains(TargetTextMatching.normalize(element.label ?? ""))
            }
            if labels.count == 1, let label = labels[0].label,
               !GoalNavigationSafety.restrictedScreen(fresh) {
                let perception = try await driver.recognizeText(for: fresh.captureID,
                    deadline: min(deadline, Date().addingTimeInterval(10)))
                events.yield(.diagnostic("Trying the visible \(label) control"))
                try await goalTextTap(label, snapshot: fresh, perception: perception, deadline: deadline)
                return .otherAction
            }
        }
        let directions: [SwipeDirection] = [.up, .down, .left, .right]
        let attempt = attempts[key, default: 0]
        guard attempt < directions.count,
              try await goalExplore(directions[attempt], snapshot: snapshot, deadline: deadline) else { return .none }
        attempts[key] = attempt + 1
        return .swipe(directions[attempt])
    }

    private func goalExplore(_ direction: SwipeDirection, snapshot: UISnapshot, deadline: Date) async throws -> Bool {
        guard snapshot.elements.contains(where: {
            $0.role == "application" && $0.originBundleIdentifier == bundleIdentifier
        }), !GoalNavigationSafety.restrictedScreen(snapshot),
              !snapshot.elements.contains(where: {
                  $0.containingAlertContext != nil || ["alert", "secureTextField", "textField"].contains($0.role)
              }) else { return false }
        let action = DrivenAction.swipe(direction, identifier: nil)
        let blockID = UUID()
        events.yield(.blockStarted(blockID))
        events.yield(.diagnostic("Exploring the app with a \(direction.rawValue) swipe"))
        events.yield(.actionStarted(blockID, action))
        try await driver.perform(action, deadline: deadline)
        events.yield(.action(blockID, action))
        events.yield(.blockFinished(blockID, .passed, duration: 0, reason: "Explored with a \(direction.rawValue) swipe"))
        return true
    }

    private func goalTextTap(_ text: String, snapshot: UISnapshot, perception: TextPerception, deadline: Date) async throws {
        guard let provenance = await driver.provenance(for: snapshot.captureID) else {
            throw DriverFailure.unavailable("Screenshot geometry is unavailable for the visible text control")
        }
        let capture = ScreenCapture(id: snapshot.captureID, createdAt: snapshot.capturedAt,
            pixelSize: PixelSize(width: provenance.pixelWidth, height: provenance.pixelHeight),
            screenshotRelativePath: "captures/" + provenance.screenshotName)
        let match = try perception.uniqueMatch(text: text, minimumConfidence: 0.4, capture: capture, maximumAge: 8)
        let blockID = UUID()
        let action: DrivenAction
        if let control = GoalNavigationSafety.enclosingVisualControl(match, perception: perception,
            snapshot: snapshot, appBundleID: bundleIdentifier) {
            action = .visualTextTap(capture: capture, perception: perception, text: text,
                control: control, minimumConfidence: 0.4, maximumAge: 8)
        } else {
            action = .textTap(capture: capture, perception: perception, text: text,
                minimumConfidence: 0.4, maximumAge: 8)
        }
        events.yield(.blockStarted(blockID))
        events.yield(.actionStarted(blockID, action))
        try await driver.perform(action, deadline: deadline)
        events.yield(.action(blockID, action))
        events.yield(.blockFinished(blockID, .passed, duration: 0, reason: "Selected visible \(text) control"))
    }

    private func goalSecureTextTap(snapshot: UISnapshot, perception: TextPerception,
                                   account: String, deadline: Date) async throws {
        guard let provenance = await driver.provenance(for: snapshot.captureID) else {
            throw DriverFailure.unavailable("Screenshot geometry is unavailable for secure input")
        }
        let capture = ScreenCapture(id: snapshot.captureID, createdAt: snapshot.capturedAt,
            pixelSize: PixelSize(width: provenance.pixelWidth, height: provenance.pixelHeight),
            screenshotRelativePath: "captures/" + provenance.screenshotName)
        _ = try perception.uniqueMatch(text: "Password", minimumConfidence: 0.4,
            capture: capture, maximumAge: 8)
        let blockID = UUID()
        let action = DrivenAction.secureTextTap(capture: capture, perception: perception,
            text: "Password", secret: .appleAccountPassword(account: account))
        events.yield(.blockStarted(blockID))
        events.yield(.actionStarted(blockID, action))
        try await driver.perform(action, deadline: deadline)
        events.yield(.action(blockID, action))
        events.yield(.blockFinished(blockID, .passed, duration: 0, reason: "Entered stored Apple Account password"))
    }

    private func goalCapture(_ deadline: Date) async throws -> UISnapshot {
        try Task.checkCancellation()
        guard Date() < deadline else { throw ProviderFailure.deadline }
        let snapshot = try await driver.capture(deadline: deadline)
        guard Date() < deadline else { throw ProviderFailure.deadline }
        try await recoveryGate.activate(snapshot.captureID)
        if let provenance = await driver.provenance(for: snapshot.captureID) { events.yield(.captureProvenance(provenance)) }
        events.yield(.capture(snapshot))
        return snapshot
    }

    private func goalProbeVisibleTab(_ tab: String, snapshot: UISnapshot, test: TestCase,
                                     evaluator: any AssertionEvaluating, deadline: Date,
                                     recentActions: [String]) async throws -> GoalNavigationResult? {
        guard let provenance = await driver.provenance(for: snapshot.captureID) else { return nil }
        let capture = ScreenCapture(id: snapshot.captureID, createdAt: snapshot.capturedAt,
            pixelSize: .init(width: provenance.pixelWidth, height: provenance.pixelHeight),
            screenshotRelativePath: "captures/" + provenance.screenshotName)
        guard let before = try? await driver.recognizeText(for: snapshot.captureID,
            deadline: min(deadline, Date().addingTimeInterval(10))),
              GoalNavigationSafety.visibleTabText(tab, in: before, capture: capture,
                  snapshot: snapshot, appBundleID: bundleIdentifier) else { return nil }
        events.yield(.perception(before))
        events.yield(.diagnostic("The visible \(tab) tab matches the requested finish state; selecting it before further navigation"))
        try await goalTextTap(tab, snapshot: snapshot, perception: before, deadline: deadline)

        var after = try await goalCapture(deadline)
        let interruption = InterruptionLibrary.recognize(after)
        if [.knownReminder, .alert, .permissionPrompt, .optionalNotificationPrompt].contains(interruption.kind) {
            after = try await recoverInterruptions(after, blockID: UUID(), deadline: deadline)
        }
        guard GoalNavigationSafety.likelyTabBar(in: after, appBundleID: bundleIdentifier),
              let afterProvenance = await driver.provenance(for: after.captureID) else {
            return .init(outcome: .needsReview, reason: "The \(tab) tab was tapped, but the resulting screen could not be verified")
        }
        let afterCapture = ScreenCapture(id: after.captureID, createdAt: after.capturedAt,
            pixelSize: .init(width: afterProvenance.pixelWidth, height: afterProvenance.pixelHeight),
            screenshotRelativePath: "captures/" + afterProvenance.screenshotName)
        guard let afterText = try? await driver.recognizeText(for: after.captureID,
            deadline: min(deadline, Date().addingTimeInterval(10))),
              GoalNavigationSafety.visibleTabText(tab, in: afterText, capture: afterCapture,
                  snapshot: after, appBundleID: bundleIdentifier) else {
            return .init(outcome: .needsReview, reason: "The \(tab) tab was tapped, but fresh OCR did not confirm it remained in the tab bar")
        }
        events.yield(.perception(afterText))
        let observed = GoalEvidenceItem(id: "verified-tab-selection", text:
            "Local OCR found \(tab) in the bottom tab bar on capture \(snapshot.captureID.rawValue.uuidString). " +
            "A capture-bound tap on that text was dispatched. Fresh capture \(after.captureID.rawValue.uuidString) " +
            "still shows \(tab) in the bottom tab bar without a blocking overlay.")
        let assessment = await assessGoal(test, established: .passed, evaluator: evaluator,
            deadline: deadline, verifiedActions: recentActions + ["Tapped visible \(tab) tab"],
            observedEvidence: [observed])
        events.yield(.goalAssessment(assessment))
        return .init(outcome: assessment.outcome, reason: assessment.reason)
    }

    private func goalAcceptAttestation(_ statement: String, deadline: Date) async throws -> Bool {
        var snapshot = try await goalCapture(deadline)
        for attempt in 0..<5 {
            guard GoalNavigationSafety.humanAttestationReason(in: snapshot) == statement else { return false }
            let switches = snapshot.elements.filter { element in
                guard let frame = element.frame else { return false }
                return ["switch", "checkbox", "other"].contains(element.role) &&
                    (element.label ?? "").isEmpty && ["0", "1"].contains(element.value ?? "") &&
                    frame.width >= 20 && frame.width <= 100 && frame.height >= 15 && frame.height <= 70 &&
                    (element.originBundleIdentifier == nil || element.originBundleIdentifier == bundleIdentifier)
            }
            if switches.count == 1, switches[0].value == "0" {
                let action = DrivenAction.tapElement(switches[0])
                let blockID = UUID()
                events.yield(.blockStarted(blockID))
                events.yield(.actionStarted(blockID, action))
                try await driver.perform(action, deadline: deadline)
                events.yield(.action(blockID, action))
                events.yield(.blockFinished(blockID, .passed, duration: 0, reason: "Selected the declaration checkbox"))
                snapshot = try await goalCapture(deadline)
                continue
            }
            let accept = snapshot.elements.filter { element in
                guard element.role == "button", let label = element.label else { return false }
                let normalized = TargetTextMatching.normalize(label)
                return (normalized.contains("accept") || normalized.contains("agree") || normalized.contains("confirm")) &&
                    element.isEnabled == true && element.isHittable == true &&
                    (element.originBundleIdentifier == nil || element.originBundleIdentifier == bundleIdentifier)
            }
            if accept.count == 1 {
                let action = DrivenAction.tapElement(accept[0])
                let blockID = UUID()
                events.yield(.blockStarted(blockID))
                events.yield(.actionStarted(blockID, action))
                try await driver.perform(action, deadline: deadline)
                events.yield(.action(blockID, action))
                events.yield(.blockFinished(blockID, .passed, duration: 0, reason: "Accepted the onboarding declaration"))
                for verificationAttempt in 0..<3 {
                    let after = try await goalCapture(deadline)
                    if GoalNavigationSafety.humanAttestationReason(in: after) != statement { return true }
                    if verificationAttempt < 2 { try await Task.sleep(for: .milliseconds(200)) }
                }
                return false
            }
            guard attempt < 4 else { break }
            let action = DrivenAction.swipe(.up, identifier: nil)
            let blockID = UUID()
            events.yield(.blockStarted(blockID))
            events.yield(.actionStarted(blockID, action))
            try await driver.perform(action, deadline: deadline)
            events.yield(.action(blockID, action))
            events.yield(.blockFinished(blockID, .passed, duration: 0, reason: "Scrolled to the declaration control"))
            snapshot = try await goalCapture(deadline)
        }
        return false
    }

    /// The wall-clock deadline includes setup, model calls, actions and final verification.
    func navigateGoal(_ test: TestCase, navigator: any GoalNavigating, evaluator: any AssertionEvaluating, wallDeadline: Date,
                      replayStore: (any GoalReplayStoring)? = nil, replayIdentity: GoalReplayRoute.Identity? = nil,
                      savedInputs: [GoalSavedInput] = []) async -> RunOutcome {
        await navigateGoalWithReason(test, navigator: navigator, evaluator: evaluator, wallDeadline: wallDeadline,
            replayStore: replayStore, replayIdentity: replayIdentity, savedInputs: savedInputs).outcome
    }

    func navigateGoalWithReason(_ test: TestCase, navigator: any GoalNavigating, evaluator: any AssertionEvaluating, wallDeadline: Date,
                                replayStore: (any GoalReplayStoring)? = nil, replayIdentity: GoalReplayRoute.Identity? = nil,
                                savedInputs: [GoalSavedInput] = []) async -> GoalNavigationResult {
        var wallDeadline = wallDeadline
        var replay = replayIdentity == nil ? nil : await replayStore?.load(replayIdentity!)
        var replayIndex = 0
        var recordedSteps: [GoalReplayRoute.Step] = []
        var routeEligible = true
        var recent: [String] = []
        var lastSignature: String?
        var unchanged = 0
        var steps = 0
        var unproductiveLabels: Set<String> = []
        var noProgressAttempts: [String: Int] = [:]
        var lastNoProgressReason: String?
        var accountSheetUnderlay: [String]?
        var accountSheetUnderlayImage: String?
        var applePasswordAttempts: Set<String> = []
        var postAccountNoProgress = 0
        var passwordSubmittedAt: Date?
        var unsettledApplePasswordCaptures = 0
        var staleRecaptures = 0
        var explorationAttempts: [String: Int] = [:]
        var pendingExploration: (direction: SwipeDirection, content: [String])?
        var attemptedSavedInputs: Set<String> = []
        var tabProbeAttempted = false
        var ocrAttemptedScreens: Set<String> = []
        var ocrFailures: [String: Int] = [:]
        var goalOCRWarmed = false
        var forceOCRForScreen: String?
        var startingScreenEvidence: GoalEvidenceItem?
        func visibleContent(_ snapshot: UISnapshot) -> [String] {
            snapshot.elements.compactMap { element in
                guard element.originBundleIdentifier == nil || element.originBundleIdentifier == bundleIdentifier,
                      ["button", "link", "cell", "staticText"].contains(element.role),
                      let label = element.label, !label.isEmpty else { return nil }
                return "\(element.role):\(label)"
            }
        }
        while Date() < wallDeadline, steps < 80 {
            do {
                try Task.checkCancellation()
                var snapshot = try await goalCapture(wallDeadline)
                if let pending = pendingExploration {
                    let changed = visibleContent(snapshot) != pending.content
                    events.yield(.diagnostic("Exploratory \(pending.direction.rawValue) swipe " +
                        (changed ? "changed visible app content" : "did not change visible app content")))
                    pendingExploration = nil
                }
                if startingScreenEvidence == nil {
                    let controls = snapshot.elements.filter { element in
                        element.role == "button" && element.isHittable == true &&
                            (element.originBundleIdentifier == nil || element.originBundleIdentifier == bundleIdentifier)
                    }.prefix(16).compactMap { element -> String? in
                        guard let label = element.label, !label.isEmpty else { return nil }
                        return "\(element.identifier ?? "button"): \(label)"
                    }
                    if controls.count >= 3 {
                        startingScreenEvidence = .init(id: "starting-screen",
                            text: "Earlier live capture \(snapshot.captureID.rawValue.uuidString) showed app controls: \(controls.joined(separator: "; "))")
                    }
                }
                let imageFingerprint = await driver.imageFingerprint(for: snapshot.captureID)
                if let accountSheetUnderlay, visibleContent(snapshot) == accountSheetUnderlay {
                    if imageFingerprint != accountSheetUnderlayImage {
                        let perception = try await driver.recognizeText(for: snapshot.captureID,
                            deadline: min(wallDeadline, Date().addingTimeInterval(20)))
                        if let account = VisualInterruption.applePasswordAccount(perception) {
                            unsettledApplePasswordCaptures = 0
                            if applePasswordAttempts.contains(account) {
                                if let passwordSubmittedAt, Date().timeIntervalSince(passwordSubmittedAt) < 8 {
                                    try await Task.sleep(for: .seconds(min(1, max(0, wallDeadline.timeIntervalSinceNow))))
                                    continue
                                }
                                let blocker = ExecutionBlocker.authenticationChallenge("Apple sign-in did not advance after one password attempt")
                                events.yield(.blocker(blocker))
                                return .init(outcome: .needsReview, reason: "Apple sign-in did not advance after one password attempt")
                            }
                            applePasswordAttempts.insert(account)
                            // The returning-account sheet animates upward after "Sign In with
                            // Password". Its password field moves substantially during that
                            // transition, so use a fresh OCR point after the animation settles.
                            try await Task.sleep(for: .seconds(min(2, max(0, wallDeadline.timeIntervalSinceNow))))
                            let passwordScreen = try await goalCapture(wallDeadline)
                            let passwordText = try await driver.recognizeText(for: passwordScreen.captureID,
                                deadline: min(wallDeadline, Date().addingTimeInterval(20)))
                            guard VisualInterruption.applePasswordAccount(passwordText) == account else {
                                events.yield(.diagnostic("Apple password screen changed while settling; observing again"))
                                applePasswordAttempts.remove(account)
                                continue
                            }
                            routeEligible = false
                            replay = nil
                            try await goalSecureTextTap(snapshot: passwordScreen, perception: passwordText,
                                account: account, deadline: wallDeadline)
                            staleRecaptures = 0
                            let filled = try await goalCapture(wallDeadline)
                            let filledText = try await driver.recognizeText(for: filled.captureID,
                                deadline: min(wallDeadline, Date().addingTimeInterval(20)))
                            guard !filledText.regions.contains(where: {
                                TargetTextMatching.equals($0.text, "Password") && $0.confidence >= 0.4
                            }) else {
                                let blocker = ExecutionBlocker.secureInputUnverified(.appleAccountPassword(account: account))
                                events.yield(.blocker(blocker))
                                return .init(outcome: .needsReview, reason: "Apple password field still appears empty after secure input")
                            }
                            guard filledText.regions.contains(where: {
                                TargetTextMatching.equals($0.text, "Sign In") && $0.confidence >= 0.4
                            }) else {
                                let blocker = ExecutionBlocker.authenticationChallenge("Apple password was entered but Sign In could not be verified")
                                events.yield(.blocker(blocker))
                                return .init(outcome: .needsReview, reason: "Apple Sign In control could not be verified")
                            }
                            try await goalTextTap("Sign In", snapshot: filled,
                                perception: filledText, deadline: wallDeadline)
                            passwordSubmittedAt = Date()
                            try await Task.sleep(for: .seconds(min(1.5, max(0, wallDeadline.timeIntervalSinceNow))))
                            continue
                        }
                        if VisualInterruption.recognize(perception) != nil {
                            unsettledApplePasswordCaptures = 0
                            events.yield(.diagnostic("Apple account sheet is still open; observing again"))
                            try await Task.sleep(for: .seconds(min(1, max(0, wallDeadline.timeIntervalSinceNow))))
                            continue
                        }
                        if let passwordSubmittedAt {
                            // AuthKit dismisses its sheet before the app finishes its own
                            // sign-in. The welcome screen's animation also changes the image
                            // fingerprint, so an image change alone is not an auth challenge.
                            if Date().timeIntervalSince(passwordSubmittedAt) < 20 {
                                events.yield(.diagnostic("Apple sheet closed; waiting for app sign-in to finish"))
                                try await Task.sleep(for: .seconds(min(1, max(0, wallDeadline.timeIntervalSinceNow))))
                                continue
                            }
                            let reason = "Apple sign-in returned to the app's login screen without advancing after 20 seconds"
                            events.yield(.blocker(.authenticationChallenge(reason)))
                            return .init(outcome: .needsReview, reason: reason)
                        }
                        // AuthKit animates the account sheet into its password form.
                        // The first screenshot can contain clipped text from both
                        // positions, so an unmatched frame is not yet a new challenge.
                        unsettledApplePasswordCaptures += 1
                        if unsettledApplePasswordCaptures <= 6 && Date() < wallDeadline {
                            events.yield(.diagnostic("Apple password sheet is settling; checking a fresh screen"))
                            try await Task.sleep(for: .seconds(min(0.5, max(0, wallDeadline.timeIntervalSinceNow))))
                            continue
                        }
                        let blocker = ExecutionBlocker.authenticationChallenge("An unrecognized Apple authentication screen needs attention")
                        events.yield(.blocker(blocker))
                        return .init(outcome: .needsReview, reason: "An unrecognized Apple authentication screen needs attention")
                    }
                    // The sheet may close before the app has updated its own tree.
                    postAccountNoProgress += 1
                    if postAccountNoProgress <= 6 && Date() < wallDeadline {
                        try await Task.sleep(for: .seconds(min(1, max(0, wallDeadline.timeIntervalSinceNow))))
                        continue
                    }
                    return .init(outcome: .needsReview, reason: "Apple sign-in closed without advancing past the login screen")
                }
                accountSheetUnderlay = nil
                accountSheetUnderlayImage = nil
                let observed = InterruptionLibrary.recognize(snapshot)
                if [.knownReminder, .alert, .permissionPrompt, .authenticationRequired, .optionalNotificationPrompt].contains(observed.kind) {
                    routeEligible = false
                    snapshot = try await recoverInterruptions(snapshot, blockID: UUID(), deadline: wallDeadline)
                }
                if let statement = GoalNavigationSafety.humanAttestationReason(in: snapshot) {
                    routeEligible = false
                    replay = nil
                    guard try await goalAcceptAttestation(statement, deadline: wallDeadline) else {
                        return .init(outcome: .needsReview, reason: "Declaration controls could not be verified on the live screen")
                    }
                    steps += 1
                    lastSignature = nil
                    unchanged = 0
                    continue
                }
                if let (field, input) = GoalNavigationSafety.savedInputTarget(in: snapshot,
                    inputs: savedInputs.filter { !attemptedSavedInputs.contains($0.name) }, appBundleID: bundleIdentifier) {
                    routeEligible = false
                    replay = nil
                    // The value is deliberately absent from action events.
                    try await driver.perform(.typeTextElement(input.value, field), deadline: wallDeadline)
                    attemptedSavedInputs.insert(input.name)
                    events.yield(.diagnostic("Entered saved input for \(input.name)"))
                    steps += 1
                    lastSignature = nil
                    unchanged = 0
                    continue
                }
                if !tabProbeAttempted,
                   let tab = GoalNavigationSafety.requestedActiveTab(test.successCriteria),
                   GoalNavigationSafety.likelyTabBar(in: snapshot, appBundleID: bundleIdentifier) {
                    tabProbeAttempted = true
                    if let result = try await goalProbeVisibleTab(tab, snapshot: snapshot, test: test,
                        evaluator: evaluator, deadline: wallDeadline, recentActions: recent) {
                        return result
                    }
                }
                if let visibleSuccess = GoalNavigationSafety.literalVisibleSuccess(
                    test.successCriteria, snapshot: snapshot, appBundleID: bundleIdentifier) {
                    events.yield(.diagnostic("Fresh app text shows the literal success criterion: \(visibleSuccess)"))
                    let assessment = await assessGoal(test, established: .passed, evaluator: evaluator,
                        deadline: wallDeadline, verifiedActions: recent)
                    events.yield(.goalAssessment(assessment))
                    return .init(outcome: assessment.outcome, reason: assessment.reason)
                }
                let signature = snapshot.elements.map { "\($0.originBundleIdentifier ?? ""):\($0.role):\($0.identifier ?? ""):\($0.label ?? ""):\($0.value ?? ""):\($0.containingAlertContext ?? "")" }.joined(separator: "|") + ":image=\(imageFingerprint ?? "unknown")"
                let ocrScreenKey = visibleContent(snapshot).joined(separator: "|")
                unchanged = signature == lastSignature ? unchanged + 1 : 0
                lastSignature = signature
                if unchanged >= 3 && forceOCRForScreen != ocrScreenKey {
                    routeEligible = false
                    replay = nil
                    let exploration = try await goalExploreNext(snapshot: snapshot, attempts: &explorationAttempts, deadline: wallDeadline)
                    if case .swipe(let direction) = exploration {
                        pendingExploration = (direction, visibleContent(snapshot))
                    }
                    if exploration.didAct {
                        unchanged = 0
                        steps += 1
                        continue
                    }
                    let reason = lastNoProgressReason ?? "Goal navigation stopped because the screen did not change"
                    events.yield(.diagnostic(reason))
                    return .init(outcome: .needsReview, reason: reason)
                }
                let observation = InterruptionLibrary.recognize(snapshot)
                if [.permissionPrompt, .authenticationExpired, .authenticationRequired, .applicationUnavailable, .offline].contains(observation.kind) {
                    let reason = "Goal navigation needs review: \(observation.reason)"
                    events.yield(.diagnostic(reason))
                    return .init(outcome: .needsReview, reason: reason)
                }
                var candidates = GoalNavigationSafety.candidates(in: snapshot, appBundleID: bundleIdentifier)
                    .filter { !unproductiveLabels.contains($0.label) }
                    .filter { GoalNavigationSafety.requestedActiveTab(test.successCriteria) == nil ||
                        !GoalNavigationSafety.isDiagnosticControl($0.label) }
                var recognizedText: [String] = []
                let explicitlyRequestedOCR = GoalNavigationSafety.shouldCheckOCR(goal: test.goal, candidates: candidates)
                let useScreenVision = screenVisionEnabled && imageDisclosureChoice == .allowRemoteForThisRun
                let shouldRecognize = forceOCRForScreen == ocrScreenKey ||
                    (!ocrAttemptedScreens.contains(ocrScreenKey) && explicitlyRequestedOCR) || useScreenVision
                if shouldRecognize, !goalOCRWarmed {
                    goalOCRWarmed = true
                    events.yield(.diagnostic("Warming OCR for a screen without a credible accessibility route"))
                    do {
                        events.yield(.perceptionWarmup(try await driver.warmupPerceptionFast(
                            deadline: min(wallDeadline, Date().addingTimeInterval(120)))))
                        continue // The capture used to decide on OCR is now stale.
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        events.yield(.diagnostic("Visual targeting is unavailable: \(error.localizedDescription)"))
                        if explicitlyRequestedOCR {
                            return .init(outcome: .needsReview,
                                reason: "Visual targeting could not inspect the requested control")
                        }
                        // A general goal can still proceed through accessible
                        // controls or bounded exploration when OCR is unavailable.
                        ocrAttemptedScreens.insert(ocrScreenKey)
                        forceOCRForScreen = nil
                        continue
                    }
                }
                if shouldRecognize,
                   let provenance = await driver.provenance(for: snapshot.captureID) {
                    forceOCRForScreen = nil
                    ocrAttemptedScreens.insert(ocrScreenKey)
                    let capture = ScreenCapture(id: snapshot.captureID, createdAt: snapshot.capturedAt,
                        pixelSize: .init(width: provenance.pixelWidth, height: provenance.pixelHeight),
                        screenshotRelativePath: "captures/" + provenance.screenshotName)
                    do {
                        var perception = try await driver.recognizeTextFast(for: snapshot.captureID,
                            deadline: min(wallDeadline, Date().addingTimeInterval(10)))
                        events.yield(.perception(perception))
                        let fastTargets = GoalNavigationSafety.ocrCandidates(perception, snapshot: snapshot,
                            appBundleID: bundleIdentifier).filter { !unproductiveLabels.contains($0.label) }
                        let fastRequest = GoalNavigationRequest(goal: test.goal, successCriteria: test.successCriteria,
                            snapshot: snapshot, candidates: candidates + fastTargets, recentActions: recent,
                            suppressedLabels: unproductiveLabels, recognizedText: perception.regions.map(\.text))
                        if GoalNavigationSafety.shouldCheckOCR(goal: test.goal, candidates: candidates),
                           GoalNavigationSafety.requestedOCRChoice(fastRequest, snapshot: snapshot,
                               appBundleID: bundleIdentifier) == nil,
                           GoalNavigationSafety.unactionableRequestedHeading(goal: test.goal,
                               snapshot: snapshot, appBundleID: bundleIdentifier) == nil {
                            events.yield(.diagnostic("Fast OCR did not find a unique requested control; trying accurate OCR"))
                            perception = try await driver.recognizeText(for: snapshot.captureID,
                                deadline: min(wallDeadline, Date().addingTimeInterval(70)))
                            if Date().timeIntervalSince(snapshot.capturedAt) >= 8 {
                                forceOCRForScreen = ocrScreenKey
                                events.yield(.diagnostic("Accurate OCR initialized after capture aged; recapturing"))
                                continue
                            }
                        }
                        try perception.validate(capture: capture, now: Date(), maximumAge: 10)
                        if perception.provider != "apple.vision.ocr.fast" { events.yield(.perception(perception)) }
                        recognizedText = perception.regions.map(\.text)
                        let ocrTargets = GoalNavigationSafety.ocrCandidates(perception, snapshot: snapshot,
                            appBundleID: bundleIdentifier)
                            .filter { !unproductiveLabels.contains($0.label) }
                        candidates += ocrTargets.prefix(max(0, 120 - candidates.count))
                        events.yield(.diagnostic("OCR found \(ocrTargets.count) possible text targets beyond accessibility controls"))
                    } catch {
                        events.yield(.diagnostic("Screen-text recognition could not supply a target: \(error.localizedDescription)"))
                        if GoalNavigationSafety.shouldCheckOCR(goal: test.goal, candidates: candidates) {
                            ocrFailures[ocrScreenKey, default: 0] += 1
                            if ocrFailures[ocrScreenKey, default: 0] < 2,
                               wallDeadline.timeIntervalSinceNow > 12 {
                                forceOCRForScreen = ocrScreenKey
                                continue
                            }
                            return .init(outcome: .needsReview,
                                reason: "Visual check failed before the requested control could be identified")
                        }
                    }
                }
                let imageData: Data?
                if useScreenVision, Date().timeIntervalSince(snapshot.capturedAt) < 8 {
                    imageData = try? await driver.visualImageData(for: snapshot.captureID)
                } else {
                    imageData = nil
                }
                let request = GoalNavigationRequest(goal: test.goal, successCriteria: test.successCriteria,
                    snapshot: snapshot, candidates: candidates, recentActions: recent,
                    suppressedLabels: unproductiveLabels, recognizedText: recognizedText,
                    imageData: imageData)
                if let heading = GoalNavigationSafety.unactionableRequestedHeading(goal: test.goal,
                    snapshot: snapshot, appBundleID: bundleIdentifier) {
                    let reason = "Requested \(heading) appears only as a noninteractive heading"
                    events.yield(.diagnostic(reason))
                    return .init(outcome: .needsReview, reason: reason)
                }
                if staleRecaptures > 0,
                   GoalNavigationSafety.shouldCheckOCR(goal: test.goal, candidates: candidates),
                   GoalNavigationSafety.requestedOCRChoice(request, snapshot: snapshot,
                       appBundleID: bundleIdentifier) == nil {
                    let reason = "Visual target moved and no unique requested control remains in the fresh capture"
                    events.yield(.diagnostic(reason))
                    return .init(outcome: .needsReview, reason: reason)
                }
                if let route = replay, replayIndex == route.steps.count {
                    let evidence = await assessGoal(test, established: .passed, evaluator: evaluator,
                        deadline: wallDeadline, verifiedActions: recent)
                    events.yield(.goalAssessment(evidence))
                    if evidence.outcome == .passed {
                        events.yield(.diagnostic("Verified replay completed; final goal independently passed"))
                        return .init(outcome: .passed, reason: evidence.reason)
                    }
                    events.yield(.diagnostic("Replay reached its end without passing final verification; resuming live navigation"))
                    replay = nil
                    routeEligible = false
                }
                var replayDecision: GoalNavigationDecision?
                if let route = replay, replayIndex < route.steps.count {
                    if let candidate = GoalReplaySafety.candidate(for: route.steps[replayIndex], in: snapshot,
                                                                 appBundleID: bundleIdentifier) {
                        replayDecision = .init(captureID: snapshot.captureID, kind: .act,
                            candidateID: candidate.id, confidence: 1, reason: "Verified route step \(replayIndex + 1)")
                    } else {
                        events.yield(.diagnostic("Verified route no longer matches a unique safe control; resuming live navigation"))
                        replay = nil
                    }
                }
                let modelDecision: GoalNavigationDecision?
                if let replayDecision {
                    modelDecision = replayDecision
                } else if !useScreenVision,
                          let requestedOCR = GoalNavigationSafety.requestedOCRChoice(request,
                              snapshot: snapshot, appBundleID: bundleIdentifier) {
                    modelDecision = requestedOCR
                } else { do {
                    let advised = try await boundedProviderCall(deadline: min(wallDeadline, Date().addingTimeInterval(30))) { try await navigator.decide(request) }
                    modelDecision = useScreenVision ? advised :
                        (GoalNavigationSafety.requestedOCRChoice(request,
                            snapshot: snapshot, appBundleID: bundleIdentifier) ?? advised)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    events.yield(.diagnostic("Goal navigator unavailable: \(error.localizedDescription)"))
                    modelDecision = GoalNavigationSafety.requestedOCRChoice(request,
                        snapshot: snapshot, appBundleID: bundleIdentifier)
                } }
                var decision: GoalNavigationDecision
                if let modelDecision, modelDecision.kind != .blocked {
                    decision = modelDecision
                } else if let fallback = GoalNavigationSafety.obviousChoice(request, snapshot: snapshot, appBundleID: bundleIdentifier)
                    ?? GoalNavigationSafety.questionChoice(request, snapshot: snapshot, appBundleID: bundleIdentifier) {
                    decision = fallback
                } else if let modelDecision {
                    decision = modelDecision
                } else {
                    if !ocrAttemptedScreens.contains(ocrScreenKey) {
                        forceOCRForScreen = ocrScreenKey
                        events.yield(.diagnostic("Accessibility navigation stalled; checking screenshot text"))
                        continue
                    }
                    routeEligible = false
                    replay = nil
                    let exploration = try await goalExploreNext(snapshot: snapshot, attempts: &explorationAttempts, deadline: wallDeadline)
                    if case .swipe(let direction) = exploration {
                        pendingExploration = (direction, visibleContent(snapshot))
                    }
                    if exploration.didAct {
                        steps += 1
                        continue
                    }
                    if GoalNavigationSafety.emptyFieldBlocksContinue(in: snapshot, appBundleID: bundleIdentifier) {
                        let reason = "An empty field kept Continue disabled. Add a saved input for this step; see diagnostics for why navigation was unavailable."
                        events.yield(.diagnostic(reason))
                        return .init(outcome: .needsReview, reason: reason)
                    }
                    return .init(outcome: .needsReview, reason: lastNoProgressReason ?? "Goal navigator was unavailable and no safe progress choice was visible")
                }
                guard decision.captureID == snapshot.captureID, decision.confidence.isFinite, (0...1).contains(decision.confidence), !decision.reason.isEmpty else {
                    events.yield(.diagnostic("Goal navigator returned an invalid decision")); return .init(outcome: .needsReview, reason: "Goal navigator returned an invalid decision")
                }
                if decision.kind == .act,
                   GoalNavigationSafety.selectedElement(decision, request: request, snapshot: snapshot, appBundleID: bundleIdentifier) == nil,
                   !request.candidates.contains(where: { $0.id == decision.candidateID && $0.isOCR }) {
                    guard let fallback = GoalNavigationSafety.obviousChoice(request, snapshot: snapshot, appBundleID: bundleIdentifier)
                        ?? GoalNavigationSafety.questionChoice(request, snapshot: snapshot, appBundleID: bundleIdentifier) else {
                        if !ocrAttemptedScreens.contains(ocrScreenKey) {
                            forceOCRForScreen = ocrScreenKey
                            events.yield(.diagnostic("Accessibility action could not be verified; checking screenshot text"))
                            continue
                        }
                        routeEligible = false
                        replay = nil
                        let exploration = try await goalExploreNext(snapshot: snapshot, attempts: &explorationAttempts, deadline: wallDeadline)
                        if case .swipe(let direction) = exploration {
                            pendingExploration = (direction, visibleContent(snapshot))
                        }
                        if exploration.didAct {
                            steps += 1
                            continue
                        }
                        events.yield(.diagnostic("Goal action rejected: candidate=\(decision.candidateID ?? "none"), confidence=\(decision.confidence); no safe progress choice"))
                        return .init(outcome: .needsReview, reason: lastNoProgressReason ?? "Goal action could not be verified and no safe progress choice was visible")
                    }
                    events.yield(.diagnostic("Goal model action could not be verified; using a visible progress choice: \(fallback.reason)"))
                    decision = fallback
                }
                events.yield(.diagnostic("Goal navigation: \(decision.reason)"))
                switch decision.kind {
                case .blocked:
                    if !ocrAttemptedScreens.contains(ocrScreenKey) {
                        forceOCRForScreen = ocrScreenKey
                        events.yield(.diagnostic("Accessibility navigation stalled; checking screenshot text"))
                        continue
                    }
                    routeEligible = false
                    replay = nil
                    let exploration = try await goalExploreNext(snapshot: snapshot, attempts: &explorationAttempts, deadline: wallDeadline)
                    if case .swipe(let direction) = exploration {
                        pendingExploration = (direction, visibleContent(snapshot))
                    }
                    if exploration.didAct {
                        steps += 1
                        continue
                    }
                    return .init(outcome: .needsReview, reason: lastNoProgressReason ?? decision.reason)
                case .complete:
                    var observedEvidence: [GoalEvidenceItem] = []
                    if let startingScreenEvidence { observedEvidence.append(startingScreenEvidence) }
                    if let before = GoalNavigationSafety.visibleTimer(in: snapshot) {
                        try await Task.sleep(for: .seconds(min(2, max(0, wallDeadline.timeIntervalSinceNow))))
                        let later = try await goalCapture(wallDeadline)
                        if let after = GoalNavigationSafety.visibleTimer(in: later), after.seconds < before.seconds,
                           later.elements.contains(where: { $0.role == "button" &&
                               TargetTextMatching.normalize($0.label ?? "").contains("pause") }) {
                            observedEvidence.append(.init(id: "observed-countdown",
                                text: "Two live captures show the timer decreasing from \(before.text) to \(after.text) while a Pause control is visible."))
                        }
                    }
                    if decision.confidence < 0.5 && observedEvidence.isEmpty {
                        events.yield(.diagnostic("Goal completion was uncertain; observing the live screen again"))
                        steps += 1
                        continue
                    }
                    let evidence = await assessGoal(test, established: .passed, evaluator: evaluator,
                        deadline: wallDeadline, verifiedActions: recent, observedEvidence: observedEvidence)
                    events.yield(.goalAssessment(evidence))
                    if evidence.outcome == .passed, routeEligible, !recordedSteps.isEmpty,
                       let replayStore, let replayIdentity {
                        do {
                            try await replayStore.save(.init(identity: replayIdentity, steps: recordedSteps))
                            events.yield(.diagnostic("Saved verified goal route with \(recordedSteps.count) steps"))
                        } catch {
                            events.yield(.diagnostic("Verified goal route could not be saved"))
                        }
                    }
                    if evidence.outcome == .needsReview && Date() < wallDeadline && steps < 78 {
                        events.yield(.diagnostic("Final evidence was uncertain; continuing to observe the goal"))
                        steps += 1
                        continue
                    }
                    return .init(outcome: evidence.outcome, reason: evidence.reason)
                case .act:
                    if let ocrCandidate = request.candidates.first(where: { $0.id == decision.candidateID && $0.isOCR }) {
                        routeEligible = false
                        replay = nil
                        let fresh = try await goalCapture(wallDeadline)
                        guard !GoalNavigationSafety.restrictedScreen(fresh),
                              !fresh.elements.contains(where: { $0.containingAlertContext != nil }) else {
                            events.yield(.diagnostic("An overlay or restricted screen appeared before the OCR tap; observing again"))
                            continue
                        }
                        var perception = try await driver.recognizeTextFast(for: fresh.captureID,
                            deadline: min(wallDeadline, Date().addingTimeInterval(10)))
                        events.yield(.perception(perception))
                        func containsRequestedTarget(_ result: TextPerception) -> Bool {
                            GoalNavigationSafety.ocrCandidates(result, snapshot: fresh,
                                appBundleID: bundleIdentifier).contains(where: {
                                    TargetTextMatching.equals($0.label, ocrCandidate.label)
                                })
                        }
                        if !containsRequestedTarget(perception) {
                            perception = try await driver.recognizeText(for: fresh.captureID,
                                deadline: min(wallDeadline, Date().addingTimeInterval(70)))
                            if Date().timeIntervalSince(fresh.capturedAt) >= 8 {
                                events.yield(.diagnostic("Accurate OCR finished after capture aged; observing again"))
                                continue
                            }
                            events.yield(.perception(perception))
                        }
                        guard containsRequestedTarget(perception) else {
                            events.yield(.diagnostic("OCR target was no longer an app text target; observing again"))
                            continue
                        }
                        do {
                            try await goalTextTap(ocrCandidate.label, snapshot: fresh,
                                perception: perception, deadline: wallDeadline)
                        } catch PerceptionFailure.noMatch {
                            events.yield(.diagnostic("OCR target moved or disappeared; observing again"))
                            continue
                        } catch PerceptionFailure.ambiguousMatch {
                            events.yield(.diagnostic("OCR target was ambiguous on the fresh screenshot; observing again"))
                            continue
                        }
                        var after = try await goalCapture(wallDeadline)
                        for _ in 0..<3 where visibleContent(after) == visibleContent(fresh) {
                            try await Task.sleep(for: .seconds(min(1.25, max(0, wallDeadline.timeIntervalSinceNow))))
                            after = try await goalCapture(wallDeadline)
                        }
                        let afterText = try? await driver.recognizeTextFast(for: after.captureID,
                            deadline: min(wallDeadline, Date().addingTimeInterval(10)))
                        if let afterText { events.yield(.perception(afterText)) }
                        if let afterText, VisualInterruption.recognize(afterText) != nil {
                            events.yield(.diagnostic("Visual interruption appeared after the tap; observing recovery state"))
                            continue
                        }
                        let targetStillVisible = visibleContent(after) == visibleContent(fresh) || (afterText?.regions.contains(where: {
                            $0.confidence >= 0.4 && TargetTextMatching.equals($0.text, ocrCandidate.label)
                        }) ?? true)
                        if visibleContent(after) == visibleContent(fresh) && targetStillVisible {
                            unproductiveLabels.insert(ocrCandidate.label)
                            lastNoProgressReason = "After tapping visible text \(ocrCandidate.label), app content and target text did not advance."
                            events.yield(.diagnostic(lastNoProgressReason!))
                            return .init(outcome: .needsReview, reason: lastNoProgressReason!)
                        } else {
                            unproductiveLabels.removeAll()
                            lastNoProgressReason = nil
                        }
                        recent.append("Tapped OCR text: \(ocrCandidate.label)")
                        if recent.count > 8 { recent.removeFirst() }
                        steps += 1
                        continue
                    }
                    guard let element = GoalNavigationSafety.selectedElement(decision, request: request, snapshot: snapshot, appBundleID: bundleIdentifier) else {
                        events.yield(.diagnostic("Goal action was not a safe control on this capture")); return .init(outcome: .needsReview, reason: "Goal action was not a safe control on this capture")
                    }
                    if GoalNavigationSafety.mismatchesExplicitTap(element.label ?? element.identifier ?? "", goal: test.goal) {
                        let reason = "Visible \(element.label ?? element.identifier ?? element.role) control does not match the requested tap target"
                        events.yield(.diagnostic(reason))
                        return .init(outcome: .needsReview, reason: reason)
                    }
                    var actionSnapshot = snapshot
                    var actionElement = element
                    if Date().timeIntervalSince(snapshot.capturedAt) >= 5 {
                        let fresh = try await goalCapture(wallDeadline)
                        guard visibleContent(fresh) == visibleContent(snapshot),
                              let rebound = GoalNavigationSafety.reboundElement(element, in: fresh, appBundleID: bundleIdentifier) else {
                            events.yield(.diagnostic("Screen changed while choosing the next goal action; observing again"))
                            continue
                        }
                        if let oldImage = imageFingerprint,
                           let newImage = await driver.imageFingerprint(for: fresh.captureID), oldImage != newImage {
                            // Status-bar time, animation and caret blinking can change the
                            // full screenshot without moving this unique live control.
                            // Check for a system sheet, then dispatch against the fresh capture.
                            if let text = try? await driver.recognizeText(for: fresh.captureID,
                                deadline: min(wallDeadline, Date().addingTimeInterval(8))),
                               VisualInterruption.recognize(text) != nil {
                                events.yield(.diagnostic("A system sheet appeared while choosing the next action; observing again"))
                                continue
                            }
                            events.yield(.diagnostic("Image changed; matched the control again on a fresh capture"))
                        }
                        actionSnapshot = fresh
                        actionElement = rebound
                    }
                    let blockID = UUID()
                    let action = DrivenAction.tapElement(actionElement)
                    events.yield(.blockStarted(blockID))
                    events.yield(.diagnostic("Trying \(actionElement.label ?? actionElement.identifier ?? actionElement.role)"))
                    events.yield(.actionStarted(blockID, action))
                    try await driver.perform(action, deadline: wallDeadline)
                    staleRecaptures = 0
                    guard Date() < wallDeadline else { throw DriverFailure.uncertain("Goal action completed after the 10-minute limit") }
                    events.yield(.action(blockID, action))
                    let label = actionElement.label ?? actionElement.identifier ?? actionElement.role
                    let actionImage = await driver.imageFingerprint(for: actionSnapshot.captureID)
                    var after = try await goalCapture(wallDeadline)
                    var foundAppleSheet: VisualInterruption?
                    var uninspectedVisualChange = false
                    // System sheets can arrive several seconds after XCTest reports a tap. Observe
                    // the live screen before treating an unchanged app tree as a failed action.
                    for observation in 0..<4 where visibleContent(after) == visibleContent(actionSnapshot) {
                        let afterImage = await driver.imageFingerprint(for: after.captureID)
                        if let actionImage, let afterImage, actionImage != afterImage {
                            uninspectedVisualChange = true
                            do {
                                let perception = try await driver.recognizeText(for: after.captureID,
                                    deadline: min(wallDeadline, Date().addingTimeInterval(20)))
                                foundAppleSheet = VisualInterruption.recognize(perception)
                                uninspectedVisualChange = false
                            } catch {
                                events.yield(.diagnostic("Screen-text recognition failed: \(error.localizedDescription)"))
                            }
                        }
                        if foundAppleSheet != nil || observation == 3 { break }
                        try await Task.sleep(for: .seconds(min(1.25, max(0, wallDeadline.timeIntervalSinceNow))))
                        after = try await goalCapture(wallDeadline)
                    }
                    if visibleContent(after) == visibleContent(actionSnapshot) {
                        if uninspectedVisualChange {
                            let reason = "A system screen appeared, but screen-text recognition could not inspect it"
                            events.yield(.diagnostic(reason))
                            return .init(outcome: .needsReview, reason: reason)
                        }
                        if let foundAppleSheet {
                                routeEligible = false
                                replay = nil
                                events.yield(.blockFinished(blockID, .passed, duration: 0, reason: "Apple sign-in sheet opened"))
                                if foundAppleSheet == .appleAccountSignIn {
                                    let sheet = try await goalCapture(wallDeadline)
                                    let sheetText = try await driver.recognizeText(for: sheet.captureID,
                                        deadline: min(wallDeadline, Date().addingTimeInterval(20)))
                                    guard VisualInterruption.recognize(sheetText) == .appleAccountSignIn else {
                                        return .init(outcome: .needsReview, reason: "Apple sign-in sheet changed before password continuation")
                                    }
                                    try await goalTextTap("Sign In with Password", snapshot: sheet,
                                        perception: sheetText, deadline: wallDeadline)
                                    accountSheetUnderlay = visibleContent(actionSnapshot)
                                    accountSheetUnderlayImage = actionImage
                                    continue
                                }
                                // Prefer Apple's private relay address when the goal does not
                                // specify an email disclosure choice. This is a reversible
                                // selection; committing the account remains an explicit step.
                                let sheet = try await goalCapture(wallDeadline)
                                let sheetText = try await driver.recognizeText(for: sheet.captureID,
                                    deadline: min(wallDeadline, Date().addingTimeInterval(20)))
                                guard VisualInterruption.recognize(sheetText) == .appleAccountCreation else {
                                    return .init(outcome: .needsReview, reason: "Apple account sheet changed before the email choice")
                                }
                                try await goalTextTap("Hide My Email", snapshot: sheet,
                                    perception: sheetText, deadline: wallDeadline)
                                let selectedSheet = try await goalCapture(wallDeadline)
                                let selectedText = try await driver.recognizeText(for: selectedSheet.captureID,
                                    deadline: min(wallDeadline, Date().addingTimeInterval(20)))
                                guard VisualInterruption.recognize(selectedText) == .appleAccountCreation,
                                      selectedText.regions.contains(where: {
                                          TargetTextMatching.equals($0.text, "Continue with Password") && $0.confidence >= 0.4
                                      }) else {
                                    return .init(outcome: .needsReview, reason: "Could not verify the Apple account continuation control")
                                }
                                recent.append(label)
                                steps += 1
                                let message = "Approval required: Hide My Email was selected. Continue with Password may create an app account and accept its Terms & Conditions. Choose Continue with Apple to approve this step."
                                events.yield(.blocker(.legalConsentRequired("App account creation and Terms & Conditions")))
                                events.yield(.diagnostic(message))
                                let pausedAt = Date()
                                await control.pause()
                                try await control.boundary(startsBlock: false)
                                wallDeadline = wallDeadline.addingTimeInterval(Date().timeIntervalSince(pausedAt))
                                let approvedSheet = try await goalCapture(wallDeadline)
                                let approvedText = try await driver.recognizeText(for: approvedSheet.captureID,
                                    deadline: min(wallDeadline, Date().addingTimeInterval(20)))
                                guard VisualInterruption.recognize(approvedText) == .appleAccountCreation else {
                                    events.yield(.diagnostic("Apple sheet changed during approval; observing again"))
                                    continue
                                }
                                try await goalTextTap("Continue with Password", snapshot: approvedSheet,
                                    perception: approvedText, deadline: wallDeadline)
                                accountSheetUnderlay = visibleContent(actionSnapshot)
                                accountSheetUnderlayImage = actionImage
                                continue
                        }
                        noProgressAttempts[label, default: 0] += 1
                        routeEligible = false
                        replay = nil
                        if label != "Sign in with Apple" || noProgressAttempts[label, default: 0] >= 2 {
                            unproductiveLabels.insert(label)
                        }
                        lastNoProgressReason = "After tapping \(label), the visible screen did not advance after repeated observation."
                        events.yield(.blockFinished(blockID, .needsReview, duration: 0, reason: lastNoProgressReason))
                    } else {
                        unproductiveLabels.removeAll()
                        noProgressAttempts.removeAll()
                        lastNoProgressReason = nil
                        events.yield(.blockFinished(blockID, .passed, duration: 0, reason: nil))
                        if routeEligible {
                            recordedSteps.append(.init(screen: GoalReplaySafety.screen(in: actionSnapshot,
                                appBundleID: bundleIdentifier), element: actionElement))
                        }
                        if replay != nil { replayIndex += 1 }
                    }
                    recent.append(actionElement.label ?? actionElement.identifier ?? actionElement.role)
                    if recent.count > 8 { recent.removeFirst() }
                    steps += 1
                }
            } catch is CancellationError { return .init(outcome: .cancelled, reason: "Goal navigation was cancelled") }
            catch DriverFailure.missingSecret(let secret) {
                events.yield(.blocker(.missingSecret(secret)))
                return .init(outcome: .needsReview,
                    reason: DriverFailure.missingSecret(secret).localizedDescription)
            }
            catch DriverFailure.credentialAccessRequired(let secret) {
                events.yield(.blocker(.credentialAccessRequired(secret)))
                return .init(outcome: .needsReview,
                    reason: DriverFailure.credentialAccessRequired(secret).localizedDescription)
            }
            catch DriverFailure.secureInputUnavailable(let secret) {
                events.yield(.blocker(.secureInputUnavailable(secret)))
                return .init(outcome: .needsReview,
                    reason: DriverFailure.secureInputUnavailable(secret).localizedDescription)
            }
            catch DriverFailure.secureInputUnverified(let secret) {
                events.yield(.blocker(.secureInputUnverified(secret)))
                return .init(outcome: .needsReview,
                    reason: DriverFailure.secureInputUnverified(secret).localizedDescription)
            }
            catch {
                if let transient = GoalTransientFailure(error) {
                    staleRecaptures += 1
                    applePasswordAttempts.removeAll()
                    unchanged = 0
                    lastSignature = nil
                    switch transient {
                    case .staleCapture:
                        // A stale capture rejects the action before dispatch. Keep
                        // observing until the goal's overall deadline.
                        if Date() < wallDeadline {
                            events.yield(.diagnostic("Capture expired before input; recapturing and retrying (attempt \(staleRecaptures))"))
                            let delay = min(2.0, 0.35 * Double(staleRecaptures))
                            try? await Task.sleep(for: .seconds(delay))
                            continue
                        }
                        let reason = "Goal deadline reached while waiting for a fresh capture"
                        events.yield(.diagnostic(reason))
                        return .init(outcome: .failed, reason: reason)
                    case .unavailableTarget:
                        if staleRecaptures <= 8 && Date() < wallDeadline {
                            events.yield(.diagnostic("Target moved before input; recapturing and retrying (\(staleRecaptures)/8)"))
                            try? await Task.sleep(for: .milliseconds(350))
                            continue
                        }
                        let reason = "Input target could not be found after eight fresh observations"
                        events.yield(.diagnostic(reason))
                        return .init(outcome: .needsReview, reason: reason)
                    }
                }
                let reason = "Goal navigation stopped: \(error.localizedDescription)"
                events.yield(.diagnostic(reason))
                return .init(outcome: Date() >= wallDeadline ? .failed : .needsReview, reason: reason)
            }
        }
        let reason = Date() >= wallDeadline ? "10-minute goal limit reached" : "Goal action limit reached"
        events.yield(.diagnostic(reason))
        return .init(outcome: Date() >= wallDeadline ? .failed : .needsReview, reason: reason)
    }
}
