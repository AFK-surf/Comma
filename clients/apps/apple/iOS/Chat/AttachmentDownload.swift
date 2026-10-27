import Foundation

/// A message attachment the client core downloads to the device (`downloads.start`, followed on the `download` topic),
/// as Android's `MediaFileStore` does: written from the network straight into the core's download directory, so a file
/// of any size opens, and kept there for the next showing.
enum AttachmentDownload {
    /// The `download` topic's value, as far as opening the file needs it.
    struct State: Sendable {
        let status: String
        let path: String?
        let failure: String?
        /// How many start or stop calls the state already answers.
        let asked: Int

        init(_ value: Any?) {
            let json = value as? NSDictionary
            status = json?["status"] as? String ?? "idle"
            path = json?["path"] as? String
            failure = json?["failure"] as? String
            asked = (json?["asked"] as? NSNumber)?.intValue ?? 0
        }
    }

    /**
     * The attachment `source` names (a core `FileSource`) downloaded as `name`: its path under the core's download
     * directory once it is whole. Throws why it could not be downloaded; a cancelled task ends it.
     */
    static func path(core: any CoreAPI, source: [String: Any], name: String) async throws -> String {
        let topic = String(decoding: try JSONSerialization.data(withJSONObject: source, options: .sortedKeys),
                           as: UTF8.self)
        let updates = core.subscribe(["topic": "download", "source": topic], read: State.init)
        let answer = try await core.call("downloads.start", ["source": source, "name": name])
        // A state from before this call (an earlier failure) says nothing of it.
        let asked = ((answer.value as? NSDictionary)?["asked"] as? NSNumber)?.intValue ?? 0
        for await update in updates {
            switch update {
            case .failed(let error):
                throw error
            case .value(let state) where state.asked >= asked:
                if state.status == "ready", let path = state.path { return path }
                if state.status == "failed" {
                    throw CoreError(code: state.failure ?? "unavailable",
                                    message: String(localized: "Couldn’t download this attachment."))
                }
            case .value:
                continue
            }
        }
        throw CancellationError()
    }
}
