import Foundation

/// An Agent's request to the person in a conversation, as the client core's `agentRequests` topic reads it (a
/// Capability Request). The server owns its status and outcome: the first ending wins, and every device shows it.
/// Only connecting an account (`oauth_authorization`) has a card so far; its success is the provider's verified
/// callback, so the person here opens the provider's page or declines.
struct AgentRequest: Sendable, Equatable, Identifiable {
    enum Status: String, Sendable {
        case pending, completed
        /// Its deadline passed with no decision.
        case expired
        /// The Agent withdrew it.
        case cancelled
        case failed
    }

    enum Outcome: String, Sendable { case connected, declined }

    let id: String
    let status: Status
    /// How a completed request ended.
    let outcome: Outcome?
    /// Unix milliseconds; nil for no deadline.
    let expiresAt: Double?
    let createdAt: Double?
    /// The person's message the Agent's turn served: the card sits under the reply to it.
    let sourceMessageID: String?
    let provider: String
    /// Why the Agent asks, in its words.
    let reason: String
    /// The page to authorize on, while the request waits (always https).
    let authorizationURL: URL?
    /// The account it connected.
    let account: String?

    /// Nil for a request the app draws no card for.
    init?(_ json: NSDictionary) {
        guard json.string("type") == "oauth_authorization", let id = json.string("id"),
              let status = json.string("status").flatMap(Status.init(rawValue:)),
              let oauth = json.object("oauth"), let provider = oauth.string("provider") else { return nil }
        self.init(id: id, status: status, outcome: json.string("outcome").flatMap(Outcome.init(rawValue:)),
                  expiresAt: json.double("expiresAt"), createdAt: json.double("createdAt"),
                  sourceMessageID: json.string("sourceMessageId"), provider: provider, reason: oauth.text("reason") ?? "",
                  // It opens in the browser: only an https page.
                  authorizationURL: oauth.string("authorizationUrl").flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil },
                  account: oauth.string("account"))
    }

    init(id: String, status: Status, outcome: Outcome? = nil, expiresAt: Double? = nil, createdAt: Double? = nil,
         sourceMessageID: String? = nil, provider: String, reason: String, authorizationURL: URL? = nil, account: String? = nil) {
        self.id = id; self.status = status; self.outcome = outcome; self.expiresAt = expiresAt; self.createdAt = createdAt
        self.sourceMessageID = sourceMessageID; self.provider = provider; self.reason = reason
        self.authorizationURL = authorizationURL; self.account = account
    }

    /// The requests of the core's `agentRequests` value, newest first as it gives them.
    static func list(_ value: Any?) -> [AgentRequest] {
        (value as? NSDictionary)?.objects("requests").compactMap(AgentRequest.init) ?? []
    }

    /// The name the card shows for the provider; others show their id, capitalized.
    var providerName: String {
        switch provider {
        case "github": "GitHub"
        case "google": "Google"
        case "linear": "Linear"
        case "notion": "Notion"
        case "slack": "Slack"
        case "feishu": "Feishu"
        default: provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    /// Waiting for the person at `now` (Unix milliseconds): pending, and its deadline not passed. A deadline that
    /// passed ends the request, though the server settles it only when it is next read.
    func isOpen(at now: Double) -> Bool {
        status == .pending && (expiresAt.map { now < $0 } ?? true)
    }
}

/// Where the request cards go: after the reply that owns each, or on the newest turn.
struct AgentRequestPlacement: Equatable {
    var byMessage: [String: [AgentRequest]] = [:]
    var waiting: [AgentRequest] = []

    /// Places each request after the reply that owns its card: the Agent's first message after the person's message
    /// the request's turn served. A pending request whose reply has not come (the Agent waits on it) goes on the newest
    /// turn. A finished one with no reply among the messages shown (its turn is not loaded) shows nowhere: its receipt
    /// belongs to that turn. Oldest request first within a reply.
    init(requests: [AgentRequest], messages: [ChatItem]) {
        guard !requests.isEmpty else { return }
        var index: [String: Int] = [:]
        for (at, message) in messages.enumerated() { index[message.id] = at }
        func replyAfter(_ source: String?) -> String? {
            guard let source, let start = index[source] else { return nil }
            return messages[(start + 1)...].first { !$0.isUser && $0.actorType != "system" }?.id
        }
        for request in requests.sorted(by: { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }) {
            if let anchor = replyAfter(request.sourceMessageID) {
                byMessage[anchor, default: []].append(request)
            } else if request.status == .pending {
                waiting.append(request)
            }
        }
    }

    init() {}
}
