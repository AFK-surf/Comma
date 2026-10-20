import Foundation
import QuickChatCore

/// The server's words for audio, through Main (`recordings.transcribe` as
/// dictation). Main answers each `transcribe` once, within its request
/// timeout: with the words, or nil when the server could not transcribe them.
@MainActor
final class ServerTranscripts {
    private let emit: (HostEvent) -> Void
    private var waiting: [String: CheckedContinuation<String?, Never>] = [:]

    init(emit: @escaping (HostEvent) -> Void) {
        self.emit = emit
    }

    func transcribe(_ audio: Data, waitForSlot: Bool = false) async -> String? {
        let clipId = UUID().uuidString
        return await withCheckedContinuation { continuation in
            waiting[clipId] = continuation
            emit(.transcribe(clipId: clipId, audio: audio, waitForSlot: waitForSlot))
        }
    }

    func receive(clipId: String, text: String?) {
        waiting.removeValue(forKey: clipId)?.resume(returning: text)
    }
}
