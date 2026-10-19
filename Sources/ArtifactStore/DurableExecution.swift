import Foundation
import RunnerCore

public protocol ExecutionPersisting: Sendable {
    func persist(_ event: ExecutionEvent) async throws -> ExecutionEnvelope
    func finish(_ report: ExecutionReport) async throws
    func closeAfterFailure() async
}

extension ExecutionArtifactStore: ExecutionPersisting {
    public func persist(_ event: ExecutionEvent) throws -> ExecutionEnvelope { try append(event) }
}

/// The single production persistence boundary: never present an event before its
/// write succeeds, and never return a write failure before the driver has stopped.
public enum DurableExecution {
    public static func consume(
        _ handle: ExecutionHandle,
        persistence: any ExecutionPersisting,
        onEvent: @Sendable (ExecutionEnvelope) async -> Void
    ) async throws -> ExecutionReport {
        try await withTaskCancellationHandler {
            do {
                for await event in handle.events {
                    let durable = try await persistence.persist(event)
                    await onEvent(durable)
                }
                try Task.checkCancellation()
                let report = await handle.task.value
                try Task.checkCancellation()
                try await persistence.finish(report)
                return report
            } catch {
                handle.cancel()
                _ = await handle.task.value
                await persistence.closeAfterFailure()
                throw error
            }
        } onCancel: { handle.cancel() }
    }
}
