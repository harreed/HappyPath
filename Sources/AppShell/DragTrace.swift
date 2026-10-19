import Foundation

/// Opt-in debug drag diagnostics; records identities, never test text.
enum DragTrace {
    private static let lock = NSLock()
    static func record(_ phase: String, _ fields: [String: String] = [:]) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["HAPPYPATH_DRAG_TRACE"] == "1" || environment["TEST_WORKBENCH_DRAG_TRACE"] == "1" else { return }
        lock.lock(); defer { lock.unlock() }
        var entry = fields
        entry["phase"] = phase; entry["date"] = ISO8601DateFormatter().string(from: Date())
        entry["epochSeconds"] = String(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HappyPath-drag.jsonl")
        do {
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]); data.append(10)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } catch { NSLog("Drag trace unavailable: %@", error.localizedDescription) }
        #endif
    }
}
