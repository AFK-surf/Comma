import Foundation
@testable import CommaCore

// A scripted voice service, socket and speaker for VoiceSession tests.

final class FakeVoiceSocket: VoiceSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let events: @Sendable (VoiceSocketEvent) -> Void
    private var sentTexts: [String] = []
    private var sentAudio: [Data] = []
    private var closedNormally = false
    private var cancelledNow = false
    var backlog = 0

    init(events: @escaping @Sendable (VoiceSocketEvent) -> Void) { self.events = events }

    var texts: [String] { lock.withLock { sentTexts } }
    var audio: [Data] { lock.withLock { sentAudio } }
    var closed: Bool { lock.withLock { closedNormally } }
    var cancelled: Bool { lock.withLock { cancelledNow } }
    var queuedBytes: Int { lock.withLock { backlog } }

    func send(text: String) -> Bool { lock.withLock { guard !closedNormally && !cancelledNow else { return false }; sentTexts.append(text); return true } }
    func send(audio: Data) -> Bool { lock.withLock { guard !closedNormally && !cancelledNow else { return false }; sentAudio.append(audio); return true } }
    func close() { lock.withLock { closedNormally = true } }
    func cancel() { lock.withLock { cancelledNow = true } }

    func emit(_ event: VoiceSocketEvent) { events(event) }
    func open() { emit(.opened(subprotocol: VoiceProtocol.subprotocol)) }
    func server(_ json: String) { emit(.text(json)) }
}

final class FakeVoiceTransport: VoiceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var readinessFailures: [VoiceFailure?]
    private var opened: [FakeVoiceSocket] = []
    private var waiters: [(index: Int, continuation: CheckedContinuation<FakeVoiceSocket, Never>)] = []
    init(readiness: [VoiceFailure?] = []) { readinessFailures = readiness }

    var sockets: [FakeVoiceSocket] { lock.withLock { opened } }

    /// The `index`th socket the session connects, once it has.
    func socket(_ index: Int) async -> FakeVoiceSocket {
        await withCheckedContinuation { continuation in
            let ready: FakeVoiceSocket? = lock.withLock {
                if index < opened.count { return opened[index] }
                waiters.append((index, continuation))
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func readiness(_ endpoint: VoiceEndpoint) async throws {
        if let failure = lock.withLock({ readinessFailures.isEmpty ? nil : readinessFailures.removeFirst() }) { throw failure }
    }

    func connect(_ endpoint: VoiceEndpoint, events: @escaping @Sendable (VoiceSocketEvent) -> Void) -> any VoiceSocket {
        let socket = FakeVoiceSocket(events: events)
        let due = lock.withLock { () -> [CheckedContinuation<FakeVoiceSocket, Never>] in
            opened.append(socket)
            let index = opened.count - 1
            defer { waiters.removeAll { $0.index == index } }
            return waiters.filter { $0.index == index }.map(\.continuation)
        }
        due.forEach { $0.resume(returning: socket) }
        return socket
    }
}

final class FakeVoiceCredentials: VoiceCredentialSource, @unchecked Sendable {
    private let lock = NSLock()
    private var endpointCalls = 0
    private var invalidateCalls = 0
    var counts: (endpoint: Int, invalidate: Int) { lock.withLock { (endpointCalls, invalidateCalls) } }

    func endpoint() async throws -> VoiceEndpoint {
        lock.withLock { endpointCalls += 1 }
        return try VoiceEndpoint(sessionsURL: "wss://voice.comma.test/sessions", readinessURL: "https://voice.comma.test/voice", bearer: "salix_vk_test")
    }
    func invalidate() async { lock.withLock { invalidateCalls += 1 } }
}

final class FakeSpeaker: VoicePlaybackSink, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var pendingMarks: [@Sendable () -> Void] = []
    private var clears = 0
    var rejects = false

    var played: [Data] { lock.withLock { chunks } }
    var clearCount: Int { lock.withLock { clears } }
    var markCount: Int { lock.withLock { pendingMarks.count } }

    func play(_ pcm: Data) throws {
        if rejects { throw CommaError.transport }
        lock.withLock { chunks.append(pcm) }
    }
    func mark(_ onPlayed: @escaping @Sendable () -> Void) throws { lock.withLock { pendingMarks.append(onPlayed) } }
    func clear() { lock.withLock { clears += 1; pendingMarks.removeAll() } }

    /// Plays everything queued, reaching every mark in order.
    func playOut() {
        let reached = lock.withLock { () -> [@Sendable () -> Void] in defer { pendingMarks.removeAll() }; return pendingMarks }
        reached.forEach { $0() }
    }
}

/// A clock the test moves: timers fire on the session's queue, in deadline order, only inside `advance`.
final class ManualVoiceScheduler: VoiceScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 1_000_000_000
    private var sequence = 0
    private var timers: [(deadline: UInt64, sequence: Int, queue: DispatchQueue, work: @Sendable () -> Void)] = []

    var now: UInt64 { lock.withLock { current } }

    func schedule(at deadline: UInt64, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
        lock.withLock {
            sequence += 1
            timers.append((deadline, sequence, queue, work))
        }
    }

    /// Moves the clock forward by `nanoseconds`, running every timer that falls due, including ones they schedule.
    func advance(by nanoseconds: UInt64) {
        let target = now + nanoseconds
        while let timer = lock.withLock({ () -> (UInt64, Int, DispatchQueue, @Sendable () -> Void)? in
            guard let next = timers.filter({ $0.deadline <= target })
                .min(by: { ($0.deadline, $0.sequence) < ($1.deadline, $1.sequence) }) else { return nil }
            timers.removeAll { $0.sequence == next.sequence }
            current = max(current, next.deadline)
            return next
        }) {
            timer.2.sync(execute: timer.3)
        }
        lock.withLock { current = target }
    }

    /// Advances by `count` uplink frames.
    func advance(frames count: Int) { advance(by: UInt64(count) * VoiceProtocol.frameNanoseconds) }
}

/// Every state the session publishes, in order, for a test to await.
final class VoiceStates: @unchecked Sendable {
    private let stream: AsyncStream<VoiceCallState>
    private var iterator: AsyncStream<VoiceCallState>.Iterator

    init(_ session: VoiceSession) {
        let (stream, continuation) = AsyncStream<VoiceCallState>.makeStream()
        self.stream = stream
        iterator = stream.makeAsyncIterator()
        session.onState = { continuation.yield($0) }
    }

    /// The next published state that satisfies `condition`.
    func next(where condition: (VoiceCallState) -> Bool) async -> VoiceCallState? {
        while let state = await iterator.next() {
            if condition(state) { return state }
        }
        return nil
    }
}

/// Runs everything already queued on the session's queue.
func drain(_ session: VoiceSession) { _ = session.snapshot() }

func textTypes(_ socket: FakeVoiceSocket) -> [String] {
    socket.texts.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }.compactMap { $0["type"] as? String }
}

let startedJSON = #"{"type":"session.started","call_id":"call-1","audio_format":"pcm16_24k","max_duration_s":1800}"#
