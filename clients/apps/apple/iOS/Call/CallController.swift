@preconcurrency import ActivityKit
@preconcurrency import AVFoundation
import CommaCore
import Foundation
import Observation
import os

/// The only owner of a voice call: its protocol session, audio and Live Activity. Views only show it.
/// Leaving the chat, minimizing the call page or backgrounding the app never ends the call
/// (`UIBackgroundModes: audio` keeps the process running while the microphone is open).
@MainActor @Observable
final class CallController {
    /// Why a call that never started, or ended, says what it says.
    enum Notice: Equatable { case microphone, output }

    /// Whether the signed-in Workspace can take in-app calls. The Call button shows only then, or during a call.
    private(set) var available = false
    private(set) var phase: VoiceCallPhase = .idle
    private(set) var result: VoiceCallResult?
    private(set) var muted = false
    private(set) var speaking = false
    /// The agent's voice level as it plays, 0 to 1; drives the ripples around the avatar.
    private(set) var agentLevel: Double = 0
    private(set) var output: CallOutput = .speaker
    /// A headset or Bluetooth device can take the call, so output is chosen with the system route picker.
    private(set) var externalOutputs = false
    private(set) var connectedAt: Date?
    private(set) var endedAt: Date?
    private(set) var notice: Notice?
    /// The user pressed End; shown as ending before the session reports it.
    private(set) var endingRequested = false
    /// The full page; false shows the floating bubble. The call is the same either way.
    var expanded = false

    /// A call holds, or is acquiring, the microphone and a connection.
    var busy: Bool { phase.isLive || starting }
    /// A call is on screen: in progress, or finished and still showing its result.
    private(set) var shown = false

    /// A finished call's last words stay up this long, then the call UI and Live Activity leave together.
    static let endedDwell: TimeInterval = 1.5
    static let failedDwell: TimeInterval = 4

    @ObservationIgnored private let store: CommaStore
    @ObservationIgnored private let credentials: CoreVoiceCredentials
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var call: (id: Int, session: VoiceSession, audio: CallAudio)?
    @ObservationIgnored private var callID = 0
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var activity: Activity<CallActivityAttributes>?
    @ObservationIgnored private var hide: Task<Void, Never>?
    @ObservationIgnored private var availabilityKey: String?

    init(store: CommaStore, preferences: UserDefaults = .standard) {
        self.store = store
        self.preferences = preferences
        credentials = CoreVoiceCredentials(core: store.core,
                                           store: KeychainVoiceKeyStore(account: store.configuration.baseURL.absoluteString)) { [weak store] in
            await MainActor.run {
                guard let store, let session = store.session, let workspace = store.workspace else { return nil }
                return VoiceAccess(accountID: session.user.id, sessionID: session.id, workspaceID: workspace.id)
            }
        }
        EndCallIntent.hangUp = { [weak self] in self?.hangUp() }
        ToggleCallMuteIntent.toggleMute = { [weak self] in
            guard let self, self.busy, !self.endingRequested else { return }
            await self.setMuted(!self.muted)
        }
        // A Live Activity outlives a process that was killed mid-call; no call survives that.
        for leftover in Activity<CallActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    #if DEBUG
    /// A connected call for the offline UI fixture; no microphone, network or Live Activity.
    func previewFloatingCall() {
        phase = .connected
        connectedAt = Date().addingTimeInterval(-6)
        shown = true
        expanded = false
    }
    #endif

    // MARK: Commands

    /// From a visible screen: asks for the microphone if needed. A tap during a call opens it instead.
    func start() async {
        guard !busy else { expanded = true; return }
        guard let session = store.session, let workspace = store.workspace else { return }
        starting = true
        defer { starting = false }
        hide?.cancel()
        reset()
        expanded = true
        shown = true
        phase = .preparing
        guard await Self.microphoneGranted() else {
            finish(id: callID, result: .interrupted, notice: .microphone)
            return
        }
        guard phase == .preparing, store.session?.id == session.id else { return }
        callID += 1
        let id = callID
        let audio = CallAudio()
        let voice: VoiceSession
        do {
            voice = try VoiceSession(credentials: credentials.source(), sink: audio,
                                     version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
            try audio.start()
        } catch {
            Self.log.error("Call could not start audio: code=\((error as NSError).code, privacy: .public)")
            audio.stop()
            finish(id: id, result: .interrupted)
            return
        }
        voice.onDiagnostic = { cause in Self.log.info("Voice session: \(cause, privacy: .public)") }
        voice.onState = { [weak self] state in Task { @MainActor in self?.apply(state, id: id) } }
        audio.onFrame = { [weak voice] frame in voice?.offerAudio(frame) }
        audio.onSpeaking = { [weak self] value in Task { @MainActor in if self?.call?.id == id { self?.speaking = value } } }
        audio.onLevel = { [weak self] value in
            Task { @MainActor in
                // Small changes are not worth a redraw.
                guard let self, self.call?.id == id, abs(value - self.agentLevel) > 0.02 || (value == 0) != (self.agentLevel == 0) else { return }
                self.agentLevel = value
            }
        }
        audio.onOutput = { [weak self] value in Task { @MainActor in self?.routeChanged(value, id: id) } }
        audio.onFailure = { [weak self] cause in
            Self.log.info("Call audio: \(cause, privacy: .public)")
            Task { @MainActor in self?.interrupt(id: id) }
        }
        call = (id, voice, audio)
        #if DEBUG
        // Playback receipts against what was played, every two seconds, while the call lasts.
        Task { [weak self, weak voice, weak audio] in
            while let voice, let audio, self?.call?.id == id {
                let stats = await Task.detached { voice.snapshot().stats }.value
                Self.log.info("Call progress: \(audio.progress, privacy: .public) sent=\(stats.sentFrames, privacy: .public) stalled=\(stats.stalledFrames, privacy: .public) mic_dropped=\(stats.droppedMicrophoneFrames, privacy: .public) marks_in=\(stats.receivedMarks, privacy: .public) marks_ack=\(stats.acknowledgedMarks, privacy: .public)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        #endif
        routeChanged(audio.output, id: id)
        startActivity(accountID: session.user.id, workspaceID: workspace.id)
        voice.start()
    }

    func hangUp() {
        guard busy else { return }
        endingRequested = true
        if let call { call.session.hangUp() } else { finish(id: callID, result: .ended) }
        updateActivity()
    }

    func setMuted(_ value: Bool) async {
        guard let call else { return }
        muted = value
        call.session.setMuted(value)
        if let activity { await activity.update(activityContent) }
    }

    func setSpeaker(_ on: Bool) {
        guard let call else { return }
        if !call.audio.setSpeaker(on) { notice = .output }
    }

    /// The finished call's result has been read; the call UI goes now instead of after its dwell.
    func dismiss() {
        guard !busy else { return }
        hide?.cancel()
        shown = false
        expanded = false
    }

    // MARK: Account

    /// Before sign-out, while the session can still delete this device's voice key.
    func signOut() async {
        endNow()
        await credentials.retire()
        available = false
        availabilityKey = nil
    }

    /// The session ended elsewhere: no call continues, and its key can no longer be deleted from here.
    func sessionEnded() {
        endNow()
        available = false
        availabilityKey = nil
        Task { await credentials.forget() }
    }

    /// Reads, once per account and Workspace in this process, whether calls are possible. The last answer for
    /// the same account and Workspace shows at once, so the Call button does not appear seconds after launch.
    func refreshAvailability() async {
        guard let session = store.session, let workspace = store.workspace else { available = false; return }
        let key = session.user.id + ":" + workspace.id
        if preferences.string(forKey: Self.availabilityKeyName) == key {
            available = preferences.bool(forKey: Self.availabilityValueName)
        } else {
            available = false
        }
        guard availabilityKey != key else { return }
        guard let callsAvailable = await store.voiceCallsAvailable(workspace: workspace),
              store.session?.id == session.id, store.workspace?.id == workspace.id else { return }
        availabilityKey = key
        available = callsAvailable
        preferences.set(key, forKey: Self.availabilityKeyName)
        preferences.set(callsAvailable, forKey: Self.availabilityValueName)
    }

    private static let availabilityKeyName = "comma.voice.availability.key"
    private static let availabilityValueName = "comma.voice.availability.ready"

    // MARK: Call state

    private func apply(_ state: VoiceCallState, id: Int) {
        guard call?.id == id else { return }
        Self.log.info("Call phase: \(state.phase.rawValue, privacy: .public) started=\(state.startedByServer, privacy: .public) audio=\(state.receivedAudio, privacy: .public)")
        if state.phase == .connected, connectedAt == nil { connectedAt = Date() }
        if state.phase == .ended || state.phase == .failed {
            finish(id: id, result: state.result ?? .ended)
            return
        }
        let changed = phase != state.phase
        phase = state.phase
        if changed { updateActivity() }
    }

    private func routeChanged(_ value: CallOutput, id: Int) {
        guard call?.id == id else { return }
        output = value
        externalOutputs = CallAudio.hasExternalRoute
    }

    private func interrupt(id: Int) {
        guard call?.id == id else { return }
        finish(id: id, result: .interrupted)
    }

    /// Releases the microphone and connection first, then shows the result until its dwell ends.
    private func finish(id: Int, result: VoiceCallResult, notice: Notice? = nil) {
        guard id == callID, phase != .ended, phase != .failed else { return }
        Self.log.info("Call finished: result=\(result.rawValue, privacy: .public) phase=\(self.phase.rawValue, privacy: .public)")
        if let call, call.id == id {
            call.session.close()
            call.audio.stop()
            self.call = nil
        }
        phase = result == .ended ? .ended : .failed
        self.result = result
        if let notice { self.notice = notice }
        endedAt = Date()
        speaking = false
        agentLevel = 0
        endingRequested = false
        let dwell = phase == .failed ? Self.failedDwell : Self.endedDwell
        endActivity(dwell: dwell)
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.busy else { return }
            self.shown = false
            self.expanded = false
        }
    }

    /// Sign-out or a lost session: no protocol goodbye and no dwell.
    private func endNow() {
        hide?.cancel()
        if let call {
            call.session.close()
            call.audio.stop()
            self.call = nil
        }
        let wasLive = phase.isLive
        if wasLive { phase = .ended; result = .ended }
        endActivity(dwell: 0)
        shown = false
        expanded = false
    }

    private func reset() {
        phase = .idle; result = nil; muted = false; speaking = false; agentLevel = 0; connectedAt = nil; endedAt = nil
        notice = nil; endingRequested = false
    }

    private static func microphoneGranted() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .undetermined: await AVAudioApplication.requestRecordPermission()
        default: false
        }
    }

    // MARK: Live Activity

    private var activityState: CallActivityAttributes.ContentState {
        let shownPhase: CallActivityAttributes.Phase = switch phase {
        case .connected: endingRequested ? .ending : .connected
        case .ending: .ending
        case .ended: .ended
        case .failed: .failed
        default: endingRequested ? .ending : .calling
        }
        return .init(phase: shownPhase, connectedAt: connectedAt, endedAt: endedAt, muted: muted)
    }

    /// Above the Task activity, which keeps the default score: the Dynamic Island and the top of the Lock Screen
    /// show the most relevant activity, and a live call matters more than the Task list.
    private static let activityRelevance = 100.0
    nonisolated private static let log = Logger(subsystem: "surf.comma.ios", category: "voice-call")

    private var activityContent: ActivityContent<CallActivityAttributes.ContentState> {
        ActivityContent(state: activityState, staleDate: nil, relevanceScore: Self.activityRelevance)
    }

    private func startActivity(accountID: String, workspaceID: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.log.info("Live Activities are disabled; the call has none")
            return
        }
        do {
            activity = try Activity.request(attributes: CallActivityAttributes(accountID: accountID, workspaceID: workspaceID),
                                            content: activityContent, pushType: nil)
        } catch {
            Self.log.error("Call Live Activity request failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func updateActivity() {
        guard let activity else { return }
        let content = activityContent
        Task { await activity.update(content) }
    }

    private func endActivity(dwell: TimeInterval) {
        guard let activity else { return }
        self.activity = nil
        let content = activityContent
        let policy: ActivityUIDismissalPolicy = dwell > 0 ? .after(Date().addingTimeInterval(dwell)) : .immediate
        Task { await activity.end(content, dismissalPolicy: policy) }
    }
}
