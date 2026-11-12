import CoreGraphics
import Foundation

public enum SessionState: String, Sendable {
    case idle
    case active
    case paused
}

public enum InterventionType: String, Sendable {
    case mouse
    case keyboard
}

public struct PausedCursorLocation: Sendable {
    public let display: Int
    public let x: Int
    public let y: Int

    public init(display: Int, x: Int, y: Int) {
        self.display = display
        self.x = x
        self.y = y
    }
}

public struct PausedInterventionContext: Sendable {
    public let type: InterventionType
    public let cursor: PausedCursorLocation
    public let screenPoint: CGPoint

    public init(type: InterventionType, cursor: PausedCursorLocation, screenPoint: CGPoint) {
        self.type = type
        self.cursor = cursor
        self.screenPoint = screenPoint
    }
}

/// Tri-state FSM ported from legacy ComputerUse. Background mode only ever
/// uses `.idle` and `.active`; the `.paused` branch is meaningful only when
/// the foreground intervention detector is wired up.
public final class StateMachine {
    public private(set) var state: SessionState = .idle
    public private(set) var pausedIntervention: PausedInterventionContext?

    /// True after recovery from intervention, until the agent has been notified.
    /// The first post-recovery command consumes this flag to deliver the notice.
    public private(set) var pendingInterventionNotice: Bool = false

    public init() {}

    public var isActive: Bool {
        state == .active
    }

    public var isPaused: Bool {
        state == .paused
    }

    public var isIdle: Bool {
        state == .idle
    }

    public var interventionType: InterventionType? {
        pausedIntervention?.type
    }

    public func transitionToActive() {
        let wasPaused = (state == .paused)
        state = .active
        pausedIntervention = nil
        if wasPaused {
            pendingInterventionNotice = true
        }
    }

    public func transitionToPaused(_ context: PausedInterventionContext) {
        state = .paused
        pausedIntervention = context
    }

    public func transitionToIdle() {
        state = .idle
        pausedIntervention = nil
        pendingInterventionNotice = false
    }

    /// Consume the pending notice flag. Returns true if there was a notice to deliver.
    public func consumeInterventionNotice() -> Bool {
        if pendingInterventionNotice {
            pendingInterventionNotice = false
            return true
        }
        return false
    }

    /// Reason a command is rejected before reaching the executor, or `nil`
    /// if the command may proceed. Mode controllers map this to whatever
    /// response shape they expose.
    public func rejectionReason() -> String? {
        switch state {
        case .idle:
            "no active session; run `start --mode <…>` first"
        case .active, .paused:
            // Paused commands are handled by blocking logic in mode runtimes,
            // not rejected here.
            nil
        }
    }
}
