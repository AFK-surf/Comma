import Foundation
import QuickChatCore

/// Adjacent clips share two encoding/request slots. Sending promotes pending
/// work to admission-waiting requests and retries failed background clips once.
@MainActor
final class ClipTranscriptions {
    typealias Encode = @MainActor (Range<Double>) async -> Data?
    private let encode: Encode
    private let transcribe: @MainActor (Data, Bool) async -> String?
    private let completed: @MainActor (Range<Double>, String?) -> Void
    private var pending: [Range<Double>] = []
    private var failedBackground: [Range<Double>] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var cancelled = false
    private var sending = false
    private(set) var through = 0.0

    init(
        encode: @escaping Encode,
        transcribe: @escaping @MainActor (Data, Bool) async -> String?,
        completed: @escaping @MainActor (Range<Double>, String?) -> Void
    ) {
        self.encode = encode
        self.transcribe = transcribe
        self.completed = completed
    }

    /// A delayed microphone callback can cover several clips. Keep all of them.
    func append(through end: Double) {
        guard !cancelled, end.isFinite else { return }
        while end > through {
            let next = min(end, through + ExactSpeech.clipLength)
            pending.append(through..<next)
            through = next
        }
        startNext()
    }

    func finish(through end: Double, waitForSlot: Bool) async -> Bool {
        guard !cancelled else { return false }
        if waitForSlot, !sending {
            sending = true
            pending.insert(contentsOf: failedBackground, at: 0)
            failedBackground.removeAll()
        }
        append(through: end)
        return await wait()
    }

    func wait() async -> Bool {
        guard !cancelled else { return false }
        if pending.isEmpty, running.isEmpty { return true }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        pending.removeAll()
        failedBackground.removeAll()
        for task in running.values { task.cancel() }
        running.removeAll()
        resumeWaiters(false)
    }

    private func startNext() {
        while !cancelled, running.count < 2, !pending.isEmpty {
            let clip = pending.removeFirst()
            let id = UUID()
            running[id] = Task { [weak self, encode, transcribe] in
                let audio = await encode(clip)
                // A send can arrive during encoding; use its admission policy.
                let waitForSlot = self?.sending ?? false
                let words: String?
                if !Task.isCancelled, let audio {
                    words = await transcribe(audio, waitForSlot)
                } else {
                    words = nil
                }
                self?.complete(id, clip: clip, words: words, waited: waitForSlot)
            }
        }
    }

    private func complete(_ id: UUID, clip: Range<Double>, words: String?, waited: Bool) {
        guard running.removeValue(forKey: id) != nil, !cancelled else { return }
        let words = words.flatMap { value in value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value }
        if words == nil, !waited {
            if sending { pending.append(clip) } else { failedBackground.append(clip) }
        }
        completed(clip, words)
        startNext()
        if pending.isEmpty, running.isEmpty { resumeWaiters(true) }
    }

    private func resumeWaiters(_ finished: Bool) {
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume(returning: finished) }
    }
}
