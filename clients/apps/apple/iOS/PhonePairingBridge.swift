import Foundation
@preconcurrency import WatchConnectivity
import CommaCore

@MainActor
final class PhonePairingBridge: NSObject, WCSessionDelegate {
    static let shared = PhonePairingBridge()
    private weak var store: CommaStore?
    private var previousSessionID: String?

    func configure(store: CommaStore) {
        self.store = store
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
            guard messageData == Data("pair".utf8), let store = self?.store,
                  let parent = store.session else {
                Self.reply(.init(pairing: nil, baseURL: nil, parentSessionID: nil,
                                 error: "Sign in to Comma on your iPhone first."), using: reply)
                return
            }
            do {
                let grant = try await store.client.createWatchPairing()
                guard store.session?.id == parent.id else { throw CommaError.staleSession }
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
