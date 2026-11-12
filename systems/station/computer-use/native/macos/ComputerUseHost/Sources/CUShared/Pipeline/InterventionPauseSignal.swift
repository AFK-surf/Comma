import Foundation

/// Thread-safe pause flag the foreground intervention detector toggles to
/// interrupt mid-flight animations. Background mode does not use this.
public final class InterventionPauseSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    public init() {}

    public func pause() {
        lock.lock()
        paused = true
        lock.unlock()
    }

    public func resume() {
        lock.lock()
        paused = false
        lock.unlock()
    }

    public var isPaused: Bool {
        lock.lock()
        let current = paused
        lock.unlock()
        return current
    }
}
