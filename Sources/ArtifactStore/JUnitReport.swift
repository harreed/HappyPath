import Foundation
import ProjectDomain
import RunnerCore

/// A small CI projection of a completed run. Raw events and diagnostics stay in the archive.
public enum JUnitReport {
    public static func write(in directory: URL, report: ExecutionReport) throws {
        let project = try ProjectBundleStore().load(from: directory)
        let selection = try JSONDecoder().decode(RunSelection.self,
            from: Data(contentsOf: directory.appendingPathComponent("selection.json")))
        let review = try ExecutionReview(project: project, selection: selection,
            events: ExecutionArtifactStore.readEvents(in: directory))
        let durations = Dictionary(uniqueKeysWithValues: review.tests.compactMap { test in
            test.duration.map { (test.id, $0) }
        })
        try write(in: directory, project: project, selection: selection, report: report, durationsByTest: durations)
    }

    /// Also supports acceptance runners whose archives predate the current event format.
    public static func write(in directory: URL, project: TestProject, selection: RunSelection,
                             report: ExecutionReport, durationsByTest: [UUID: TimeInterval] = [:]) throws {
        let selected = try project.selectedTests(selection)
        var results: [UUID: RunOutcome] = [:]
        for result in report.tests { results[result.testID] = result.outcome }
        var cases: [(name: String, suite: String, duration: TimeInterval, outcome: RunOutcome?)] = selected.map { item in
            let category = project.categories.first { $0.id == item.categoryID }?.name ?? "Category"
            return (item.test.name, "\(category) / \(item.suite.name)",
                durationsByTest[item.test.id] ?? 0, results[item.test.id])
        }
        // A failed preparation can have no test results. Never produce a green, empty suite.
        if cases.isEmpty || (report.outcome != .passed && cases.allSatisfy { $0.outcome == .passed }) {
            cases.append(("Run completion", "Run", 0, report.outcome))
        }
        let failures = cases.filter { $0.outcome != .passed }.count
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<testsuite name=\"Run\" tests=\"\(cases.count)\" failures=\"\(failures)\" errors=\"0\" skipped=\"0\">\n"
        for item in cases {
            xml += "  <testcase classname=\"\(escape(item.suite))\" name=\"\(escape(item.name))\" time=\"\(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, item.duration)))\">"
            if item.outcome != .passed {
                let status = item.outcome?.rawValue ?? "incomplete"
                xml += "<failure type=\"\(escape(status))\" message=\"Test \(escape(status))\"/>"
            }
            xml += "</testcase>\n"
        }
        xml += "</testsuite>\n"
        try Data(xml.utf8).write(to: directory.appendingPathComponent("junit.xml"), options: .atomic)
    }

    private static func escape(_ value: String) -> String {
        let legal = value.unicodeScalars.filter { scalar in
            scalar.value == 0x9 || scalar.value == 0xA || scalar.value == 0xD ||
            (0x20...0xD7FF).contains(scalar.value) ||
            (0xE000...0xFFFD).contains(scalar.value) ||
            (0x10000...0x10FFFF).contains(scalar.value)
        }
        return String(String.UnicodeScalarView(legal))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
