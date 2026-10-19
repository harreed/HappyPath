import Foundation

/// A single, reviewable UI test proposal derived from a Linear issue.
public struct LinearIssueDraft: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let description: String
    public let url: URL

    public init(identifier: String, title: String, description: String, url: URL) {
        self.identifier = identifier
        self.title = title
        self.description = description
        self.url = url
    }

    public var proposedName: String { "\(identifier): \(title)" }

    public var proposedGoal: String {
        let context = description.components(separatedBy: .newlines).prefix(while: { line in
            !Self.isAcceptanceHeading(line)
        }).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let result = context.isEmpty ? title : "\(title)\n\nTicket context:\n\(context)"
        return String(result.prefix(8000))
    }

    public var proposedSuccessCriteria: String {
        let lines = description.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: Self.isAcceptanceHeading) else { return "" }
        let section = lines.dropFirst(start + 1).prefix(while: { line in
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        })
        return String(section.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(8000))
    }

    private static func isAcceptanceHeading(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            .lowercased()
        return ["acceptance criteria", "success criteria", "expected behavior", "expected behaviour", "definition of done"].contains(value)
    }
}
