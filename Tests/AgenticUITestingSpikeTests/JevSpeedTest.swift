import XCTest
import RunnerCore
import ModelProviders

final class JevSpeedTest: XCTestCase {
    func testJevLatency() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_JEV_SPEED"] == "1" else {
            throw XCTSkip("Opt-in live provider latency probe; set RUN_LIVE_JEV_SPEED=1.")
        }
        let transport = JevHTTPTransport.fromEnvironment()
        guard transport.credentialsAvailable else {
            throw XCTSkip("TYPESAFE_API_KEY not set")
        }

        let candidate = ActionCandidate(
            captureID: CaptureID(),
            title: "Test Action",
            action: .dismiss,
            isSafeForAutomaticExecution: true
        )

        let chooser = JevCandidateChooser(transport: transport)

        let iterations = 5
        var latencies: [TimeInterval] = []
        var successes = 0
        var abstentions = 0
        var errors = 0

        for i in 1...iterations {
            let start = Date()
            do {
                let result = try await chooser.choose(from: [candidate], context: "Speed test iteration \(i)")
                let latency = Date().timeIntervalSince(start)
                latencies.append(latency)
                successes += 1
                print("Iteration \(i): \(String(format: "%.3f", latency))s - selected confidence: \(result.confidence)")
            } catch let refusal as CandidateProviderRefusal {
                let latency = Date().timeIntervalSince(start)
                latencies.append(latency)
                if refusal.evidence.selectedID == "abstain" || !refusal.evidence.accepted {
                    abstentions += 1
                    print("Iteration \(i): \(String(format: "%.3f", latency))s - abstained: \(refusal.evidence.reason)")
                } else {
                    errors += 1
                    print("Iteration \(i): \(String(format: "%.3f", latency))s - refused: \(refusal.evidence.reason)")
                }
            } catch {
                let latency = Date().timeIntervalSince(start)
                latencies.append(latency)
                errors += 1
                print("Iteration \(i): \(String(format: "%.3f", latency))s - error: \(error)")
            }
        }

        let sorted = latencies.sorted()
        let avg = latencies.reduce(0, +) / Double(latencies.count)
        let median = sorted[sorted.count / 2]
        let min = sorted.first!
        let max = sorted.last!

        print("\n=== Jev Latency Results (\(iterations) iterations) ===")
        print("Successful: \(successes), Abstained: \(abstentions), Errors: \(errors)")
        print("Min:  \(String(format: "%.3f", min))s")
        print("Max:  \(String(format: "%.3f", max))s")
        print("Median: \(String(format: "%.3f", median))s")
        print("Avg:  \(String(format: "%.3f", avg))s")
    }
}
