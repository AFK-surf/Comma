import AVFoundation
import SwiftUI

/// The composer's microphone: it records what the member says, shows its level as it goes, and has the server's ASR
/// write it out (`recordings.transcribe` with the `dictation` purpose, as the desktop's Quick Chat does). The words
/// go into the draft at the caret; a failure says why in a toast and leaves the draft as it was.
///
/// Bounds: one recording at a time, at most `maxSeconds` long (it stops and transcribes then), and one transcription
/// in flight. The core gives a dictation up after 10 s, so the recording stays short.
@MainActor @Observable
final class DictationModel {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    private(set) var phase: Phase = .idle

    nonisolated static let maxSeconds: TimeInterval = 60
    private static let toastID = "composer.dictation"

    @ObservationIgnored private var recorder: AVAudioRecorder?
    /// Watches for the recording to end by itself: `maxSeconds` reached, or the system took the microphone.
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var file: URL?
    /// Where the words go: the draft of the conversation the recording started in.
    @ObservationIgnored private var insert: (@MainActor (String) -> Void)?
    /// The last start. The next one waits for it, so `audio` runs a dropped start's stop before the new start.
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// The system's permission prompt is up. Nothing the composer does then ends the recording: the prompt itself
    /// cancels a held touch and makes the scene inactive.
    @ObservationIgnored private var asking = false
    /// The recording was ended while the recorder was starting: it ends as soon as the recorder is up.
    @ObservationIgnored private var stopWhenStarted = false

    var busy: Bool { phase != .idle }

    /// The microphone button: starts a recording, or ends one and transcribes it into `insert`.
    func toggle(store: CommaStore, insert: @escaping @MainActor (String) -> Void) {
        switch phase {
        case .idle: start(store: store, insert: insert)
        case .recording: finish(store: store)
        case .transcribing: break
        }
    }

    /// The composer went to another conversation or away: a recording is dropped, and a transcription's words go
    /// nowhere.
    func cancel() {
        work?.cancel()
        work = nil
        stopRecorder()
        discardFile()
        phase = .idle
    }

    /// The microphone's level now, 0...1, which the waveform reads each frame; 0 when not recording. It is read on
    /// demand rather than published, so the level never re-renders SwiftUI.
    func sampleLevel() -> CGFloat {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        return Self.level(decibels: recorder.averagePower(forChannel: 0))
    }

    private func start(store: CommaStore, insert: @escaping @MainActor (String) -> Void) {
        self.insert = insert
        phase = .recording
        asking = AVAudioApplication.shared.recordPermission == .undetermined
        stopWhenStarted = false
        let previous = starting
        let task = Task { [weak self] in
            await previous?.value
            let allowed = await AVAudioApplication.requestRecordPermission()
            self?.asking = false
            guard allowed else {
                self?.fail(store, String(localized: "Allow microphone access in Settings to dictate a message."),
                           openSettings: true)
                return
            }
            guard self?.phase == .recording, !Task.isCancelled else { return }
            let started: Result<Recording, DictationError> = await withCheckedContinuation { done in
                Self.audio.async { done.resume(returning: Result { try Self.record() }.mapError { $0 as? DictationError
                    ?? DictationError(message: String(localized: "The microphone could not start. Try again.")) }) }
            }
            switch started {
            case .failure(let error):
                guard !Task.isCancelled else { return }
                self?.fail(store, error.message)
            case .success(let recording):
                // Ended or dropped while the microphone started: nothing of it is kept.
                guard let self, !Task.isCancelled, self.phase == .recording else { return Self.stop(recording, discard: true) }
                self.recorder = recording.recorder
                self.file = recording.file
                if self.stopWhenStarted { self.finish(store: store) } else { self.watch(store: store) }
            }
        }
        starting = task
        work = task
    }

    /// Starting the audio session and the recorder takes most of a second; on `audio` it holds up no frame.
    /// Stopping goes the same queue, and a start waits for the one before it, so a stop always ends before the next
    /// start begins.
    nonisolated private static let audio = DispatchQueue(label: "surf.comma.dictation.audio", qos: .userInitiated)

    private struct Recording: @unchecked Sendable {
        let recorder: AVAudioRecorder
        let file: URL
    }

    nonisolated private static func record() throws -> Recording {
        let session = AVAudioSession.sharedInstance()
        // A voice call holds the microphone; dictating would take its audio session from it.
        guard session.mode != .voiceChat else {
            throw DictationError(message: String(localized: "You can't dictate during a voice call."))
        }
        let bluetooth: AVAudioSession.CategoryOptions = if #available(iOS 26, *) { .allowBluetoothHFP } else { .allowBluetooth }
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, bluetooth])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).m4a")
        let recorder = try Recorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: maxSeconds) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw DictationError(message: String(localized: "The microphone could not start. Try again."))
        }
        return Recording(recorder: recorder, file: url)
    }

    /// Stops a recording and gives the audio session back, on `audio`; `discard` also deletes its file.
    nonisolated private static func stop(_ recording: Recording, discard: Bool) {
        audio.async {
            recording.recorder.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            if discard { try? FileManager.default.removeItem(at: recording.file) }
        }
    }

    private func watch(store: CommaStore) {
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let recorder = self.recorder else { return }
                // Ended by itself: transcribe what there is.
                if !recorder.isRecording { return self.finish(store: store) }
            }
        }
    }

    private func finish(store: CommaStore) {
        guard phase == .recording, !asking else { return }
        guard let url = file else {
            stopWhenStarted = true
            return
        }
        stopRecorder()
        phase = .transcribing
        work?.cancel()
        work = Task { [weak self] in
            // The recorder writes the file out as it stops, which happens on `audio`: read it after that.
            let audio: Data? = await withCheckedContinuation { done in
                Self.audio.async { done.resume(returning: try? Data(contentsOf: url)) }
            }
            guard !Task.isCancelled else { return }
            guard let audio, !audio.isEmpty else {
                self?.fail(store, String(localized: "Nothing was recorded. Try again."))
                return
            }
            do {
                let answer = try await store.core.call("recordings.transcribe", ["audio": CoreBytes.json(audio), "purpose": "dictation"])
                guard let self, !Task.isCancelled else { return }
                let words = ((answer.value as? NSDictionary)?["transcript"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !words.isEmpty else {
                    self.fail(store, String(localized: "No speech was recognized. Try again."))
                    return
                }
                self.insert?(words)
                self.done()
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(store, String(localized: "Your recording could not be transcribed. Try again."))
            }
        }
    }

    private func fail(_ store: CommaStore, _ message: String, openSettings: Bool = false) {
        done()
        let action = openSettings ? Toast.Action(title: String(localized: "Settings")) {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } : nil
        store.toasts.show(Toast(id: Self.toastID, intent: .error, message: message, action: action, answersMember: true))
    }

    private func done() {
        stopRecorder()
        discardFile()
        work = nil
        insert = nil
        phase = .idle
    }

    private func stopRecorder() {
        watching?.cancel()
        watching = nil
        guard let recorder, let file else { return }
        self.recorder = nil
        Self.stop(Recording(recorder: recorder, file: file), discard: false)
    }

    private func discardFile() {
        // After the recorder's stop, which is queued on `audio` ahead of this.
        if let file { Self.audio.async { try? FileManager.default.removeItem(at: file) } }
        file = nil
    }

    /// A meter's average power (-160...0 dBFS) as 0...1: speech sits around -40 to -10 dB, so the bottom 50 dB of
    /// silence reads as nothing.
    private static func level(decibels: Float) -> CGFloat {
        let floor: Float = -50
        guard decibels > floor else { return 0 }
        return CGFloat(min(1, (decibels - floor) / -floor))
    }
}

#if GESTURE_FIXTURE
private typealias Recorder = FixtureRecorder
#else
private typealias Recorder = AVAudioRecorder
#endif

private struct DictationError: Error, Sendable {
    let message: String
}
