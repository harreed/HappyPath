import Foundation
import ModelProviders

enum PlanningDiagnostics {
    static func store(prompt: String, failure: Error, bundleURL: URL?) throws -> URL {
        let root: URL
        if let bundleURL { root = bundleURL.appendingPathComponent("planning-diagnostics") }
        else { root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("HappyPath/PlanningDiagnostics") }
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try prompt.write(to: directory.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
        if let failure = failure as? PlanGenerationFailure {
            try failure.rawJSON.write(to: directory.appendingPathComponent("raw-response.json"), atomically: true, encoding: .utf8)
        }
        try failure.localizedDescription.write(to: directory.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
        return directory
    }
}
