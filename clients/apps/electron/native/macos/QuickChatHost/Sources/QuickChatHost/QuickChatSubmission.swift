import QuickChatCore

/// Keeps the existing send visible while its remaining audio clips finish.
@MainActor
final class QuickChatSubmission {
    private let emit: (HostEvent) -> Void
    private var sources: [String: TranscriptSource] = [:]

    init(emit: @escaping (HostEvent) -> Void) {
        self.emit = emit
    }

    @discardableResult
    func send(requestId: String, source: TranscriptSource) -> Task<Void, Never>? {
        guard sources[requestId] == nil else { return nil }
        sources[requestId] = source
        emit(.preparing(requestId: requestId, text: source.text))
        return Task {
            let local = await source.finish()
            guard sources[requestId] != nil else { return }
            emit(.preparing(requestId: requestId, text: local, update: true))
            let words = await source.serverWords(waitForSlot: true)
            guard sources.removeValue(forKey: requestId) != nil else { return }
            source.stop()
            emit(.submit(requestId: requestId, text: words ?? local, draft: "", audio: nil, prepared: true))
        }
    }

    /// Main refused or timed out the send. A late transcript must not submit it.
    func cancel(requestId: String) {
        sources.removeValue(forKey: requestId)?.stop()
    }
}
