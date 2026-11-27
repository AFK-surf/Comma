import Foundation

/// One platform card on the phone's Home: a connected app's briefing cards, or an enabled app the briefing
/// has nothing from yet. Two connections of the same app are two platforms; several cards from the same
/// connection merge into one platform.
public struct PlatformRoutine: Equatable, Identifiable, Sendable {
    /// The connection id, which outlives a briefing; a card drawn from several sources keeps its own id.
    public let id: String
    /// The platform's single source. A card drawn from several sources has none.
    public let source: RecommendationSource?
    /// All briefing cards belonging to this platform, in server order.
    public let cards: [RecommendationCard]
    /// The connected account, set only when another platform shows the same name, to tell the two apart.
    public let connectionLabel: String?

    public init(id: String, source: RecommendationSource?, cards: [RecommendationCard], connectionLabel: String? = nil) {
        self.id = id; self.source = source; self.cards = cards; self.connectionLabel = connectionLabel
    }

    public init(id: String, source: RecommendationSource?, card: RecommendationCard?, connectionLabel: String? = nil) {
        self.init(id: id, source: source, cards: card.map { [$0] } ?? [], connectionLabel: connectionLabel)
    }

    /// The platform's first briefing card, if any.
    public var card: RecommendationCard? { cards.first }

    /// Fallback texts from cards whose templates this client cannot render.
    public var fallbackTexts: [String] { cards.compactMap(\.fallbackText) }

    /// The app's name, or the card's title when the card has no single source.
    public var name: String { source?.appName ?? card?.title ?? "" }

    /// The cards' items the member can still act on, in server order. A row standing for one Task shows only while
    /// that Task is open, as the desktop's `VisibleRecommendationTaskRow` does. When several cards from one
    /// connection merge, repeated per-card item ids are prefixed with their card id so every row stays uniquely
    /// identifiable regardless of which linked Tasks are open.
    public func preTasks(isTaskOpen: (String) -> Bool) -> [RecommendationItem] {
        var seen = Set<String>()
        return cards.flatMap { card in
            card.items.compactMap { item -> RecommendationItem? in
                let uniqueID: String
                if seen.insert(item.id).inserted {
                    uniqueID = item.id
                } else {
                    var candidate = "\(card.id):\(item.id)"
                    var suffix = 2
                    while !seen.insert(candidate).inserted {
                        candidate = "\(card.id):\(item.id):\(suffix)"
                        suffix += 1
                    }
                    uniqueID = candidate
                }
                guard item.linkedTaskID.map(isTaskOpen) ?? true else { return nil }
                guard uniqueID != item.id else { return item }
                return RecommendationItem(
                    id: uniqueID,
                    title: item.title,
                    parts: item.parts,
                    detail: item.detail,
                    imageURL: item.imageURL,
                    action: item.action,
                    objective: item.objective,
                    quote: item.quote
                )
            }
        }
    }

    /// Whether a briefing row standing for `task` still needs the member. A Task this client does not know
    /// counts as ended, as on the desktop.
    public static func isOpen(_ task: Conversation?) -> Bool {
        guard let task, !task.isArchived else { return false }
        return !endedStatuses.contains(task.status)
    }

    private static let endedStatuses: Set<String> = ["completed", "cancelled", "archived", "ready_for_review"]
}

extension RecommendationFeed {
    /// Home's platform cards: the briefing's cards in server order, most pressing first, merged by single
    /// connection, then each enabled source no card names. A disabled source without a card is left out.
    public var platforms: [PlatformRoutine] {
        var grouped: [(id: String, source: RecommendationSource?, cards: [RecommendationCard])] = []
        var indexByConnection: [String: Int] = [:]
        let named = Set(cards.flatMap(\.sourceIDs).compactMap { source($0)?.connectionID })
        for card in cards {
            if let source = source(for: card) {
                if let index = indexByConnection[source.connectionID] {
                    grouped[index].cards.append(card)
                } else {
                    indexByConnection[source.connectionID] = grouped.count
                    grouped.append((id: source.connectionID, source: source, cards: [card]))
                }
            } else {
                grouped.append((id: card.id, source: nil, cards: [card]))
            }
        }
        for source in sources where source.enabled && !named.contains(source.connectionID) {
            grouped.append((id: source.connectionID, source: source, cards: []))
        }
        let platforms = grouped.map { PlatformRoutine(id: $0.id, source: $0.source, cards: $0.cards) }
        let repeated = Set(Dictionary(grouping: platforms, by: \.name).filter { $0.value.count > 1 }.keys)
        return platforms.map { platform in
            guard repeated.contains(platform.name) else { return platform }
            return PlatformRoutine(id: platform.id, source: platform.source, cards: platform.cards,
                                   connectionLabel: platform.source?.label)
        }
    }
}
