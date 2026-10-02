import Foundation
import Combine
@preconcurrency import WatchConnectivity
import CommaCore

@MainActor
final class WatchPairingBridge: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var pairing = false
    @Published private(set) var error: String?
    private weak var store: CommaStore?
    private let parentKey = "comma.watch-parent-session"

    func configure(store: CommaStore) {
        self.store = store
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func pair() async {
        guard let store, !pairing else { return }
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            error = "Open Comma on your paired iPhone, then try again."
            return
        }
        pairing = true
        error = nil
        defer { pairing = false }
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                WCSession.default.sendMessageData(Data("pair".utf8), replyHandler: {
                    continuation.resume(returning: $0)
                }, errorHandler: { continuation.resume(throwing: $0) })
            }
            guard data.count <= 8192 else { throw CommaError.responseTooLarge }
            let value = try JSONDecoder().decode(WatchPairingEnvelope.self, from: data)
            if let message = value.error { throw CommaError.invalidInput(message) }
            guard let grant = value.pairing, let parent = value.parentSessionID,
                  value.baseURL == store.configuration.baseURL.absoluteString else { throw CommaError.originMismatch }
            let result = try await store.client.exchangeWatchPairing(grant)
            UserDefaults.standard.set(parent, forKey: parentKey)
            await store.signedIn(result)
        } catch { self.error = error.localizedDescription }
    }

    func applyLatestContext() async {
        guard WCSession.isSupported() else { return }
        let context = WCSession.default.receivedApplicationContext
        await receive(parent: context["parent_session_id"] as? String,
                      authenticated: context["authenticated"] as? Bool)
    }

    private func receive(parent: String?, authenticated: Bool?) async {
        guard authenticated == false, parent == UserDefaults.standard.string(forKey: parentKey) else { return }
        await store?.invalidateLocalSession()
        UserDefaults.standard.removeObject(forKey: parentKey)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        Task { @MainActor [weak self] in await self?.applyLatestContext() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let parent = applicationContext["parent_session_id"] as? String
        let authenticated = applicationContext["authenticated"] as? Bool
        Task { @MainActor [weak self] in await self?.receive(parent: parent, authenticated: authenticated) }
    }
}
