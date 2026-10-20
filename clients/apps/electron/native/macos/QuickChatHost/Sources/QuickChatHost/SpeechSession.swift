import AVFoundation
import Foundation
import QuickChatCore
import Speech

/// Where Quick Chat's words come from while it listens.
@MainActor
protocol TranscriptSource: AnyObject {
    /// The whole text so far, each time it changes.
    var onText: ((String) -> Void)? { get set }
    /// The voice's loudness, 0…1, with each audio buffer (about ten a second).
    var onLevel: ((CGFloat) -> Void)? { get set }
    /// True while macOS downloads the speech model for the language.
    var onPreparing: ((Bool) -> Void)? { get set }
    var onFailure: ((SpeechFailure) -> Void)? { get set }
    /// The text as shown.
    var text: String { get }
    /// The text the words continue: a draft kept from an earlier Quick Chat, or edited words.
    var draft: String { get }
    /// Segmented speech sends text, so it needs no whole-recording payload.
    var audio: Data? { get }
    func start()
    /// Cancel: stops listening; nothing is sent.
    func stop()
    /// Enter: stops listening and returns the text to send.
    func finish() async -> String
    /// After `finish`: wait for outstanding clips and the tail, keeping local
    /// words for failed clips. A send waits for admission and retries failed
    /// background clips once. Nil if this source was cancelled.
    func serverWords(waitForSlot: Bool) async -> String?
}

enum SpeechFailure: Error {
    case microphoneDenied
    case unavailable
}

/// Live device words with server corrections for adjacent clips of at most
/// 60 seconds. Natural pauses and elapsed audio close clips. Enter only waits
/// for unfinished clips; successfully transcribed audio is not uploaded again.
@MainActor
final class SpeechSession: TranscriptSource {
    var onText: ((String) -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    var onPreparing: ((Bool) -> Void)?
    var onFailure: ((SpeechFailure) -> Void)?

    let draft: String
    private(set) var audio: Data?
    private var speech: ShownSpeech
    private var recording: Recording?
    private let engine = AVAudioEngine()
    private var inputs: [AsyncStream<AnalyzerInput>.Continuation] = []
    private var analyzers: [SpeechAnalyzer] = []
    private var exact = ExactSpeech(writesCJK: [])
    /// The last pause both analyzers have finalized, in seconds of audio:
    /// the words shown are exact up to it.
    private var exactThrough: Double?
    private var readers: [Task<Void, Never>] = []
    private var work: Task<Void, Never>?
    private var stopped = false
    /// The server's words for M4A audio; nil when it could not transcribe it.
    private let transcribe: @MainActor (Data, Bool) async -> String?
    private var cancelled = false
    private var finishing: Task<String, Never>?
    private var heardThrough = 0.0
    private var finalizedThrough: [Double] = []
    private var checkpointThrough = 0.0
    private var checkpointWork: Task<Void, Never>?
    private let encodeAudio: ClipTranscriptions.Encode?
    private let finalizeInput: (@MainActor () async -> Bool)?
    private var clips: ClipTranscriptions!
    private var localFinalized = false

    init(
        draft: String,
        transcribe: @escaping @MainActor (Data, Bool) async -> String?,
        writesCJK: [Bool] = [],
        encodeAudio: ClipTranscriptions.Encode? = nil,
        finalizeInput: (@MainActor () async -> Bool)? = nil
    ) {
        self.draft = draft
        self.transcribe = transcribe
        self.encodeAudio = encodeAudio
        self.finalizeInput = finalizeInput
        exact = ExactSpeech(writesCJK: writesCJK)
        finalizedThrough = writesCJK.map { _ in 0 }
        speech = ShownSpeech(draft: draft)
        clips = ClipTranscriptions(
            encode: { [weak self] clip in
                guard let self, !cancelled else { return nil }
                if let encodeAudio { return await encodeAudio(clip) }
                return await recording?.m4a(from: clip.lowerBound, through: clip.upperBound)
            },
            transcribe: transcribe,
            completed: { [weak self] clip, words in
                guard let self, !cancelled else { return }
                if let words { exact.hearFromServer(words, for: clip) }
                settle()
            }
        )
    }

    var text: String { speech.text }

    func start() {
        work = Task { [weak self] in await self?.run() }
    }

    func stop() {
        guard !cancelled else { return }
        cancelled = true
        stopped = true
        stopMicrophone()
        clips.cancel()
        recording = nil
        work?.cancel()
        checkpointWork?.cancel()
        for analyzer in analyzers {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// The draft, then what was said: the exact words once the analyzers
    /// have finalized, or the words as shown when they fail or take
    /// longer than `SpeechSetup.finishLimit`. What was said goes out with its
    /// product names corrected; the draft is kept as it is.
    func finish() async -> String {
        if let finishing { return await finishing.value }
        let task = Task { await finishedSpeech() }
        finishing = task
        return await task.value
    }

    private func finishedSpeech() async -> String {
        guard !stopped else { return SpeechText.joined(draft, speech.spoken) }
        stopped = true
        let shown = speech.spoken
        stopMicrophone()
        heardThrough = max(heardThrough, recording?.duration ?? 0)
        exact.pause(at: heardThrough)
        let finalized: Bool
        if let finalizeInput {
            finalized = await finalizeInput()
        } else {
            finalized = await SpeechSetup.finalize(analyzers)
        }
        work?.cancel()
        checkpointWork?.cancel()
        if finalized {
            for reader in readers { await reader.value }
        }
        localFinalized = finalized
        let said = finalized ? exact.text ?? shown : shown
        return SpeechText.joined(draft, SpeechSetup.sent(said))
    }

    func serverWords(waitForSlot: Bool = false) async -> String? {
        let local = await finish()
        guard await clips.finish(through: heardThrough, waitForSlot: waitForSlot), !cancelled else { return nil }
        // A failed analyzer can lack the tail that is still in the live text.
        // Preserve that complete snapshot instead of replacing it with a prefix.
        guard localFinalized, let words = exact.text else { return local }
        return SpeechText.joined(draft, SpeechSetup.sent(words))
    }

    private func run() async {
        guard await Self.microphoneAllowed() else { return fail(.microphoneDenied) }
        let languages = await SpeechSetup.languages()
        guard let language = languages.first else { return fail(.unavailable) }
        var setup = SpeechSetup(language: language, second: languages.dropFirst().first)
        do {
            // The person's language is required. The second language is used once
            // its model is on the Mac; until then it downloads in the background.
            try await prepareAssets([setup.live, setup.exact[0]])
            if let second = setup.exact.dropFirst().first,
               await AssetInventory.status(forModules: [second]) != .installed {
                Task.detached {
                    try? await AssetInventory.assetInstallationRequest(supporting: [second])?.downloadAndInstall()
                }
                setup = SpeechSetup(language: language)
            }
            guard !stopped,
                  let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: setup.modules)
            else { return }

            // The microphone starts before the models have loaded; its audio waits in the streams.
            let analyzers = setup.analyzers()
            let streams = analyzers.map { _ in AsyncStream.makeStream(of: AnalyzerInput.self) }
            self.analyzers = analyzers
            inputs = streams.map(\.continuation)
            exact = ExactSpeech(writesCJK: setup.languages.map(\.writesCJK))
            finalizedThrough = setup.languages.map { _ in 0 }
            try startMicrophone(format: format, into: inputs)
            for (analyzer, stream) in zip(analyzers, streams) {
                try await analyzer.start(inputSequence: stream.stream)
            }
            // Enter while the models loaded sent the text as shown.
            guard !stopped else { return }
            readers = setup.exact.enumerated().map { index, transcriber in
                Task { [weak self] in
                    do {
                        for try await result in transcriber.results where result.isFinal {
                            self?.receive(
                                ExactSpeech.Segment.segments(result), from: index,
                                finalizedThrough: result.resultsFinalizationTime.seconds
                            )
                        }
                    } catch {}
                }
            }

            for try await result in setup.live.results {
                guard !stopped else { break }
                receiveLive(String(result.text.characters), from: result.range.start.seconds, isFinal: result.isFinal)
            }
        } catch {
            if !stopped { fail(.unavailable) }
        }
    }

    /// The exact words up to the last finalized pause, corrected as Enter
    /// would send them, in place of the live ones. A late result revises them.
    private func settle() {
        guard !stopped, let exactThrough else { return }
        speech.hearExactly(SpeechSetup.sent(exact.text(through: exactThrough) ?? ""), through: exactThrough)
        onText?(speech.text)
    }

    /// Called on the main actor for each recorded buffer. Audio time, not a
    /// wall-clock timer, closes long uninterrupted speech at the length limit.
    func audioProgress(through seconds: Double, paused: Bool) {
        guard !stopped else { return }
        heardThrough = max(heardThrough, seconds)
        while heardThrough - clips.through >= ExactSpeech.clipLength {
            let limit = clips.through + ExactSpeech.clipLength
            checkpoint(at: exact.checkpoint(after: clips.through, through: limit))
        }
        if paused, heardThrough > clips.through { checkpoint(at: heardThrough) }
    }

    func receiveLive(_ text: String, from start: Double, isFinal: Bool) {
        guard !stopped else { return }
        speech.hear(text, from: start, isFinal: isFinal)
        onText?(speech.text)
    }

    /// The same reader entry point is used by injected audio tests.
    func receive(_ segments: [ExactSpeech.Segment], from transcript: Int, finalizedThrough time: Double) {
        guard !cancelled else { return }
        for segment in segments { exact.add(segment, from: transcript) }
        finalizedThrough[transcript] = max(finalizedThrough[transcript], time)
        if let through = finalizedThrough.min(), through >= checkpointThrough {
            exactThrough = checkpointThrough
        }
        settle()
    }

    private func checkpoint(at seconds: Double) {
        exact.pause(at: seconds)
        clips.append(through: seconds)
        checkpointThrough = seconds
        // Finalization publishes results before it returns, but readers can
        // consume them later. receive advances shown text only after both did.
        let previous = checkpointWork
        let analyzers = analyzers
        checkpointWork = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            let time = CMTime(seconds: seconds, preferredTimescale: 48_000)
            for analyzer in analyzers { try? await analyzer.finalize(through: time) }
        }
    }

    /// Downloads a missing model, and reserves an installed one for this app:
    /// macOS reports an installed locale that no app reserved as `.supported`.
    private func prepareAssets(_ modules: [any SpeechModule]) async throws {
        guard await AssetInventory.status(forModules: modules) != .installed else { return }
        onPreparing?(true)
        defer { onPreparing?(false) }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
    }

    private func startMicrophone(
        format: AVAudioFormat,
        into continuations: [AsyncStream<AnalyzerInput>.Continuation]
    ) throws {
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: natural, to: format) else {
            throw SpeechFailure.unavailable
        }
        let recording = Recording(format: format)
        self.recording = recording
        let tap = MicrophoneTap(
            converter: converter, format: format, continuations: continuations, recording: recording,
            progress: { [weak self] level, time, paused in
                Task { @MainActor in
                    self?.onLevel?(level)
                    self?.audioProgress(through: time, paused: paused)
                }
            }
        )
        tap.install(on: node, format: natural)
        engine.prepare()
        try engine.start()
    }

    private func stopMicrophone() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        for input in inputs { input.finish() }
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
/// the analyzers' format and finds the person's pauses in it. It is not on
/// the main actor: AVAudioEngine calls a tap on its own queue, and a tap
/// block formed on the main actor would trap there in Swift 6's isolation check.
private final class MicrophoneTap: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let continuations: [AsyncStream<AnalyzerInput>.Continuation]
    private let recording: Recording
    private let progress: @Sendable (CGFloat, Double, Bool) -> Void
    private var pauses = SpeechPause()
    /// Frames the analyzers have, in their format.
    private var frames: Int64 = 0

    init(
        converter: AVAudioConverter,
        format: AVAudioFormat,
        continuations: [AsyncStream<AnalyzerInput>.Continuation],
        recording: Recording,
        progress: @escaping @Sendable (CGFloat, Double, Bool) -> Void
    ) {
        self.converter = converter
        self.format = format
        self.continuations = continuations
        self.recording = recording
        self.progress = progress
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
        guard status != .error, converted.frameLength > 0 else { return }
        // Every analyzer reads the same buffer; none writes to it.
        for continuation in continuations { continuation.yield(AnalyzerInput(buffer: converted)) }
        recording.write(converted)
        frames += Int64(converted.frameLength)
        let paused = pauses.hear(decibels: decibels, seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
        progress(level, Double(frames) / format.sampleRate, paused)
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

/// The audio the analyzers hear, kept in memory while Quick Chat listens
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
