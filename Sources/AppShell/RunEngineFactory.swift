import Foundation
import ModelProviders
import PerceptionCore
import ProjectDomain
import RunnerCore
import SimulatorControl

/// Builds the production runner and its service adapters for a single run.
enum RunEngineFactory {
    static func make(base: URL, artifacts: URL, savedInputs: [GoalSavedInput],
                     imageDisclosureChoice: ImageDisclosureChoice) -> ExecutionEngine {
        let jevKey = JevCredentialStore.apiKey ?? ""
        let jev = JevVisionProvider(apiKey: jevKey)
        let imageAssessor: any ImageAssessing = ScreenshotProvider.selected == .jev ? jev : ClefVisionProvider()
        let fallbackImageAssessor: any ImageAssessing = ScreenshotProvider.selected == .jev ? ClefVisionProvider() : jev
        return ExecutionEngine(
            driver: XCTestRunnerDriver(baseDirectory: base, artifacts: artifacts),
            assertionEvaluator: AppleAssertionEvaluator(),
            failureSummariser: AppleFailureSummariser(),
            candidateChooser: JevCandidateChooser(transport: JevHTTPTransport.fromEnvironment()),
            goalNavigator: jev,
            visualComparator: LocalPixelComparator(),
            imageAssessor: imageAssessor,
            fallbackImageAssessor: fallbackImageAssessor,
            primaryImageMinimumConfidence: 0.4,
            imageDisclosureChoice: imageDisclosureChoice,
            savedInputs: savedInputs,
            screenVisionEnabled: !jevKey.isEmpty
        )
    }
}
