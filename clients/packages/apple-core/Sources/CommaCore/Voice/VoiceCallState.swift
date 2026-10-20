import Foundation

/// Connected is a transport state; expanded or minimized presentation belongs to the UI.
public enum VoiceCallPhase: String, Sendable, Equatable {
    case idle, preparing, calling, connected, ending, ended, failed

    /// The call holds, or is acquiring, a transport.
    public var isLive: Bool { [.preparing, .calling, .connected, .ending].contains(self) }
}

public struct VoiceCallState: Sendable, Equatable {
    /// Advances on every start and credential retry, so a callback from an older attempt is ignored.
    public var generation: Int = 0
    public var phase: VoiceCallPhase = .idle
    public var maxDurationSeconds: Int?
    public var startedByServer = false
    public var receivedAudio = false
    public var result: VoiceCallResult?
    public init() {}
}

public enum VoiceCallSignal: Sendable {
    case begin(Int)
    case retryCredentials(Int)
    case ready(Int)
    case started(Int, maxDurationSeconds: Int)
    case audio(Int)
    case hangUp(Int)
    case finished(Int, VoiceCallResult)
    case dismissFailure(Int)

    var generation: Int {
        switch self {
        case .begin(let g), .retryCredentials(let g), .ready(let g), .started(let g, _), .audio(let g), .hangUp(let g),
             .finished(let g, _), .dismissFailure(let g): g
        }
    }
}

public enum VoiceCallReducer {
    public static func reduce(_ state: VoiceCallState, _ signal: VoiceCallSignal) -> VoiceCallState {
        switch signal {
        case .begin(let generation):
            guard generation > state.generation, restartable.contains(state.phase) else { return state }
            return fresh(generation)
        case .retryCredentials(let generation):
            guard generation > state.generation, live.contains(state.phase) else { return state }
            return fresh(generation)
        default: break
        }
        guard signal.generation == state.generation else { return state }
        var next = state
        switch signal {
        case .ready:
            if state.phase == .preparing { next.phase = .calling }
        case .started(_, let limit):
            guard state.phase == .calling else { return state }
            next.startedByServer = true
            next.maxDurationSeconds = limit
            return connected(next)
        case .audio:
            guard state.phase == .calling else { return state }
            next.receivedAudio = true
            return connected(next)
        case .hangUp:
            if live.contains(state.phase) { next.phase = .ending }
        case .finished(_, let result):
            guard live.contains(state.phase) || state.phase == .ending else { return state }
            next.phase = result == .ended ? .ended : .failed
            next.result = result
        case .dismissFailure:
            if state.phase == .failed { next.phase = .ended }
        case .begin, .retryCredentials: break
        }
        return next
    }

    /// Both the server's `session.started` and its first audio are required: the agent is then audible.
    private static func connected(_ state: VoiceCallState) -> VoiceCallState {
        var next = state
        if state.startedByServer && state.receivedAudio { next.phase = .connected }
        return next
    }

    private static func fresh(_ generation: Int) -> VoiceCallState {
        var state = VoiceCallState()
        state.generation = generation
        state.phase = .preparing
        return state
    }

    private static let live: Set<VoiceCallPhase> = [.preparing, .calling, .connected]
    private static let restartable: Set<VoiceCallPhase> = [.idle, .ended, .failed]
}
