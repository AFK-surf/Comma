import Foundation
import CommaCore

struct WatchPairingEnvelope: Codable, Sendable {
    let pairing: WatchPairing?
    let baseURL: String?
    let parentSessionID: String?
    let error: String?
}

// WatchConnectivity invokes reply handlers on its own queue.
struct WatchReply: @unchecked Sendable {
    let send: (Data) -> Void
}
