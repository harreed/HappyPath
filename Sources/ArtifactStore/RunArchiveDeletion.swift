import Foundation

public struct RunArchiveDeletionResult: Sendable {
    public let deleted: [URL]
    public let failures: [String]
}

public enum RunArchiveDeletion {
    /// Removes whole run directories, including recordings and other evidence.
    /// Only immediate children of this project's runs directory are accepted.
    public static func delete(_ directories: [URL], projectURL: URL) -> RunArchiveDeletionResult {
        let runs = projectURL.appendingPathComponent("runs").standardizedFileURL
        var deleted: [URL] = []
        var failures: [String] = []
        for directory in Set(directories) {
            let candidate = directory.standardizedFileURL
            guard candidate.deletingLastPathComponent() == runs,
                  candidate != runs else {
                failures.append("\(directory.lastPathComponent): outside this project's runs folder")
                continue
            }
            do {
                try FileManager.default.removeItem(at: candidate)
                deleted.append(directory)
            } catch {
                failures.append("\(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return RunArchiveDeletionResult(deleted: deleted, failures: failures)
    }
}
