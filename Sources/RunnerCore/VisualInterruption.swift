import Foundation

/// Identifies system-owned UI that is visible in the screenshot but absent
/// from the target application's accessibility tree.
public enum VisualInterruption: Equatable {
    case appleAccountCreation
    case appleAccountSignIn

    public static func applePasswordAccount(_ perception: TextPerception) -> String? {
        let visible = perception.regions.filter { $0.confidence >= 0.4 }
            .map(\.text).joined(separator: " ")
        let normalized = TargetTextMatching.normalize(visible)
        guard normalized.contains("apple account"),
              normalized.contains("password"),
              normalized.contains("sign in") || normalized.contains("enter the password") else { return nil }
        guard let pattern = try? NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive),
              let range = pattern.firstMatch(in: visible, range: NSRange(visible.startIndex..., in: visible))?.range,
              let swiftRange = Range(range, in: visible) else { return nil }
        return String(visible[swiftRange]).lowercased()
    }

    public static func recognize(_ perception: TextPerception) -> Self? {
        let text = perception.regions
            .filter { $0.confidence >= 0.4 }
            .map { TargetTextMatching.normalize($0.text) }
            .joined(separator: " ")
        if text.contains("sign in with apple"),
           text.contains("create an account for"),
           text.contains("share my email"),
           text.contains("hide my email") { return .appleAccountCreation }
        if text.contains("sign in with apple"),
           text.contains("using your apple account"),
           text.contains("sign in with password") { return .appleAccountSignIn }
        return nil
    }
}
