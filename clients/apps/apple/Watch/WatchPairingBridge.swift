import Foundation
import Synchronization
import Combine
@preconcurrency import WatchConnectivity
import CommaCore

@MainActor
final class WatchPairingBridge: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var pairing = false
    @Published private(set) var error: String?
    /// This watch was signed in through the iPhone's current Session. When it is signed out on its own (the
    /// Session revoked or expired, or signed out on the watch), connecting again waits for the reader, so a
    /// revoked watch does not sign itself back in. The iPhone signing out clears it.
    @Published private(set) var pairedBefore = UserDefaults.standard.string(forKey: WatchPairingBridge.parentKey) != nil
    private weak var store: CommaStore?
    private static let parentKey = "comma.watch-parent-session"

    func configure(store: CommaStore) {
        self.store = store
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Pairing starts by itself whenever the watch is signed out, has not been signed in through the iPhone's
    /// current Session (`pairedBefore`), and the iPhone is reachable; WatchConnectivity wakes the iPhone app in
    /// the background. `automatic` attempts wait quietly for the iPhone; only a request the reader made reports
    /// that it is out of reach.
    func pair(automatic: Bool = false) async {
        guard let store, store.session == nil, !pairing, !(automatic && pairedBefore) else { return }
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            if !automatic { error = "Bring your iPhone nearby, then try again." }
            return
        }
        pairing = true
        error = nil
        defer { pairing = false }
        do {
            let data = try await Self.requestPairing()
            guard data.count <= 8192 else { throw CommaError.responseTooLarge }
            let value = try JSONDecoder().decode(WatchPairingEnvelope.self, from: data)
            if let message = value.error { throw CommaError.invalidInput(message) }
            guard let grant = value.pairing, let parent = value.parentSessionID,
                  value.baseURL == store.configuration.baseURL.absoluteString else { throw CommaError.originMismatch }
            let result = try await store.client.exchangeWatchPairing(grant)
            UserDefaults.standard.set(parent, forKey: Self.parentKey)
            pairedBefore = true
            await store.signedIn(result)
        } catch { self.error = error.localizedDescription }
    }

    /// WatchConnectivity calls both handlers on its own queue. Closures formed in this nonisolated context carry
    /// no main-actor isolation, so Swift 6's runtime isolation check cannot trap when they run there.
    private nonisolated static func requestPairing() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let reply = PairingReply(continuation)
            WCSession.default.sendMessageData(Data("pair".utf8), replyHandler: { reply.finish(.success($0)) },
                                              errorHandler: { reply.finish(.failure($0)) })
            // An iPhone that never answers must not leave the watch waiting; the reader can try again.
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                reply.finish(.failure(CommaError.invalidInput(
                    "Your iPhone didn't respond. Open Comma on your iPhone, then try again.")))
            }
        }
    }

    func applyLatestContext() async {
        guard WCSession.isSupported() else { return }
        let context = WCSession.default.receivedApplicationContext
        await receive(parent: context["parent_session_id"] as? String,
                      authenticated: context["authenticated"] as? Bool)
    }

    private func receive(parent: String?, authenticated: Bool?) async {
        guard authenticated == false, parent == UserDefaults.standard.string(forKey: Self.parentKey) else { return }
        await store?.invalidateLocalSession()
        UserDefaults.standard.removeObject(forKey: Self.parentKey)
        pairedBefore = false
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        Task { @MainActor [weak self] in
            await self?.applyLatestContext()
            await self?.pair(automatic: true)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor [weak self] in await self?.pair(automatic: true) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let parent = applicationContext["parent_session_id"] as? String
        let authenticated = applicationContext["authenticated"] as? Bool
        Task { @MainActor [weak self] in await self?.receive(parent: parent, authenticated: authenticated) }
    }
}

/// Resumes the pairing request once, with the iPhone's reply or the timeout, whichever comes first.
private final class PairingReply: Sendable {
    private let continuation: Mutex<CheckedContinuation<Data, any Error>?>
    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = Mutex(continuation) }
    func finish(_ result: Result<Data, any Error>) {
        continuation.withLock { value in
            value?.resume(with: result)
            value = nil
        }
    }
}
