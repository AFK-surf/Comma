import Foundation
import QuickChatCore
import Testing

@testable import QuickChatHost

@MainActor
private final class PendingSpeech: TranscriptSource {
    var onText: ((String) -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    var onPreparing: ((Bool) -> Void)?
    var onFailure: ((SpeechFailure) -> Void)?
    let text = "The local words"
    let draft = ""
    let audio: Data? = nil
    let started = AsyncStream<Void>.makeStream()
    var answer: CheckedContinuation<String?, Never>?
    var stops = 0
    var waitsForSlot = false

    func start() {}
    func stop() { stops += 1 }
    func finish() async -> String { "The local words with their ending" }
    func serverWords(waitForSlot: Bool) async -> String? {
        waitsForSlot = waitForSlot
        return await withCheckedContinuation {
            answer = $0
            started.continuation.yield(())
        }
    }
}

@MainActor
@Test func sendShowsPendingBeforeItsClipsFinishAndSubmitsOnlyTheirWords() async throws {
    var events: [HostEvent] = []
    let source = PendingSpeech()
    let submission = QuickChatSubmission { events.append($0) }
    let task = try #require(submission.send(requestId: "send", source: source))
    #expect(events == [.preparing(requestId: "send", text: source.text)])
    #expect(submission.send(requestId: "send", source: source) == nil)
    var started = source.started.stream.makeAsyncIterator()
    await started.next()
    #expect(events.last == .preparing(requestId: "send", text: "The local words with their ending", update: true))
    source.answer?.resume(returning: "The corrected clips in order")
    await task.value
    #expect(events == [
        .preparing(requestId: "send", text: source.text),
        .preparing(requestId: "send", text: "The local words with their ending", update: true),
        .submit(requestId: "send", text: "The corrected clips in order", draft: "", audio: nil, prepared: true),
    ])
    let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(events[2])) as? [String: Any])
    #expect(wire["prepared"] as? Bool == true)
    #expect(wire["audio"] == nil)
    #expect(source.stops == 1)
    #expect(source.waitsForSlot)
}

@MainActor
@Test func failedPreparationStopsItsSourceAndLateWordsCannotSubmit() async throws {
    var events: [HostEvent] = []
    let source = PendingSpeech()
    let submission = QuickChatSubmission { events.append($0) }
    let task = try #require(submission.send(requestId: "send", source: source))
    var started = source.started.stream.makeAsyncIterator()
    await started.next()
    submission.cancel(requestId: "send")
    #expect(source.stops == 1)
    source.answer?.resume(returning: "A late transcript")
    await task.value
    #expect(events == [
        .preparing(requestId: "send", text: source.text),
        .preparing(requestId: "send", text: "The local words with their ending", update: true),
    ])
}

@MainActor
@Test func unavailableServerWordsKeepTheLocalSend() async throws {
    var events: [HostEvent] = []
    let source = PendingSpeech()
    let submission = QuickChatSubmission { events.append($0) }
    let task = try #require(submission.send(requestId: "send", source: source))
    var started = source.started.stream.makeAsyncIterator()
    await started.next()
    source.answer?.resume(returning: nil)
    await task.value
    #expect(events.last == .submit(requestId: "send", text: "The local words with their ending", draft: "", audio: nil, prepared: true))
}
