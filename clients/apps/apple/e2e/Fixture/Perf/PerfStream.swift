import Foundation
import notify

/// Event stream bodies for `--perf-hold-stream` and `--perf-stream`. A held stream sends its frames and stays open,
/// as a live server's does between events; the client cancels it when its pane closes or reconnects.
enum PerfStream {
    /// 200 cumulative deltas at 30 Hz, as a fast model streams.
    static let deltas = 200
    static let rate = 30.0
    /// From the signal to the first frame. XCUITest waits for the app to go idle before each touch, which a
    /// streaming app never does, so a scenario starts its touch in this lead and the touch overlaps the deltas.
    static let lead: Duration = .milliseconds(500)

    static func held(_ frames: [Data]) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            for frame in frames { continuation.yield(frame) }
        }
    }

    /// The router's snapshot of its newest messages, which every connection opens with.
    static func snapshot(_ messages: ArraySlice<String>) -> Data {
        frame(#"{"type":"snapshot","conversation_id":"home","group_id":"g","title":"Home","status":"open","messages":[\#(messages.joined(separator: ","))]}"#)
    }

    /// The snapshot, then, once `gate` opens, the drafted reply: started, the deltas, completed, and after
    /// `commit` has made the reply part of the conversation, message_created, which makes the client core
    /// reconnect and read the snapshot that holds the reply. Only the first connection to claim the gate plays it; later ones hold.
    static func reply(after snapshot: Data, gate: PerfReplyGate,
                      commit: @escaping @Sendable () async -> Void) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            let player = Task {
                guard await gate.claim() else { return }
                try? await Task.sleep(for: lead)
                let text = Array(PerfChat.streamedReply)
                let clock = ContinuousClock()
                let start = clock.now
                if Task.isCancelled { return }
                continuation.yield(draft("started", revision: 0, text: "", delta: ""))
                var sent = 0
                for revision in 1...deltas {
                    try? await clock.sleep(until: start + .seconds(Double(revision) / rate))
                    if Task.isCancelled { return }
                    let end = text.count * revision / deltas
                    continuation.yield(draft("delta", revision: revision, text: String(text[..<end]), delta: String(text[sent..<end])))
                    sent = end
                }
                continuation.yield(draft("completed", revision: deltas + 1, text: String(text), delta: ""))
                await commit()
                continuation.yield(frame(#"{"type":"message_created","conversation_id":"home","group_id":"g","message_id":"message150","role":"assistant"}"#))
            }
            continuation.onTermination = { _ in player.cancel() }
        }
    }

    private static func draft(_ kind: String, revision: Int, text: String, delta: String) -> Data {
        frame(PerfChat.json([
            "type": "message_draft_" + kind, "conversation_id": "home", "group_id": "g", "draft_id": "perf-draft",
            "response_key": "perf-response", "source_message_ids": [PerfChat.replySource],
            "revision": revision, "text": text, "delta": delta,
        ]))
    }

    private static func frame(_ json: String) -> Data { Data("data: \(json)\n\n".utf8) }
}

/// Opens on `PerfSignal.stream`, which the streaming scenario posts once the router chat is on screen. The router
/// stream connects at launch, long before that, so it cannot start the reply on its own.
actor PerfReplyGate {
    private var open = false
    private var claimed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static func listening() -> PerfReplyGate {
        let gate = PerfReplyGate()
        var token: Int32 = 0
        notify_register_dispatch(PerfSignal.stream.name, &token, .global()) { _ in Task { await gate.signal() } }
        return gate
    }

    private func signal() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// Waits for the signal; true for the first caller still connected. A waiter whose stream was cancelled
    /// meanwhile resumes too, and gets false.
    func claim() async -> Bool {
        if !open { await withCheckedContinuation { waiters.append($0) } }
        guard !claimed, !Task.isCancelled else { return false }
        claimed = true
        return true
    }
}
