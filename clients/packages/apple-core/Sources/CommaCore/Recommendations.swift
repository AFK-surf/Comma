import Foundation

/// The workspace's Routines briefing as the phone shows it: a summary, a few cards, and the connected
/// sources they come from. Decoded from `GET /workspaces/:id/recommendations`. Prompt references are
/// resolved here, as the desktop contract does at its API boundary; unknown card templates keep only
/// their server-authored fallback text.
public struct RecommendationFeed: Equatable, Sendable {
    /// `empty`, `fresh`, `refreshing`, `stale` or `error`.
    public let state: String
    public let lastError: String?
    public let sources: [RecommendationSource]
    public let summary: [RecommendationPart]
    public let cards: [RecommendationCard]
    public let generatedAt: Date?
    /// Identifies the snapshot; a new briefing has a new generation.
    public let generation: Int?

    public var isRefreshing: Bool { state == "refreshing" }
    public var hasSnapshot: Bool { generation != nil }
    /// A source is needed before a refresh can generate anything.
    public var canRefresh: Bool { sources.contains(where: \.enabled) }
    /// Sources only the member can repair, by reconnecting them.
    public var sourcesNeedingReconnect: [RecommendationSource] { sources.filter(\.needsReconnect) }
    public var summaryText: String { RecommendationPart.plainText(summary) }

    public init(state: String, lastError: String? = nil, sources: [RecommendationSource] = [], summary: [RecommendationPart] = [],
                cards: [RecommendationCard] = [], generatedAt: Date? = nil, generation: Int? = nil) {
        self.state = state; self.lastError = lastError; self.sources = sources; self.summary = summary
        self.cards = cards; self.generatedAt = generatedAt; self.generation = generation
    }

    public init(envelope: JSONValue) throws {
        guard let root = envelope.object, let state = root["state"]?.string else { throw CommaError.invalidResponse }
        self.state = state
        lastError = root["lastError"]?.string
        sources = (root["settings"]?.object?["sources"]?.array ?? []).prefix(12).compactMap(RecommendationSource.init(json:))
        guard let snapshot = root["snapshot"]?.object else {
            summary = []; cards = []; generatedAt = nil; generation = nil; return
        }
        let prompts = (snapshot["prompts"]?.object ?? [:]).compactMapValues { value -> String? in
            guard let prompt = value.object, let objective = prompt["objective"]?.string else { return nil }
            return prompt["sourceUrl"]?.string.map { objective + "\n\n" + $0 } ?? objective
        }
        summary = RecommendationPart.parts(snapshot["summary"], prompts: prompts)
        generatedAt = snapshot["generatedAt"]?.number.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
        generation = snapshot["generation"]?.number.map { Int($0) }
        cards = (snapshot["cards"]?.array ?? []).prefix(6).compactMap { RecommendationCard(json: $0, prompts: prompts) }
    }

    /// The source a card or chip names: by connection id, else by app id, as on the desktop.
    public func source(_ id: String?) -> RecommendationSource? {
        guard let id else { return nil }
        return sources.first { $0.connectionID == id || $0.appID == id }
    }

    /// The card's single source, which gives it its logo. A card from several sources has none.
    public func source(for card: RecommendationCard) -> RecommendationSource? {
        card.sourceIDs.count == 1 ? source(card.sourceIDs[0]) : nil
    }
}

/// A connected app the briefing reads from.
public struct RecommendationSource: Equatable, Identifiable, Sendable {
    public let connectionID: String
    public let appID: String
    public let appName: String
    public let iconURL: URL?
    public let enabled: Bool
    public let needsReconnect: Bool
    public var id: String { connectionID }

    public init(connectionID: String, appID: String, appName: String, iconURL: URL? = nil, enabled: Bool = true, needsReconnect: Bool = false) {
        self.connectionID = connectionID; self.appID = appID; self.appName = appName
        self.iconURL = iconURL; self.enabled = enabled; self.needsReconnect = needsReconnect
    }

    init?(json: JSONValue) {
        guard let source = json.object, let connection = source["connectionId"]?.string, let app = source["appId"]?.string else { return nil }
        self.init(connectionID: connection, appID: app, appName: source["appName"]?.string ?? app,
                  iconURL: source["iconUrl"]?.string.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil },
                  enabled: source["enabled"]?.bool ?? false, needsReconnect: source["needsReconnect"]?.bool ?? false)
    }

    /// The provider brand key shared with the desktop logo resolver: lower case, letters and digits only.
    public static func brandKey(_ value: String?) -> String? {
        let key = value?.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return key?.isEmpty == false ? key : nil
    }
}

/// One run of briefing prose: text, a source link, or a Task.
public enum RecommendationPart: Equatable, Sendable {
    case text(String)
    case link(label: String, url: URL, sourceID: String?)
    case task(label: String, conversationID: String, sourceID: String?)

    static func parts(_ json: JSONValue?, prompts: [String: String]) -> [RecommendationPart] {
        (json?.array ?? []).prefix(24).compactMap { part -> RecommendationPart? in
            guard let part = part.object else { return nil }
            switch part["kind"]?.string {
            case "markdown":
                return part["text"]?.string.map(RecommendationPart.text)
            case "inline-link":
                guard let link = part["link"]?.object, let label = link["label"]?.string,
                      let href = link["href"]?.string, let url = URL(string: href), url.scheme == "https" || url.scheme == "http" else { return nil }
                return .link(label: label, url: url, sourceID: link["sourceId"]?.string)
            case "inline-task":
                guard let task = part["task"]?.object, let label = task["label"]?.string, let id = task["conversationId"]?.string else { return nil }
                return .task(label: label, conversationID: id, sourceID: task["sourceId"]?.string)
            default:
                return nil
            }
        }
    }

    public static func plainText(_ parts: [RecommendationPart]) -> String {
        parts.map { part in
            switch part {
            case .text(let text): text
            case .link(let label, _, _), .task(let label, _, _): label
            }
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct RecommendationCard: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let sourceIDs: [String]
    public let items: [RecommendationItem]
    /// The card's text when its template is unknown to this client.
    public let fallbackText: String?
    public let footerAction: RecommendationAction?

    public init(id: String, title: String, sourceIDs: [String], items: [RecommendationItem], fallbackText: String? = nil,
                footerAction: RecommendationAction? = nil) {
        self.id = id; self.title = title; self.sourceIDs = sourceIDs; self.items = items
        self.fallbackText = fallbackText; self.footerAction = footerAction
    }

    init?(json: JSONValue, prompts: [String: String]) {
        guard let card = json.object, let id = card["id"]?.string, let title = card["title"]?.string else { return nil }
        let template = card["template"]?.string
        let items = template == "text-list@1" || template == "media-list@1"
            ? (card["items"]?.array ?? []).prefix(4).compactMap { RecommendationItem(json: $0, prompts: prompts) } : []
        let fallback = items.isEmpty ? card["fallbackText"]?.string : nil
        guard !items.isEmpty || fallback != nil else { return nil }
        self.init(id: id, title: title, sourceIDs: (card["sourceIds"]?.array ?? []).compactMap(\.string), items: items,
                  fallbackText: fallback, footerAction: RecommendationAction(json: card["footerAction"], prompts: prompts))
    }
}

public struct RecommendationItem: Equatable, Identifiable, Sendable {
    public let id: String
    /// A media item's title; text items carry their prose in `parts`.
    public let title: String?
    public let parts: [RecommendationPart]
    public let detail: String?
    public let imageURL: URL?
    public let action: RecommendationAction?

    public init(id: String, title: String? = nil, parts: [RecommendationPart] = [], detail: String? = nil,
                imageURL: URL? = nil, action: RecommendationAction? = nil) {
        self.id = id; self.title = title; self.parts = parts; self.detail = detail; self.imageURL = imageURL; self.action = action
    }

    init?(json: JSONValue, prompts: [String: String]) {
        guard let item = json.object, let id = item["id"]?.string else { return nil }
        let parts = RecommendationPart.parts(item["parts"], prompts: prompts)
        let title = item["title"]?.string
        guard title != nil || !parts.isEmpty else { return nil }
        self.init(id: id, title: title, parts: parts, detail: item["description"]?.string,
                  imageURL: item["imageUrl"]?.string.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil },
                  action: RecommendationAction(json: item["action"], prompts: prompts))
    }

    public var text: String { RecommendationPart.plainText(parts) }

    /// A row that stands for one existing Task opens that Task instead of its source link, as on the desktop.
    public var linkedTaskID: String? {
        guard case .openURL = action else { return nil }
        let tasks = parts.compactMap { part -> String? in if case .task(_, let id, _) = part { id } else { nil } }
        return tasks.count == 1 ? tasks[0] : nil
    }
}

/// What tapping a recommendation does. A prompt goes into the composer; the member still sends it.
public enum RecommendationAction: Equatable, Sendable {
    case openURL(URL, label: String)
    /// `memberTask`: the prompt is the member's own task, which the composer turns into a request for help.
    case prompt(String, label: String, memberTask: Bool)

    public var label: String {
        switch self { case .openURL(_, let label), .prompt(_, let label, _): label }
    }

    init?(json: JSONValue?, prompts: [String: String]) {
        guard let action = json?.object, let label = action["label"]?.string else { return nil }
        switch action["type"]?.string {
        case "open_url":
            guard let href = action["href"]?.string, let url = URL(string: href), url.scheme == "https" || url.scheme == "http" else { return nil }
            self = .openURL(url, label: label)
        case "open_task_form", "send_to_comma":
            let referenced = action["promptId"]?.string.flatMap { prompts[$0] }
            guard let prompt = action["prompt"]?.string ?? referenced,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let member = action["type"]?.string == "send_to_comma" && (referenced != nil || action["memberTask"]?.bool == true)
            self = .prompt(prompt, label: label, memberTask: member)
        default:
            return nil
        }
    }
}
