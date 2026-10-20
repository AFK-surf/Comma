import Foundation
import Testing
import QuickChatCore
@testable import QuickChatHost

@MainActor
private final class TranscriptionProbe {
    private(set) var encoded: [Range<Double>] = []
    private(set) var requested: [Range<Double>] = []
    private(set) var waitingPolicies: [Bool] = []
    private var replies: [Range<Double>: CheckedContinuation<String?, Never>] = [:]
    private var started: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var active = 0
    private(set) var mostActive = 0

    func encode(_ clip: Range<Double>) async -> Data? {
        encoded.append(clip)
        return Data("\(clip.lowerBound),\(clip.upperBound)".utf8)
    }

    func transcribe(_ data: Data, _ waitForSlot: Bool) async -> String? {
        let numbers = String(decoding: data, as: UTF8.self).split(separator: ",").map { Double($0)! }
        let clip = numbers[0]..<numbers[1]
        active += 1
        mostActive = max(mostActive, active)
        let answer = await withCheckedContinuation { continuation in
            requested.append(clip)
            waitingPolicies.append(waitForSlot)
            replies[clip] = continuation
            let ready = started.filter { requested.count >= $0.0 }
            started.removeAll { requested.count >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
        active -= 1
        return answer
    }

    func waitForRequests(_ count: Int) async {
        if requested.count >= count { return }
        await withCheckedContinuation { started.append((count, $0)) }
    }

    func reply(_ clip: Range<Double>, _ text: String?) {
        replies.removeValue(forKey: clip)?.resume(returning: text)
    }
}

@MainActor
struct SpeechClipsTests {
    @Test(.timeLimit(.minutes(1))) func longSpeechKeepsEveryClipWhileTwoRequestsAreBusy() async {
        let probe = TranscriptionProbe()
        var answers: [Range<Double>] = []
        let queue = ClipTranscriptions(encode: probe.encode, transcribe: probe.transcribe) { clip, _ in
            answers.append(clip)
        }
        queue.append(through: 190)
        await probe.waitForRequests(2)
        #expect(probe.requested == [0..<60, 60..<120])
        probe.reply(60..<120, "second")
        await probe.waitForRequests(3)
        probe.reply(0..<60, "first")
        await probe.waitForRequests(4)
        probe.reply(120..<180, nil)
        probe.reply(180..<190, "tail")
        #expect(await queue.wait())
        #expect(probe.encoded == [0..<60, 60..<120, 120..<180, 180..<190])
        #expect(probe.mostActive == 2)
        #expect(answers.count == 4)
    }

    @Test(.timeLimit(.minutes(1))) func sendWaitsOnlyForPendingClipsAndTailWhileLocalFinishIsImmediate() async {
        let probe = TranscriptionProbe()
        let source = SpeechSession(
            draft: "Draft:", transcribe: probe.transcribe, writesCJK: [false],
            encodeAudio: probe.encode, finalizeInput: { true }
        )
        source.receive([
            .init(start: 0, end: 10, text: "local first", confidences: []),
            .init(start: 60, end: 70, text: "local second", confidences: []),
            .init(start: 120, end: 130, text: "local tail", confidences: []),
        ], from: 0, finalizedThrough: 130)
        source.audioProgress(through: 130, paused: false)
        await probe.waitForRequests(2)
        // No response was supplied: editing/Esc still gets local text now.
        #expect(await source.finish() == "Draft: local first local second local tail")
        #expect(source.audio == nil)
        let sending = Task { await source.serverWords(waitForSlot: true) }
        probe.reply(60..<120, "server second")
        await probe.waitForRequests(3)
        probe.reply(120..<130, "server tail")
        probe.reply(0..<60, "server first")
        #expect(await sending.value == "Draft: server first server second server tail")
        #expect(await source.serverWords() == "Draft: server first server second server tail")
        #expect(probe.encoded == [0..<60, 60..<120, 120..<130])
        #expect(probe.waitingPolicies == [false, false, true])
        #expect(probe.mostActive == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aFailedClipKeepsLocalWordsBetweenSuccessfulClips() async {
        let probe = TranscriptionProbe()
        let source = SpeechSession(
            draft: "", transcribe: probe.transcribe, writesCJK: [false],
            encodeAudio: probe.encode, finalizeInput: { true }
        )
        for (start, text) in [(0.0, "local first"), (60, "local middle"), (120, "local last")] {
            source.receive([.init(start: start, end: start + 8, text: text, confidences: [])],
                           from: 0, finalizedThrough: start + 8)
        }
        source.audioProgress(through: 130, paused: false)
        await probe.waitForRequests(2)
        let sending = Task { await source.serverWords(waitForSlot: true) }
        probe.reply(0..<60, "server first")
        await probe.waitForRequests(3)
        probe.reply(60..<120, nil)
        probe.reply(120..<130, "server last")
        await probe.waitForRequests(4)
        probe.reply(60..<120, nil)
        #expect(await sending.value == "server first local middle server last")
        #expect(probe.requested == [0..<60, 60..<120, 120..<130, 60..<120])
        #expect(probe.waitingPolicies == [false, false, true, true])
    }

    @Test(.timeLimit(.minutes(1))) func sendRetriesAnEarlierFailedBackgroundClipOnceWithAdmissionWaiting() async {
        let probe = TranscriptionProbe()
        let queue = ClipTranscriptions(encode: probe.encode, transcribe: probe.transcribe) { _, _ in }
        queue.append(through: 60)
        await probe.waitForRequests(1)
        probe.reply(0..<60, nil)
        #expect(await queue.wait())
        let sending = Task { await queue.finish(through: 70, waitForSlot: true) }
        await probe.waitForRequests(3)
        probe.reply(0..<60, "recovered")
        probe.reply(60..<70, "tail")
        #expect(await sending.value)
        #expect(probe.requested == [0..<60, 0..<60, 60..<70])
        #expect(probe.waitingPolicies == [false, true, true])
    }

    @Test(.timeLimit(.minutes(1))) func cancelAfterLocalFinishEndsWaitAndStartsNoMoreRequests() async {
        let probe = TranscriptionProbe()
        let source = SpeechSession(
            draft: "", transcribe: probe.transcribe, writesCJK: [false],
            encodeAudio: probe.encode, finalizeInput: { true }
        )
        source.audioProgress(through: 190, paused: false)
        await probe.waitForRequests(2)
        _ = await source.finish()
        let sending = Task { await source.serverWords(waitForSlot: true) }
        source.stop()
        #expect(await sending.value == nil)
        probe.reply(0..<60, "late first")
        probe.reply(60..<120, "late second")
        #expect(probe.requested.count == 2)
        #expect(source.text.isEmpty)
    }
}

@MainActor
struct SpeechFallbackTests {
    @Test(.timeLimit(.minutes(1))) func failedLocalFinalizationKeepsTheLiveTailWhenServerAlsoFails() async {
        let source = SpeechSession(
            draft: "Draft:", transcribe: { _, _ in nil }, writesCJK: [false],
            encodeAudio: { _ in Data([1]) }, finalizeInput: { false }
        )
        source.receive([.init(start: 0, end: 5, text: "old prefix", confidences: [])],
                       from: 0, finalizedThrough: 5)
        source.receiveLive("all the latest words including the unfinished tail", from: 0, isFinal: false)
        source.audioProgress(through: 10, paused: false)
        let local = await source.finish()
        #expect(local == "Draft: all the latest words including the unfinished tail")
        #expect(await source.serverWords() == local)
    }
}
