import Foundation

/// Ordered, nonblocking playback of the agent's audio. Calls come from the session's queue, one at a time.
public protocol VoicePlaybackSink: AnyObject, Sendable {
    /// 24 kHz mono PCM16 little-endian. Throws when playback cannot take it.
    func play(_ pcm: Data) throws
    /// Calls `onPlayed`, from any thread, once all audio queued before this mark has been heard.
    /// Marks discarded by `clear()` may never be called back.
    func mark(_ onPlayed: @escaping @Sendable () -> Void) throws
    /// Discards queued audio now.
    func clear()
}

/// When the session's timers fire: the uplink pacer and the hang-up grace. Tests drive a manual one.
public protocol VoiceScheduler: Sendable {
    /// Monotonic nanoseconds.
    var now: UInt64 { get }
    /// Runs `work` on `queue` once `now` reaches `deadline`.
    func schedule(at deadline: UInt64, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void)
}

public struct DispatchVoiceScheduler: VoiceScheduler {
    public init() {}
    public var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    public func schedule(at deadline: UInt64, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: work)
    }
}

/// Counters for local diagnostics; they hold no audio, text or identifiers.
public struct VoiceSessionStats: Sendable, Equatable {
    public var sentFrames = 0
    /// Frames skipped while the socket was backed up.
    public var stalledFrames = 0
    /// Microphone frames dropped because the uplink queue was full.
    public var droppedMicrophoneFrames = 0
    public var receivedMarks = 0
    public var acknowledgedMarks = 0
}

/// Owns one call's protocol: credentials, readiness, the socket, uplink pacing and playback receipts.
/// It has no microphone, speaker or UI. Every mutable field is confined to `queue`.
public final class VoiceSession: @unchecked Sendable {
    /// The uplink queue holds 100 ms; the microphone may not run further ahead of the pacer.
    static let uplinkFrames = 5
    /// While the socket holds more than this, frames are skipped rather than queued: the server tolerates
    /// a stall but limits the catch-up burst.
    static let maxQueuedUplinkBytes = 48_000
    static let hangUpGrace: UInt64 = 2_000_000_000

    public let queue: DispatchQueue
    /// Called on `queue` after every state change.
    public var onState: (@Sendable (VoiceCallState) -> Void)?
    /// Why a call ended or failed, as a fixed phrase with numbers only (codes, statuses, a known end reason):
    /// never text, identifiers, URLs or credentials. Called on `queue`, for local diagnostics.
    public var onDiagnostic: (@Sendable (String) -> Void)?
    /// Ephemeral transcript events, called on `queue`; never stored or logged.
    public var onTranscript: (@Sendable (_ role: String, _ text: String, _ final: Bool) -> Void)?

    private let credentials: any VoiceCredentialSource
    private let transport: any VoiceTransport
    private let sink: any VoicePlaybackSink
    private let scheduler: any VoiceScheduler
    private let startMessage: String
    private var current = VoiceCallState()
    private var socket: (any VoiceSocket)?
    private var preparing: Task<Void, Never>?
    private var opened = false
    private var muted = false
    private var retried = false
    private var disposed = false
    private var uplink: [Data] = []
    private var marks: [(id: Int, name: String)] = []
    private var nextMark = 0
    private var counters = VoiceSessionStats()
    private let silence = Data(count: VoiceProtocol.frameBytes)

    public init(credentials: any VoiceCredentialSource, transport: any VoiceTransport = URLSessionVoiceTransport(),
                sink: any VoicePlaybackSink, version: String, displayName: String? = nil,
                queue: DispatchQueue = DispatchQueue(label: "surf.comma.voice.session", qos: .userInitiated),
                scheduler: any VoiceScheduler = DispatchVoiceScheduler()) throws {
        self.credentials = credentials; self.transport = transport; self.sink = sink; self.queue = queue
        self.scheduler = scheduler
        startMessage = try VoiceProtocol.start(version: version, displayName: displayName)
    }

    /// For tests and diagnostics; never call from `queue`.
    public func snapshot() -> (state: VoiceCallState, stats: VoiceSessionStats) { queue.sync { (current, counters) } }

    /// Microphone permission must already be granted. A start during a call is ignored.
    public func start() {
        queue.async { [self] in
            guard !disposed else { return }
            let next = VoiceCallReducer.reduce(current, .begin(current.generation + 1))
            guard next != current else { return }
            cleanup()
            retried = false; muted = false
            counters = VoiceSessionStats()
            publish(next)
            prepare(next.generation, invalidate: false)
        }
    }

    /// One 20 ms frame from the microphone. Dropped while muted, before the socket opens, or when the queue is full.
    public func offerAudio(_ pcm: Data) {
        queue.async { [self] in
            guard pcm.count == VoiceProtocol.frameBytes, !muted, opened,
                  current.phase == .calling || current.phase == .connected else { return }
            guard uplink.count < Self.uplinkFrames else { counters.droppedMicrophoneFrames += 1; return }
            uplink.append(pcm)
        }
    }

    /// Muted calls send paced silence: the server ends a call that sends no audio.
    public func setMuted(_ value: Bool) {
        queue.async { [self] in
            muted = value
            if value { uplink.removeAll() }
        }
    }

    public func hangUp() {
        queue.async { [self] in
            let generation = current.generation
            transition(.hangUp(generation))
            guard current.phase == .ending else { return }
            preparing?.cancel(); preparing = nil
            uplink.removeAll()
            guard opened, let socket else { finish(generation, .ended); return }
            guard socket.send(text: VoiceProtocol.end) else { finish(generation, .ended); return }
            scheduler.schedule(at: scheduler.now + Self.hangUpGrace, on: queue) { [self] in
                if isCurrent(generation, socket), current.phase == .ending { finish(generation, .ended, forceClose: true) }
            }
        }
    }

    public func dismissFailure() { queue.async { [self] in transition(.dismissFailure(current.generation)) } }

    /// Immediate teardown when the owner goes away; use `hangUp()` for a normal end.
    public func close() {
        queue.async { [self] in
            transition(.finished(current.generation, .ended))
            disposed = true
            cleanup()
        }
    }

    // MARK: Connection

    private func prepare(_ generation: Int, invalidate: Bool) {
        let credentials = self.credentials, transport = self.transport
        preparing = Task { [weak self] in
            var stage = "credentials"
            do {
                if invalidate { await credentials.invalidate() }
                let endpoint = try await credentials.endpoint()
                stage = "readiness"
                try await transport.readiness(endpoint)
                try Task.checkCancellation()
                guard let session = self else { return }
                session.queue.async { session.connect(generation, endpoint) }
            } catch is CancellationError {
            } catch {
                let failure = error as? VoiceFailure
                let result = failure?.result ?? .interrupted
                let code = failure?.networkCode ?? (error as? URLError)?.code.rawValue
                let diagnostic = "prepare_failed stage=\(stage) result=\(result.rawValue) network=\(code.map(String.init) ?? "none")"
                self?.queue.async { [weak self] in
                    guard let self, self.isCurrent(generation) else { return }
                    self.failed(generation, result, diagnostic)
                }
            }
        }
    }

    private func connect(_ generation: Int, _ endpoint: VoiceEndpoint) {
        guard isCurrent(generation), current.phase == .preparing else { return }
        preparing = nil
        transition(.ready(generation))
        // Assigned before any event can arrive: events hop onto this queue behind this block.
        let holder = SocketHolder()
        let socket = transport.connect(endpoint) { [weak self] event in
            self?.queue.async { [weak self] in
                guard let self, let socket = holder.socket else { return }
                self.handle(event, generation, socket)
            }
        }
        holder.socket = socket
        self.socket = socket
    }

    private func handle(_ event: VoiceSocketEvent, _ generation: Int, _ socket: any VoiceSocket) {
        guard isCurrent(generation, socket) else { return }
        switch event {
        case .opened(let subprotocol):
            guard subprotocol == VoiceProtocol.subprotocol else { failed(generation, .interrupted, "subprotocol_rejected"); return }
            // The first frame; no audio can precede it.
            guard socket.send(text: startMessage) else { failed(generation, .interrupted, "start_send_failed"); return }
            opened = true
            pace(generation, socket, due: scheduler.now + VoiceProtocol.frameNanoseconds)
        case .binary(let data):
            guard VoiceProtocol.validAudio(data.count) else { failed(generation, .interrupted, "invalid_downlink bytes=\(data.count)"); return }
            guard !data.isEmpty else { return }
            do { try sink.play(data) } catch { failed(generation, .interrupted, "playback_rejected"); return }
            transition(.audio(generation))
        case .text(let text):
            receive(text, generation, socket)
        case .closed(let code, let reason):
            failed(generation, VoiceProtocol.closeResult(code: code, reason: reason),
                   "socket_closed code=\(code.map(String.init) ?? "none") reason=\(VoiceProtocol.diagnosticReason(reason))")
        case .failed(let status, let error, let stage):
            failed(generation, status.map { VoiceProtocol.result(code: $0) } ?? .interrupted,
                   "\(stage?.rawValue ?? "socket")_failed status=\(status.map(String.init) ?? "none") error=\(error.map(String.init) ?? "none")")
        }
    }

    private func receive(_ text: String, _ generation: Int, _ socket: any VoiceSocket) {
        switch VoiceProtocol.decode(text) {
        case .started(_, let format, let limit)?:
            guard format == VoiceProtocol.audioFormat else { failed(generation, .interrupted, "audio_format_rejected"); return }
            transition(.started(generation, maxDurationSeconds: limit))
        case .mark(let name)?:
            guard marks.count < 1024 else { failed(generation, .interrupted, "mark_overflow"); return }
            nextMark += 1
            let id = nextMark
            marks.append((id, name))
            counters.receivedMarks += 1
            do {
                try sink.mark { [weak self] in
                    self?.queue.async { [weak self] in
                        guard let self, self.isCurrent(generation, socket), self.marks.contains(where: { $0.id == id }) else { return }
                        self.acknowledge(socket, through: id)
                    }
                }
            } catch { failed(generation, .interrupted, "mark_rejected") }
        case .clear?:
            sink.clear()
            acknowledge(socket, through: nil)
        case .transcript(let role, let text, let final)?:
            onTranscript?(role, text, final)
        case .ended(let reason, _)?:
            let result = VoiceProtocol.endedResult(reason)
            onDiagnostic?("session_ended reason=\(VoiceProtocol.diagnosticReason(reason))")
            if result == .ended { finish(generation, .ended) } else { failed(generation, result, "session_ended") }
        case .error(let code, let message)?:
            failed(generation, VoiceProtocol.errorResult(code: code, message: message), "server_error code=\(code)")
        case nil:
            break
        }
    }

    /// Acknowledges marks in order, up to and including `through`, or all of them.
    private func acknowledge(_ socket: any VoiceSocket, through id: Int?) {
        while !marks.isEmpty {
            let mark = marks.removeFirst()
            guard socket.send(text: VoiceProtocol.played(mark.name)) else { failed(current.generation, .interrupted, "played_send_failed"); return }
            counters.acknowledgedMarks += 1
            if mark.id == id { return }
        }
    }

    /// Absolute deadlines: a relative delay per frame runs slower than the microphone, which then
    /// overflows the queue. After a long stall the schedule restarts instead of bursting to catch up.
    private func pace(_ generation: Int, _ socket: any VoiceSocket, due: UInt64) {
        scheduler.schedule(at: due, on: queue) { [weak self] in
            guard let self, self.isCurrent(generation, socket), self.current.phase != .ending else { return }
            let frame = self.muted || self.uplink.isEmpty ? self.silence : self.uplink.removeFirst()
            if socket.isAudioBackpressured { self.counters.stalledFrames += 1 }
            else if socket.send(audio: frame) { self.counters.sentFrames += 1 }
            else { self.failed(generation, .interrupted, "uplink_send_failed"); return }
            let step = VoiceProtocol.frameNanoseconds
            var next = due + step
            let now = self.scheduler.now
            if now > next + step * UInt64(Self.uplinkFrames) { next = now + step }
            self.pace(generation, socket, due: next)
        }
    }

    // MARK: Ending

    private func failed(_ generation: Int, _ result: VoiceCallResult, _ cause: String) {
        onDiagnostic?(cause)
        guard result == .credentialsExpired else { finish(generation, result); return }
        // Only while connecting: a key revoked during a call ends it rather than redialing with a new one.
        let canRetry = !retried && current.phase != .ending && !current.startedByServer
        cleanup()
        if canRetry {
            // One fresh key, once: a key revoked or expired since it was saved.
            retried = true
            let next = generation + 1
            transition(.retryCredentials(next))
            prepare(next, invalidate: true)
        } else {
            let credentials = self.credentials
            preparing = Task { [weak self] in
                await credentials.invalidate()
                self?.queue.async { [weak self] in
                    guard let self, self.isCurrent(generation) else { return }
                    self.finish(generation, result)
                }
            }
        }
    }

    private func finish(_ generation: Int, _ result: VoiceCallResult, forceClose: Bool = false) {
        transition(.finished(generation, result))
        let old = socket
        socket = nil
        cleanup()
        if let old {
            if !forceClose && result == .ended { old.close() } else { old.cancel() }
        }
    }

    private func cleanup() {
        if let old = socket { socket = nil; old.cancel() }
        opened = false
        preparing?.cancel(); preparing = nil
        uplink.removeAll()
        marks.removeAll()
        sink.clear()
    }

    private func isCurrent(_ generation: Int, _ socket: (any VoiceSocket)? = nil) -> Bool {
        !disposed && current.generation == generation && current.phase.isLive && (socket == nil || self.socket === socket)
    }

    private func transition(_ signal: VoiceCallSignal) { publish(VoiceCallReducer.reduce(current, signal)) }

    private func publish(_ next: VoiceCallState) {
        guard next != current else { return }
        current = next
        onState?(next)
    }
}

/// Lets the event closure reach the socket that `connect` returns.
private final class SocketHolder: @unchecked Sendable {
    var socket: (any VoiceSocket)?
}
