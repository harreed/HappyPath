import Foundation

public protocol CandidateActionExecuting: Sendable {
    func execute(_ action: CandidateAction) async throws
}

public struct BoundedRecoveryCoordinator<Chooser: CandidateChoosing, Executor: CandidateActionExecuting>: Sendable {
    private let chooser: Chooser
    private let executor: Executor
    private let gate: CaptureActionGate
    private let minimumConfidence: Double

    public init(
        chooser: Chooser,
        executor: Executor,
        gate: CaptureActionGate = CaptureActionGate(),
        minimumConfidence: Double = 0.8
    ) {
        precondition((0...1).contains(minimumConfidence))
        self.chooser = chooser
        self.executor = executor
        self.gate = gate
        self.minimumConfidence = minimumConfidence
    }

    @discardableResult
    public func recover(
        capture: ScreenCapture,
        candidates: [ActionCandidate],
        context: String
    ) async throws -> ActionCandidate {
        try await gate.activate(capture.id)
        let choice = try await chooser.choose(from: candidates, context: context)
        let selected = try await gate.validateAndConsume(
            choice: choice,
            candidates: candidates,
            minimumConfidence: minimumConfidence
        )
        try await executor.execute(selected.action)
        return selected
    }
}
