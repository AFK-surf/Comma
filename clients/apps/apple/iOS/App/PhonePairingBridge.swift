import Foundation
@preconcurrency import WatchConnectivity
import CommaCore

@MainActor
final class PhonePairingBridge: NSObject, WCSessionDelegate {
    static let shared = PhonePairingBridge()
    private weak var store: CommaStore?
    private var previousSessionID: String?
    /// Restores the stored Session; a watch request can launch the app in the background before it has.
    private var ready: (() async -> Void)?

    /// Called at launch, background launches included: a watch request is delivered only to an activated
    /// session.
    func configure(store: CommaStore, ready: @escaping () async -> Void) {
        guard self.store !== store else { return }
        self.store = store
        self.ready = ready
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sessionChanged(_ session: CommaSession?) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        if let session { previousSessionID = session.id }
        guard let identity = session?.id ?? previousSessionID else { return }
        try? WCSession.default.updateApplicationContext([
            "parent_session_id": identity,
            "authenticated": session != nil
        ])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        Task { @MainActor [weak self] in self?.sessionChanged(self?.store?.session) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                             replyHandler: @escaping (Data) -> Void) {
        let reply = WatchReply(send: replyHandler)
        Task { @MainActor [weak self] in
            await self?.ready?()
            guard messageData == Data("pair".utf8), let store = self?.store,
                  let parent = store.session else {
                Self.reply(.init(pairing: nil, baseURL: nil, parentSessionID: nil,
                                 error: "Sign in to Comma on your iPhone first."), using: reply)
                return
            }
            do {
                let answer = try await store.core.object("accountSessions.pairWatch")
                guard store.session?.id == parent.id, let id = answer.string("pairingId"), let secret = answer.string("pairingSecret"),
                      let data = try? JSONSerialization.data(withJSONObject: ["pairing_id": id, "pairing_secret": secret,
                                                                               "expires_at": answer.double("expiresAt") ?? 0]) else {
                    throw CommaError.staleSession
                }
                let grant = try JSONDecoder().decode(WatchPairing.self, from: data)
                Self.reply(.init(pairing: grant, baseURL: store.configuration.baseURL.absoluteString,
                                 parentSessionID: parent.id, error: nil), using: reply)
            } catch {
                Self.reply(.init(pairing: nil, baseURL: nil, parentSessionID: nil,
                                 error: error.localizedDescription), using: reply)
            }
        }
    }

    private static func reply(_ value: WatchPairingEnvelope, using reply: WatchReply) {
        if let data = try? JSONEncoder().encode(value) { reply.send(data) }
    }
}
