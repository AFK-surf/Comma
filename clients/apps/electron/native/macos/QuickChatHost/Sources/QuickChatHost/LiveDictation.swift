import AVFoundation
import Foundation
import QuickChatCore

/// Where Quick Chat's words come from while it listens.
@MainActor
protocol TranscriptSource: AnyObject {
    /// The whole text so far, each time it changes.
    var onText: ((String) -> Void)? { get set }
    /// The voice's loudness, 0…1, with each audio buffer (about ten a second).
    var onLevel: ((CGFloat) -> Void)? { get set }
    var onFailure: ((SpeechFailure) -> Void)? { get set }
    /// The text as shown.
    var text: String { get }
    /// The text the words continue: a draft kept from an earlier Quick Chat, or edited words.
    var draft: String { get }
    /// The words go as text, so a send needs no whole-recording payload.
    var audio: Data? { get }
    func start()
    /// Cancel: stops listening; nothing is sent.
    func stop()
    /// Enter: stops listening and returns the words as shown.
    func finish() async -> String
    /// After `finish`: the settled words, once the last segments or clips
    /// have them. A send waits for transcription admission and retries
    /// failed background clips once. Nil if this source was cancelled.
    func serverWords(waitForSlot: Bool) async -> String?
}

enum SpeechFailure: Error {
    case microphoneDenied
    case unavailable
}

/// The server's live dictation (`DictationSocket`), as on Windows: the
/// microphone's PCM goes up as it is heard, and each segment's words come
/// back while it is spoken. The server settles each segment after a pause
/// with words that are right in any language.
///
/// Without live dictation (no ticket, a socket that fails) the microphone is
/// transcribed as clips (`ClipTranscriptions`), one per pause, at most
/// `ClipTranscriptions.clipLength` each, and the words show clip by clip.
/// Until live dictation answers, everything heard stays in the recording,
/// so falling back loses nothing.
@MainActor
final class LiveDictation: TranscriptSource {
    enum Live {
        case waiting, on, off
    }

    /// After Enter, the last segments' words are waited for this long.
    static let endLimit: Duration = .seconds(12)
    /// PCM goes up in frames of 128 ms.
    static let frameBytes = 4_096
    /// Until the socket opens, at most this much audio waits (about 8 s).
    static let backlogFrames = 64

    var onText: ((String) -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    var onFailure: ((SpeechFailure) -> Void)?

    let draft: String
    let audio: Data? = nil
    private(set) var live = Live.waiting
    /// What the words continue: the draft, or live dictation's words when it failed partway.
    private var base: String
    private var segments: [Int: String] = [:]
    private var clipWords: [(clip: Range<Double>, words: String?)] = []
    private var clips: ClipTranscriptions?
    private var connection: (any DictationConnection)?
    private var frame = Data()
    private var backlog: [Data] = []
    private var heardThrough = 0.0
    private var finished = false
    private var cancelled = false
    private var settled: [CheckedContinuation<Void, Never>] = []
    private var work: Task<Void, Never>?
    private var recording: Recording?
    private let engine = AVAudioEngine()
    private let ticket: @MainActor () async -> DictationTicket?
    private let connect: @MainActor (DictationTicket) -> (any DictationConnection)?
    private let transcribe: @MainActor (Data, Bool) async -> String?
    private let encodeAudio: ClipTranscriptions.Encode?
    private let listens: Bool

    init(
        draft: String,
        ticket: @escaping @MainActor () async -> DictationTicket?,
        transcribe: @escaping @MainActor (Data, Bool) async -> String?,
        connect: @escaping @MainActor (DictationTicket) -> (any DictationConnection)? = { DictationSocket(ticket: $0) },
        encodeAudio: ClipTranscriptions.Encode? = nil,
        listens: Bool = true
    ) {
        self.draft = draft
        base = draft
        self.ticket = ticket
        self.connect = connect
        self.transcribe = transcribe
        self.encodeAudio = encodeAudio
        self.listens = listens
    }

    /// The draft, then every segment's or clip's words so far, in order.
    var text: String {
        var spoken = ""
        for index in segments.keys.sorted() {
            spoken = SpeechText.joined(spoken, segments[index]!.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for clip in clipWords {
            if let words = clip.words { spoken = SpeechText.joined(spoken, words) }
        }
        return SpeechText.joined(base, spoken)
    }

    func start() {
        work = Task { [weak self] in await self?.run() }
    }

    func stop() {
        guard !cancelled else { return }
        cancelled = true
        finished = true
        stopMicrophone()
        work?.cancel()
        connection?.cancel()
        clips?.cancel()
        recording = nil
        resumeSettled()
    }

    func finish() async -> String {
        guard !finished else { return text }
        finished = true
        stopMicrophone()
        switch live {
        case .on:
            flushFrame()
            connection?.end()
            Task { [weak self] in
                try? await Task.sleep(for: Self.endLimit)
                self?.resumeSettled()
            }
        case .waiting:
            fallBack()
        case .off:
            break
        }
        return text
    }

    func serverWords(waitForSlot: Bool = false) async -> String? {
        _ = await finish()
        if live == .on, !cancelled {
            await withCheckedContinuation { settled.append($0) }
        }
        if live == .off, let clips, !cancelled {
            guard await clips.finish(through: heardThrough, waitForSlot: waitForSlot) else { return nil }
        }
        return cancelled ? nil : text
    }

    private func run() async {
        if listens {
            guard await Self.microphoneAllowed() else { return fail(.microphoneDenied) }
            guard !finished else { return }
            do {
                try startMicrophone()
            } catch {
                return fail(.unavailable)
            }
        }
        let ticket = await ticket()
        guard !cancelled, live == .waiting else { return }
        guard let ticket, let connection = connect(ticket) else { return fallBack() }
        self.connection = connection
        for frame in backlog { connection.send(frame) }
        backlog = []
        if finished {
            flushFrame()
            connection.end()
        }
        for await event in connection.events {
            guard !cancelled else { return }
            receive(event)
        }
    }

    /// What the socket said.
    func receive(_ event: DictationEvent) {
        guard !cancelled, live != .off else { return }
        switch event {
        case let .partial(segment, words), let .final(segment, words):
            // Live words came: what the recording kept meanwhile is not needed.
            live = .on
            segments[segment] = words
            onText?(text)
        case .done:
            resumeSettled()
        case .unavailable:
            fallBack()
        }
    }

    /// Live dictation is not there, or stopped answering: clips from here on,
    /// continuing its words; from the start when it never gave any.
    private func fallBack() {
        let wasOn = live == .on
        live = .off
        connection?.cancel()
        connection = nil
        backlog = []
        if wasOn {
            base = text
            segments = [:]
        }
        let clips = ClipTranscriptions(
            from: wasOn ? heardThrough : 0,
            encode: { [weak self] clip in
                guard let self, !cancelled else { return nil }
                if let encodeAudio { return await encodeAudio(clip) }
                return await recording?.m4a(from: clip.lowerBound, through: clip.upperBound)
            },
            transcribe: transcribe,
            completed: { [weak self] clip, words in
                guard let self, !cancelled else { return }
                clipWords.append((clip, words))
                clipWords.sort { $0.clip.lowerBound < $1.clip.lowerBound }
                onText?(text)
            }
        )
        self.clips = clips
        // What was heard before live dictation answered, or all of it after Enter.
        if !wasOn || finished { clips.append(through: heardThrough) }
        resumeSettled()
    }

    /// Each microphone buffer as 16 kHz mono s16le, heard through `seconds`:
    /// it goes up to live dictation, or closes a clip at a pause or the length limit.
    func hear(_ pcm: Data, through seconds: Double, paused: Bool) {
        guard !finished else { return }
        heardThrough = max(heardThrough, seconds)
        switch live {
        case .waiting, .on:
            frame.append(pcm)
            while frame.count >= Self.frameBytes {
                send(frame.prefix(Self.frameBytes))
                frame.removeFirst(Self.frameBytes)
            }
        case .off:
            guard let clips else { return }
            while heardThrough - clips.through >= ClipTranscriptions.clipLength {
                clips.append(through: clips.through + ClipTranscriptions.clipLength)
            }
            if paused, heardThrough > clips.through { clips.append(through: heardThrough) }
        }
    }

    private func flushFrame() {
        guard !frame.isEmpty else { return }
        send(frame)
        frame = Data()
    }

    private func send(_ pcm: Data) {
        if let connection {
            connection.send(Data(pcm))
        } else if backlog.count < Self.backlogFrames {
            backlog.append(Data(pcm))
        }
    }

    private func resumeSettled() {
        let waiting = settled
        settled = []
        for waiter in waiting { waiter.resume() }
    }

    private func startMicrophone() throws {
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: natural, to: format)
        else { throw SpeechFailure.unavailable }
        let recording = Recording(format: format)
        self.recording = recording
        let tap = MicrophoneTap(
            converter: converter, format: format, recording: recording,
            heard: { [weak self] level, pcm, time, paused in
                Task { @MainActor in
                    self?.onLevel?(level)
                    self?.hear(pcm, through: time, paused: paused)
                }
            }
        )
        tap.install(on: node, format: natural)
        engine.prepare()
        try engine.start()
    }

    private func stopMicrophone() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func fail(_ failure: SpeechFailure) {
        stop()
        onFailure?(failure)
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}

/// Runs on the audio thread: measures each buffer's loudness, converts it to
/// 16 kHz mono and finds the person's pauses in it. It is not on the main
/// actor: AVAudioEngine calls a tap on its own queue, and a tap block formed
/// on the main actor would trap there in Swift 6's isolation check.
private final class MicrophoneTap: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let recording: Recording
    /// Loudness, the buffer as s16le, the seconds heard so far, and whether a pause ended.
    private let heard: @Sendable (CGFloat, Data, Double, Bool) -> Void
    private var pauses = SpeechPause()
    private var frames: Int64 = 0

    init(
        converter: AVAudioConverter,
        format: AVAudioFormat,
        recording: Recording,
        heard: @escaping @Sendable (CGFloat, Data, Double, Bool) -> Void
    ) {
        self.converter = converter
        self.format = format
        self.recording = recording
        self.heard = heard
    }

    func install(on node: AVAudioInputNode, format natural: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 1024, format: natural) { buffer, _ in
            self.process(buffer)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let decibels = Self.decibels(buffer)
        // -50…-10 dBFS shows as 0…1.
        let level = CGFloat(max(0, min(1, (decibels + 50) / 40)))
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        ) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0, let samples = converted.floatChannelData?[0] else { return }
        recording.write(converted)
        frames += Int64(converted.frameLength)
        var pcm = Data(count: Int(converted.frameLength) * 2)
        pcm.withUnsafeMutableBytes { bytes in
            let output = bytes.bindMemory(to: Int16.self)
            for index in 0..<Int(converted.frameLength) {
                output[index] = Int16(max(-1, min(1, samples[index])) * Float(Int16.max)).littleEndian
            }
        }
        let paused = pauses.hear(decibels: decibels, seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
        heard(level, pcm, Double(frames) / format.sampleRate, paused)
    }

    /// RMS of the first channel, in dBFS.
    private static func decibels(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -140 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return Double(20 * log10(max(rms, 1e-7)))
    }
}

/// The audio heard, kept in memory while Quick Chat listens
/// (32 KB a second at 16 kHz). The audio thread adds each buffer; `m4a`
/// encodes it as AAC in M4A, off the main thread, in a file gone once read.
final class Recording: @unchecked Sendable {
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var frames: Int64 = 0

    var duration: Double { lock.withLock { Double(frames) / format.sampleRate } }

    init(format: AVAudioFormat) {
        self.format = format
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            buffers.append(buffer)
            frames += Int64(buffer.frameLength)
        }
    }

    /// The audio from `start` seconds before `end`, or all of it; nil when
    /// there is none. Clip buffers at both edges to preserve the time bound.
    func m4a(from start: Double = 0, through end: Double = .infinity) async -> Data? {
        await Task.detached { self.encode(from: start, through: end) }.value
    }

    private func encode(from start: Double, through end: Double) -> Data? {
        let buffers = audio(from: start, through: end)
        guard !buffers.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuickChat-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 32_000,
        ]
        guard let file = try? AVAudioFile(
            forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved
        ) else { return nil }
        for buffer in buffers {
            guard (try? file.write(from: buffer)) != nil else { return nil }
        }
        file.close()
        return try? Data(contentsOf: url)
    }

    /// The PCM frames that the encoder consumes. Quantize a shared boundary
    /// once in both adjacent clips so floating-point times cannot lose a frame.
    func audio(from start: Double, through end: Double) -> [AVAudioPCMBuffer] {
        let buffers = lock.withLock { self.buffers }
        let first = (start * format.sampleRate).rounded()
        let last = (end * format.sampleRate).rounded()
        var frames = 0.0
        var result: [AVAudioPCMBuffer] = []
        for buffer in buffers {
            let next = frames + Double(buffer.frameLength)
            defer { frames = next }
            guard next > first, frames < last else { continue }
            let offset = Int(max(0, first - frames))
            let count = Int(min(Double(buffer.frameLength), last - frames)) - offset
            guard count > 0 else { continue }
            if offset == 0, count == Int(buffer.frameLength) {
                result.append(buffer)
            } else {
                guard let clipped = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return [] }
                clipped.frameLength = AVAudioFrameCount(count)
                let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
                let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let destination = UnsafeMutableAudioBufferListPointer(clipped.mutableAudioBufferList)
                for (source, destination) in zip(source, destination) {
                    guard let input = source.mData, let output = destination.mData else { return [] }
                    memcpy(output, input.advanced(by: offset * bytesPerFrame), count * bytesPerFrame)
                }
                result.append(clipped)
            }
        }
        return result
    }
}
