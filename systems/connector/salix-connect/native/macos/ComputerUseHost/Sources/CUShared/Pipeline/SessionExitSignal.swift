import Foundation

/// Thread-safe latch used by session runtimes to surface "user wants out"
/// across the async pipeline. Consumers call `consumeExitRequest()` from
/// the dispatch loop and tear down on `true`.
public final class SessionExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    public init() {}

    public func requestExit() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    public func consumeExitRequest() -> Bool {
        lock.lock()
        let wasRequested = requested
        requested = false
        lock.unlock()
        return wasRequested
    }
}
