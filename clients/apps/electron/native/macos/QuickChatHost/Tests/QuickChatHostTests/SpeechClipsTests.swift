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
}

/// Live dictation's socket, played by the test.
@MainActor
private final class ScriptedSocket: DictationConnection {
    let events: AsyncStream<DictationEvent>
    private let continuation: AsyncStream<DictationEvent>.Continuation
    private(set) var sent: [Data] = []
    private(set) var ended = false
    private(set) var cancelled = false
    private var cancelWaiter: CheckedContinuation<Void, Never>?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: DictationEvent.self)
    }

    func send(_ pcm: Data) { sent.append(pcm) }
    func end() { ended = true }
    func cancel() {
        cancelled = true
        continuation.finish()
        cancelWaiter?.resume()
        cancelWaiter = nil
    }

    func waitForCancel() async {
        if cancelled { return }
        await withCheckedContinuation { cancelWaiter = $0 }
    }

    func say(_ event: DictationEvent) { continuation.yield(event) }
}

@MainActor
private final class Dictation {
    let socket = ScriptedSocket()
    let probe = TranscriptionProbe()
    private(set) var source: LiveDictation!
    private var texts: [String] = []
    private var textWaiter: CheckedContinuation<String, Never>?
    private var connected = false
    private var connectWaiter: CheckedContinuation<Void, Never>?

    init(draft: String = "", ticket: DictationTicket? = DictationTicket(url: "wss://comma.test/v1/comma/dictation", ticket: "t")) {
        source = LiveDictation(
            draft: draft,
            ticket: { ticket },
            transcribe: probe.transcribe,
            connect: { [unowned self] _ in
                connected = true
                connectWaiter?.resume()
                connectWaiter = nil
                return socket
            },
            encodeAudio: probe.encode,
            listens: false
        )
        source.onText = { [unowned self] text in
            if let textWaiter {
                self.textWaiter = nil
                textWaiter.resume(returning: text)
            } else {
                texts.append(text)
            }
        }
        source.start()
    }

    func waitForSocket() async {
        if connected { return }
        await withCheckedContinuation { connectWaiter = $0 }
    }

    /// The words shown next.
    func shown() async -> String {
        if !texts.isEmpty { return texts.removeFirst() }
        return await withCheckedContinuation { textWaiter = $0 }
    }
}

/// `seconds` of 16 kHz s16le audio, heard as the microphone gives it.
private func pcm(_ seconds: Double) -> Data {
    Data(count: Int(seconds * 16_000) * 2)
}

@MainActor
struct LiveDictationTests {
    @Test(.timeLimit(.minutes(1))) func liveWordsShowAsSaidAndASendWaitsForTheLastSegmentsFinalWords() async {
        let dictation = Dictation(draft: "Draft:")
        // Heard before the socket opened: it goes up first, in 128 ms frames.
        dictation.source.hear(pcm(0.5), through: 0.5, paused: false)
        await dictation.waitForSocket()
        dictation.source.hear(pcm(0.5), through: 1, paused: false)
        dictation.socket.say(.partial(segment: 0, text: "明日の"))
        #expect(await dictation.shown() == "Draft: 明日の")
        dictation.socket.say(.final(segment: 0, text: "明日の会議を予約して。"))
        #expect(await dictation.shown() == "Draft: 明日の会議を予約して。")
        dictation.socket.say(.partial(segment: 1, text: "资料"))
        #expect(await dictation.shown() == "Draft: 明日の会議を予約して。资料")

        // Enter: the words as shown at once, then the settled ones.
        #expect(await dictation.source.finish() == "Draft: 明日の会議を予約して。资料")
        #expect(dictation.socket.ended)
        #expect(dictation.socket.sent.reduce(0) { $0 + $1.count } == pcm(1).count)
        #expect(dictation.socket.sent.dropLast().allSatisfy { $0.count == LiveDictation.frameBytes })
        let sending = Task { await dictation.source.serverWords(waitForSlot: true) }
        dictation.socket.say(.final(segment: 1, text: "資料は前日までに送ります。"))
        dictation.socket.say(.done)
        #expect(await sending.value == "Draft: 明日の会議を予約して。資料は前日までに送ります。")
        #expect(dictation.probe.requested.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func withoutLiveDictationEveryPauseIsAClipFromTheStart() async {
        let dictation = Dictation(ticket: nil)
        // Before the ticket was refused: kept in the recording.
        dictation.source.hear(pcm(1), through: 3, paused: true)
        await dictation.probe.waitForRequests(1)
        #expect(dictation.probe.requested == [0..<3])
        dictation.source.hear(pcm(1), through: 70, paused: false)
        await dictation.probe.waitForRequests(2)
        dictation.probe.reply(0..<3, "first")
        #expect(await dictation.shown() == "first")
        _ = await dictation.source.finish()
        let sending = Task { await dictation.source.serverWords(waitForSlot: true) }
        await dictation.probe.waitForRequests(3)
        dictation.probe.reply(3..<63, "second")
        dictation.probe.reply(63..<70, "tail")
        #expect(await sending.value == "first second tail")
        #expect(dictation.probe.waitingPolicies == [false, false, true])
    }

    @Test(.timeLimit(.minutes(1))) func aSocketThatFailsKeepsItsWordsAndClipsTheRest() async {
        let dictation = Dictation()
        await dictation.waitForSocket()
        dictation.source.hear(pcm(1), through: 4, paused: false)
        dictation.socket.say(.final(segment: 0, text: "Draft a reply."))
        #expect(await dictation.shown() == "Draft a reply.")
        dictation.socket.say(.unavailable)
        await dictation.socket.waitForCancel()
        // From where the socket failed; what it settled stays.
        dictation.source.hear(pcm(1), through: 9, paused: true)
        await dictation.probe.waitForRequests(1)
        #expect(dictation.probe.requested == [4..<9])
        dictation.probe.reply(4..<9, "Then send it.")
        #expect(await dictation.shown() == "Draft a reply. Then send it.")
        #expect(await dictation.source.serverWords(waitForSlot: true) == "Draft a reply. Then send it.")
    }

    @Test(.timeLimit(.minutes(1))) func cancelEndsTheWaitForWords() async {
        let dictation = Dictation()
        await dictation.waitForSocket()
        dictation.socket.say(.partial(segment: 0, text: "half"))
        #expect(await dictation.shown() == "half")
        _ = await dictation.source.finish()
        let sending = Task { await dictation.source.serverWords(waitForSlot: true) }
        dictation.source.stop()
        #expect(await sending.value == nil)
        #expect(dictation.socket.cancelled)
    }
}
