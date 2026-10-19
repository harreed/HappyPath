import Foundation

/// Tolerant target text comparison.
///
/// Goal: users can type `sign in with apple`, `Sign In With Apple`, or vague
/// `apple` and still resolve the same node, while never tapping the wrong one.
/// Safety comes from uniqueness, not string strictness: every tier still
/// requires exactly one match before an action is authorized.
public enum TargetTextMatching {
    /// Lowercase, diacritic-insensitive, trimmed, internal whitespace collapsed.
    /// `Sign  in with Apple` and `sign in with apple` normalize identically.
    /// `&` is expanded to `and` so `Terms & Conditions` matches `terms and conditions`.
    public static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let expanded = folded.replacingOccurrences(of: "&", with: " and ")
        return expanded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Normalized equality. Handles optionals: nil element never equals a query.
    public static func equals(_ element: String?, _ query: String) -> Bool {
        guard let element else { return false }
        return normalize(element) == normalize(query)
    }

    public static func equals(_ lhs: String, _ rhs: String) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    /// Vague substring: element contains the query after normalization.
    /// Single characters are excluded to avoid `a` matching everything;
    /// empty queries only match empty elements (exact tier handles that).
    public static func contains(_ element: String?, _ query: String) -> Bool {
        guard let element else { return false }
        let needle = normalize(query)
        guard needle.count >= 2 else { return normalize(element) == needle }
        return normalize(element).contains(needle)
    }

    /// Either direction: the element contains the query (`apple` finds
    /// `Sign in with Apple`) or the query contains the element (user
    /// over-specified, e.g. identifier guess `Sign In With Apple Button`
    /// for label `Sign in with Apple`). Guards exclude empty/short sides
    /// so single characters never match the world.
    public static func containsEither(_ element: String?, _ query: String) -> Bool {
        if contains(element, query) { return true }
        guard let element else { return false }
        let hay = normalize(query), needle = normalize(element)
        guard needle.count >= 2, hay.count > needle.count else { return false }
        return hay.contains(needle)
    }

    /// Optional target field: nil means wildcard (match anything).
    public static func fieldEquals(_ element: String?, _ target: String?) -> Bool {
        guard let target else { return true }
        guard let element else { return false }
        return equals(element, target)
    }

    public static func fieldContains(_ element: String?, _ target: String?) -> Bool {
        guard let target else { return true }
        guard let element else { return false }
        return containsEither(element, target)
    }

    /// Dismissal affordances. Plans and model-written steps often say
    /// `close button` for the control an app exposes as `Back` (or `xmark`,
    /// `chevron.backward`). These words form one family, matched only as a
    /// last-resort tier whose uniqueness requirement still gates any action.
    public static let dismissalWords: Set<String> = ["back", "backward", "backwards", "cancel", "close", "dismiss", "later", "no", "not", "now", "thanks", "x", "xmark"]
    private static let fillerWords: Set<String> = ["a", "an", "arrow", "bar", "btn", "button", "chevron", "click", "control", "go", "icon", "item", "nav", "navigation", "press", "tap", "the"]

    /// Unambiguous forward navigation. A control qualifies only when every
    /// meaningful word is progress vocabulary, so `Continue with Password`
    /// qualifies while `Continue to payment` is rejected by the risk list.
    public static let progressWords: Set<String> = ["begin", "continue", "done", "enter", "finish", "get", "got", "in", "log", "next", "ok", "okay", "proceed", "sign", "skip", "start", "started"]
    /// Irreversible, consenting or monetary vocabulary. A control or screen
    /// that names any of these is never advanced automatically.
    public static let irreversibleWords: Set<String> = ["allow", "billing", "block", "buy", "checkout", "confirm", "deactivate", "decline", "delete", "deny", "disable", "donate", "erase", "grant", "logout", "order", "out", "pay", "payment", "post", "publish", "purchase", "reject", "remove", "report", "reset", "revoke", "send", "subscribe", "transfer", "trial", "unsubscribe", "upgrade"]

    /// Splits camelCase and separators so `BackButton`, `Close button` and
    /// `chevron.backward` expose their meaningful words.
    public static func words(_ value: String) -> [String] {
        var spaced = ""
        var previous: Character?
        for character in value {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        return normalize(spaced).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// True when the phrase (ignoring filler nouns and verbs) names exactly a
    /// dismissal affordance: `close button`, `Back`, `go back`, `xmark`.
    public static func dismissalAffordance(_ value: String?) -> Bool {
        guard let value else { return false }
        let meaningful = words(value).filter { !fillerWords.contains($0) }
        guard !meaningful.isEmpty else { return false }
        return meaningful.allSatisfy { dismissalWords.contains($0) }
    }

    /// True when the phrase names one unambiguous forward step: `Next`,
    /// `Continue with Password`, `Get Started`, `Done`. At least one progress
    /// word is required and no irreversible/consent/monetary word may appear.
    public static func progressAffordance(_ value: String?) -> Bool {
        guard let value else { return false }
        let meaningful = words(value).filter { !fillerWords.contains($0) }
        guard !meaningful.isEmpty, meaningful.contains(where: { containsForm($0, progressWords) }) else { return false }
        return !meaningful.contains { containsForm($0, irreversibleWords) }
    }

    /// Screen-level refusal: any visible irreversible, consent or monetary
    /// vocabulary disables automatic progress escapes for the whole screen.
    public static func irreversibleIntent(_ elements: [UIElement]) -> Bool {
        for element in elements {
            for field in [element.label, element.value, element.containingAlertContext] {
                guard let field else { continue }
                if words(field).contains(where: { containsForm($0, irreversibleWords) }) { return true }
                if monetary(field) { return true }
            }
        }
        return false
    }

    /// Tolerates simple plural forms so `deletes`/`payments` still match.
    private static func containsForm(_ word: String, _ vocabulary: Set<String>) -> Bool {
        if vocabulary.contains(word) { return true }
        guard word.hasSuffix("s") else { return false }
        return vocabulary.contains(String(word.dropLast()))
    }

    private static func monetary(_ value: String) -> Bool {
        let normalized = normalize(value)
        for symbol in ["$", "£", "€", "¥"] {
            guard let range = normalized.range(of: symbol) else { continue }
            if normalized[range.upperBound...].first(where: { !$0.isWhitespace })?.isNumber == true { return true }
        }
        return ["/mo", "/month", "/year", "/yr", "per month", "per year"].contains { normalized.contains($0) }
    }
}
