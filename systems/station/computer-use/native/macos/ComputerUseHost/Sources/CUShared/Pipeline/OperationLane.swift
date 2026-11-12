import Foundation

/// Mode-specific executor that runs one parsed request to completion. Each
/// mode owns its own request/response shape; the pipeline only needs to
/// serialize calls.
public protocol PipelineExecutor: Sendable {
    associatedtype Request: Sendable
    associatedtype Response: Sendable

    func execute(_ request: Request) async throws -> Response
}

/// Actor wrapper that serializes execution of a `PipelineExecutor`. Modeled
/// after legacy `CommandOperationLane` but generic over request/response.
@available(macOS 14.0, *)
public actor OperationLane<Executor: PipelineExecutor> {
    private let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func execute(_ request: Executor.Request) async throws -> Executor.Response {
        try await executor.execute(request)
    }
}
