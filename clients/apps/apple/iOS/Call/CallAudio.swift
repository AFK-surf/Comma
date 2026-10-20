@preconcurrency import AVFoundation
import CommaCore
import Foundation
import os

/// Where the call is heard.
enum CallOutput: Equatable, Sendable {
    case phone, speaker, headphones, bluetooth, other

    init(_ port: AVAudioSession.Port?) {
        switch port {
        case .builtInReceiver?: self = .phone
        case .builtInSpeaker?: self = .speaker
        case .headphones?, .usbAudio?, .lineOut?: self = .headphones
        case .bluetoothHFP?, .bluetoothA2DP?, .bluetoothLE?: self = .bluetooth
        default: self = .other
        }
    }
}

/// The call's audio session, microphone and speaker: one voice-processing `AVAudioEngine`, so the
/// agent's voice is cancelled from the microphone. The call protocol lives in `VoiceSession`.
///
/// Microphone frames go to `onFrame` as 20 ms of 24 kHz mono PCM16. The agent's audio is scheduled on
/// one player node; a mark completes when every buffer before it has been played back by the hardware.
final class CallAudio: VoicePlaybackSink, @unchecked Sendable {
    /// The server writes at most ~0.6 s ahead and tolerates playback 8 s behind; this only caps memory.
    private static let maxPendingFrames = 24_000 * 10
    private static let ringbackGap: TimeInterval = 3

    var onFrame: (@Sendable (Data) -> Void)?
    /// The agent's first audio reached the speaker.
    var onPlaybackStarted: (@Sendable () -> Void)?
    /// Whether the agent's audio is playing now.
    var onSpeaking: (@Sendable (Bool) -> Void)?
    /// How loud the agent's voice is as it plays, 0 (silence) to 1, about 23 times a second while the call runs.
    var onLevel: (@Sendable (Double) -> Void)?
    var onOutput: (@Sendable (CallOutput) -> Void)?
    /// The call cannot continue: another call or Siri took the audio, or the audio system failed.
    /// With a fixed diagnostic phrase naming the cause.
    var onFailure: (@Sendable (String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let ringer = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceProtocol.sampleRate,
                                               channels: 1, interleaved: false)!
    private let uplinkFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: VoiceProtocol.sampleRate,
                                             channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var running = false
    private var epoch = 0
    private var scheduled = 0
    private var played = 0
    private var pendingFrames = 0
    private var marks: [(target: Int, callback: @Sendable () -> Void)] = []
    private var reportedPlayback = false
    private var speaking = false
    private var ringing = false
    /// The looping ringback buffer; an engine restart drops what the ringer had scheduled, so it is queued again.
    private var tone: AVAudioPCMBuffer?
    /// Touched only from the input tap's thread. Rebuilt whenever the tap's format changes, as it does when a
    /// Bluetooth headset takes the call.
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var observers: [NSObjectProtocol] = []

    /// Playback accounting for local diagnostics; counts only.
    var progress: String {
        let (epoch, scheduled, played, frames, marks) = lock.withLock { (epoch, scheduled, played, pendingFrames, marks.count) }
        let time = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }.map { String(Int($0.sampleTime)) } ?? "none"
        return "epoch=\(epoch) scheduled=\(scheduled) played=\(played) pending_frames=\(frames) marks=\(marks) "
            + "engine=\(engine.isRunning) player=\(player.isPlaying) player_time=\(time)"
    }

    // MARK: Lifetime

    /// Call after microphone permission is granted. Throws if the audio system refuses the call.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        #if os(watchOS)
        try session.setCategory(.playAndRecord, mode: .voiceChat)
        #else
        let bluetooth: AVAudioSession.CategoryOptions = if #available(iOS 26, *) { .allowBluetoothHFP } else { .allowBluetooth }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [bluetooth])
        try? session.setPreferredIOBufferDuration(0.02)
        #endif
        try session.setActive(true)
        // The earpiece is the voice-chat default; like Android, start out loud unless a headset is in. Routed before
        // the engine starts: a route change on a running engine stops it, and with it the ringback.
        #if !os(watchOS)
        if session.currentRoute.outputs.first?.portType == .builtInReceiver { try? session.overrideOutputAudioPort(.speaker) }
        #endif
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.attach(player)
            engine.attach(ringer)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            let tone = Self.ringbackBuffer()
            self.tone = tone
            engine.connect(ringer, to: engine.mainMixerNode, format: tone?.format ?? playbackFormat)
            try installInputTap()
            // What the player renders, not what arrived: the level follows the voice as it is heard.
            player.installTap(onBus: 0, bufferSize: 1024, format: playbackFormat) { [weak self] buffer, _ in
                self?.measure(buffer)
            }
            // Observed before the engine starts, so a configuration change during startup is not missed.
            observe(session)
            engine.prepare()
            try engine.start()
            player.play()
            lock.withLock { running = true }
            if let tone { startRinging(tone) }
            reportOutput()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        lock.withLock { running = false; ringing = false; marks.removeAll(); epoch += 1 }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        player.removeTap(onBus: 0)
        player.stop(); ringer.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Output

    var output: CallOutput { CallOutput(AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType) }

    /// A headset or Bluetooth device is connected, so there is more to choose than earpiece or speaker.
    static var hasExternalRoute: Bool {
        let session = AVAudioSession.sharedInstance()
        let external: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headsetMic, .headphones, .usbAudio, .carAudio]
        return session.currentRoute.outputs.contains { external.contains($0.portType) }
            || (session.availableInputs ?? []).contains { external.contains($0.portType) }
    }

    /// Between the phone's earpiece and its speaker. Headsets and Bluetooth are chosen with the system route picker.
    #if !os(watchOS)
    func setSpeaker(_ on: Bool) -> Bool {
        let ok = (try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)) != nil
        reportOutput()
        return ok
    }

    #endif

    private func reportOutput() { onOutput?(output) }

    // MARK: Microphone

    /// In the input's current format: a tap whose format no longer matches the hardware stops the engine from starting.
    private func installInputTap() throws {
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else { throw CommaError.invalidInput("Call input is unavailable.") }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: input) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ running }) else { return }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: uplinkFormat)
            converter?.downmix = true
        }
        guard let converter else { return }
        let ratio = uplinkFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: uplinkFormat, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let samples = output.int16ChannelData else { return }
        pending.append(Data(bytes: samples[0], count: Int(output.frameLength) * 2))
        while pending.count >= VoiceProtocol.frameBytes {
            onFrame?(Data(pending.prefix(VoiceProtocol.frameBytes)))
            pending.removeFirst(VoiceProtocol.frameBytes)
        }
    }

    // MARK: Output level

    /// The buffer's loudness in decibels, mapped from -50 dB (0) to -10 dB (1). Touched only from the player tap's thread.
    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        onLevel?(Double(min(max((decibels + 50) / 40, 0), 1)))
    }

    // MARK: VoicePlaybackSink

    func play(_ pcm: Data) throws {
        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for index in 0..<frames {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                channel[index] = Float(sample) / 32_768
            }
        }
        let (epoch, index, becameSpeaking) = try lock.withLock { () throws -> (Int, Int, Bool) in
            guard running else { throw CommaError.invalidInput("Call audio stopped.") }
            guard pendingFrames + frames <= Self.maxPendingFrames else { throw CommaError.invalidInput("Call playback is too far behind.") }
            scheduled += 1
            pendingFrames += frames
            let became = !speaking
            speaking = true
            return (self.epoch, scheduled, became)
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.playedBack(index, frames: frames, epoch: epoch)
        }
        if becameSpeaking { onSpeaking?(true) }
    }

    func mark(_ onPlayed: @escaping @Sendable () -> Void) throws {
        let now = try lock.withLock { () throws -> Bool in
            guard running else { throw CommaError.invalidInput("Call audio stopped.") }
            if scheduled <= played { return true }
            marks.append((scheduled, onPlayed))
            return false
        }
        if now { DispatchQueue.global(qos: .userInitiated).async(execute: onPlayed) }
    }

    func clear() {
        let wasSpeaking = lock.withLock { () -> Bool in
            epoch += 1
            scheduled = 0; played = 0; pendingFrames = 0
            marks.removeAll()
            defer { speaking = false }
            return speaking
        }
        // Outside the lock: stop() may call the dropped buffers' completions on this thread.
        player.stop()
        if lock.withLock({ running }) { player.play() }
        if wasSpeaking { onSpeaking?(false) }
    }

    private func playedBack(_ index: Int, frames: Int, epoch: Int) {
        let (reached, first, quiet) = lock.withLock { () -> ([@Sendable () -> Void], Bool, Bool) in
            guard running, epoch == self.epoch else { return ([], false, false) }
            played = max(played, index)
            pendingFrames = max(0, pendingFrames - frames)
            let reached = marks.filter { $0.target <= played }.map(\.callback)
            marks.removeAll { $0.target <= played }
            let first = !reportedPlayback
            reportedPlayback = true
            let quiet = speaking && played >= scheduled
            if quiet { speaking = false }
            return (reached, first, quiet)
        }
        reached.forEach { $0() }
        if first { stopRinging(); onPlaybackStarted?() }
        if quiet { onSpeaking?(false) }
    }

    // MARK: Ringback

    /// The ringback tone, then three seconds of silence, as one looping buffer.
    private static func ringbackBuffer() -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: "ringback", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let toneFrames = AVAudioFrameCount(file.length)
        let total = toneFrames + AVAudioFrameCount(format.sampleRate * ringbackGap)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        do { try file.read(into: buffer, frameCount: toneFrames) } catch { return nil }
        let channels = Int(format.channelCount)
        if let data = buffer.floatChannelData {
            for channel in 0..<channels { (data[channel] + Int(toneFrames)).update(repeating: 0, count: Int(total - toneFrames)) }
        }
        buffer.frameLength = total
        return buffer
    }

    private func startRinging(_ tone: AVAudioPCMBuffer) {
        let start = lock.withLock { () -> Bool in
            guard !reportedPlayback, !ringing else { return false }
            ringing = true
            return true
        }
        guard start else { return }
        ringer.scheduleBuffer(tone, at: nil, options: .loops)
        ringer.play()
    }

    /// The tone stops once the agent is heard, never on a timer.
    func stopRinging() {
        let stop = lock.withLock { () -> Bool in defer { ringing = false }; return ringing }
        if stop { ringer.stop() }
    }

    // MARK: System events

    private func observe(_ session: AVAudioSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            // A phone call, FaceTime or Siri took the microphone; Comma's call cannot hold on.
            let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt).map(String.init) ?? "none"
            self?.onFailure?("audio_interruption reason=\(reason)")
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            self?.onFailure?("media_services_reset")
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] _ in
            self?.reportOutput()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        })
    }

    private static let log = Logger(subsystem: "surf.comma.ios", category: "voice-call")

    /// A route change can stop the engine; resume it. Audio queued at that moment is lost, so its marks
    /// complete now: the server paces from them and would otherwise see playback stall.
    private func restartAfterConfigurationChange() {
        guard lock.withLock({ running }), !engine.isRunning else { return }
        Self.log.info("Call audio: engine configuration changed; restarting")
        let (dropped, wasSpeaking) = lock.withLock { () -> ([@Sendable () -> Void], Bool) in
            defer { epoch += 1; scheduled = 0; played = 0; pendingFrames = 0; marks.removeAll(); speaking = false }
            return (marks.map(\.callback), speaking)
        }
        player.stop()
        dropped.forEach { $0() }
        if wasSpeaking { onSpeaking?(false) }
        do {
            // The new route may record at another sample rate.
            engine.inputNode.removeTap(onBus: 0)
            try installInputTap()
            try engine.start()
            player.play()
            if lock.withLock({ ringing }), let tone {
                ringer.stop()
                ringer.scheduleBuffer(tone, at: nil, options: .loops)
                ringer.play()
            }
        } catch { onFailure?("engine_restart_failed code=\((error as NSError).code)") }
    }
}
