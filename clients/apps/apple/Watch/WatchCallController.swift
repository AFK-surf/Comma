@preconcurrency import AVFoundation
import CommaCore
import Observation
import Foundation
import os

@MainActor @Observable
final class WatchCallController {
    private(set) var phase: VoiceCallPhase = .idle
    private(set) var result: VoiceCallResult?
    private(set) var muted = false
    private(set) var agentLevel: Double = 0
    private(set) var connectedAt: Date?
    private(set) var microphoneDenied = false
    private(set) var waitingForContext = false
    var presented = false
    @ObservationIgnored private let store: CommaStore
    @ObservationIgnored private let credentials: VoiceKeyCredentials
    @ObservationIgnored private var session: VoiceSession?
    @ObservationIgnored private var audio: CallAudio?
    @ObservationIgnored private var generation = 0
    nonisolated private static let log = Logger(subsystem: "surf.comma.watch", category: "voice-call")
    @ObservationIgnored private let microphonePermission: () async -> Bool

    init(store: CommaStore, microphonePermission: @escaping () async -> Bool = {
        await AVAudioApplication.requestRecordPermission()
    }) {
        self.microphonePermission = microphonePermission
        self.store = store
        credentials = VoiceKeyCredentials(client: store.client,
            store: KeychainVoiceKeyStore(account: store.client.baseURL.absoluteString))

    }

    func presentPendingCall() {
        presented = true
        guard !phase.isLive else { return }
        waitingForContext = true
        phase = .preparing
        result = nil
        microphoneDenied = false
    }

    func startPendingCall() async {
        guard waitingForContext else { return }
        await start()
    }

    func start() async {
        presented = true
        guard !phase.isLive || waitingForContext else { return }
        waitingForContext = false
        guard let account = store.session, let workspace = store.workspace else {
            finish(.unavailable)
            return
        }
        generation += 1
        let attempt = generation
        phase = .preparing
        result = nil
        muted = false
        agentLevel = 0
        connectedAt = nil
        microphoneDenied = false
        let granted = await microphonePermission()
        guard attempt == generation, phase == .preparing,
              store.session?.id == account.id, store.workspace?.id == workspace.id else { return }
        guard granted else { microphoneDenied = true; finish(.interrupted); return }
        do {
            let audio = CallAudio()
            let transport = HTTPVoiceTransport()
            let voice = try VoiceSession(credentials: credentials.source(workspaceID: workspace.id), transport: transport, sink: audio,
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
            voice.onDiagnostic = { cause in
                Self.log.info("Voice session: \(cause, privacy: .public)")
            }
            voice.onState = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.generation == attempt, self.session != nil else { return }
                    if state.phase == .ended || state.phase == .failed {
                        self.finish(state.result ?? .ended)
                    } else {
                        self.phase = state.phase
                        if state.phase == .connected, self.connectedAt == nil {
                            self.connectedAt = Date()
                        }
                    }
                }
            }
            audio.onFrame = { [weak voice] in voice?.offerAudio($0) }
            audio.onLevel = { [weak self] level in
                Task { @MainActor in
                    guard let self, self.generation == attempt, self.session != nil,
                          abs(level - self.agentLevel) > 0.02 || (level == 0) != (self.agentLevel == 0) else { return }
                    self.agentLevel = level
                }
            }
            audio.onFailure = { [weak self] cause in
                Self.log.error("Call audio: \(cause, privacy: .public)")
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    self.finish(.interrupted)
                }
            }
            self.audio = audio
            session = voice
            try audio.start()
            voice.start()
        } catch {
            guard attempt == generation else { return }
            let failure = error as NSError
            Self.log.error("Watch call startup failed stage=audio domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            finish(.interrupted)
        }
    }

    func hangUp() {
        guard phase.isLive else { return }
        if let session { phase = .ending; session.hangUp() }
        else { finish(.ended) }
    }

    func toggleMute() {
        guard let session, phase.isLive, phase != .ending else { return }
        muted.toggle()
        session.setMuted(muted)
    }

    func invalidate() {
        finish(.interrupted)
        presented = false
    }

    func signOut() async {
        invalidate()
        await credentials.revokeStored()
    }

    func sessionEnded() {
        invalidate()
        Task { await credentials.forget() }
    }

    private func finish(_ result: VoiceCallResult) {
        waitingForContext = false
        generation += 1
        session?.close()
        session = nil
        audio?.stop()
        audio = nil
        agentLevel = 0
        self.result = result
        phase = result == .ended ? .ended : .failed
    }
}
