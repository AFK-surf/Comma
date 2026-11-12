import Foundation

/// Mode-agnostic helpers ported from legacy `CommandHandler`: a state
/// machine + an operation lane + the optional intervention/exit signals.
/// Each mode runtime embeds one and feeds it parsed requests.
@available(macOS 14.0, *)
@MainActor
public final class ModeController<Executor: PipelineExecutor> {
    public let stateMachine: StateMachine
    public let lane: OperationLane<Executor>
    public let interventionSignal: InterventionPauseSignal
    public let exitSignal: SessionExitSignal

    public init(executor: Executor) {
        stateMachine = StateMachine()
        lane = OperationLane(executor: executor)
        interventionSignal = InterventionPauseSignal()
        exitSignal = SessionExitSignal()
    }

    /// Convenience wrapper: rejects commands that don't pass the state
    /// machine's gate, otherwise runs them through the lane.
    public func execute(
        _ request: Executor.Request
    ) async throws -> Executor.Response {
        if let _ = stateMachine.rejectionReason() {
            // Caller is responsible for converting rejection to its own
            // response shape; we don't have a generic Response constructor.
            throw ModeControllerError.rejected(
                reason: stateMachine.rejectionReason() ?? "rejected"
            )
        }
        return try await lane.execute(request)
    }
}

public enum ModeControllerError: Error, CustomStringConvertible {
    case rejected(reason: String)

    public var description: String {
        switch self {
        case let .rejected(reason):
            reason
        }
    }
}
