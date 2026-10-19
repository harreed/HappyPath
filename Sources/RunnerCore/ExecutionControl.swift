import Foundation

/// Wall-clock deadlines are translated by accumulated safe-boundary pauses.
final class ExecutionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var excluded: TimeInterval = 0
    func virtualNow() -> Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(-excluded) }
    func actual(_ deadline: Date) -> Date { lock.lock(); defer { lock.unlock() }; return deadline.addingTimeInterval(excluded) }
    func exclude(_ seconds: TimeInterval) { lock.lock(); excluded += seconds; lock.unlock() }
}

public actor ExecutionControl {
    private var pauseRequested = false
    private var stopped = false
    private var stepAllowance = 0
    private var attestationPending = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let clock: ExecutionClock
    private let events: AsyncStream<ExecutionEvent>.Continuation
    init(clock: ExecutionClock, events: AsyncStream<ExecutionEvent>.Continuation) { self.clock = clock; self.events = events }
    public func pause() { pauseRequested = true }
    public func resume() { guard !attestationPending else { return }; pauseRequested = false; stepAllowance = 0; waiter?.resume(); waiter = nil }
    public func step() { guard !attestationPending else { return }; pauseRequested = true; stepAllowance = 1; waiter?.resume(); waiter = nil }
    public func requireHumanAttestation() { attestationPending = true; pauseRequested = true; stepAllowance = 0 }
    public func approveHumanAttestation() {
        guard attestationPending else { return }
        attestationPending = false
        resume()
    }
    func stop() { stopped = true; waiter?.resume(); waiter = nil }
    func boundary(breakpoint: Bool = false, startsBlock: Bool = true) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        if stepAllowance > 0 { if startsBlock { stepAllowance -= 1 }; return }
        if pauseRequested || breakpoint {
            pauseRequested = true
            let began = Date()
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    waiter = $0
                    events.yield(.state(.paused))
                }
            } onCancel: { Task { await self.stop() } }
            clock.exclude(Date().timeIntervalSince(began))
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            if startsBlock && stepAllowance > 0 { stepAllowance -= 1 }
            events.yield(.state(.running))
        }
    }
}

public struct RecordingAnchor: Codable, Sendable {
    public let processStartedAt: Date
    public let markerObservedAt: Date
    public init(processStartedAt: Date, markerObservedAt: Date) {
        self.processStartedAt = processStartedAt; self.markerObservedAt = markerObservedAt
    }
}
