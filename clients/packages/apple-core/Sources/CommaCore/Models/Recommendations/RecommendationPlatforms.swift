import Foundation

/// One platform card on the phone's Home: a connected app's briefing card, or an enabled app the briefing
/// has nothing from yet. Two connections of the same app are two platforms.
public struct PlatformRoutine: Equatable, Identifiable, Sendable {
    /// The connection id, which outlives a briefing; a card drawn from several sources keeps its own id.
    public let id: String
    /// The card's single source. A card drawn from several sources has none.
    public let source: RecommendationSource?
    public let card: RecommendationCard?
    /// The connected account, set only when another platform shows the same name, to tell the two apart.
    public let connectionLabel: String?

    public init(id: String, source: RecommendationSource?, card: RecommendationCard?, connectionLabel: String? = nil) {
        self.id = id; self.source = source; self.card = card; self.connectionLabel = connectionLabel
    }

    /// The app's name, or the card's title when the card has no single source.
    public var name: String { source?.appName ?? card?.title ?? "" }

    /// The card's items the member can still act on. A row standing for one Task shows only while that Task
    /// is open, as the desktop's `VisibleRecommendationTaskRow` does.
    public func preTasks(isTaskOpen: (String) -> Bool) -> [RecommendationItem] {
        (card?.items ?? []).filter { item in item.linkedTaskID.map(isTaskOpen) ?? true }
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
    /// Home's platform cards: the briefing's cards in server order, most pressing first, then each enabled
    /// source no card names. A disabled source without a card is left out.
    public var platforms: [PlatformRoutine] {
        // A second card from one connection keeps its card id, so every platform stays identifiable.
        var usedConnections = Set<String>()
        let named = Set(cards.flatMap(\.sourceIDs).compactMap { source($0)?.connectionID })
        let platforms = cards.map { card in
            let source = source(for: card)
            let id = source.map(\.connectionID).flatMap { usedConnections.insert($0).inserted ? $0 : nil } ?? card.id
            return PlatformRoutine(id: id, source: source, card: card)
        } + sources.filter { $0.enabled && !named.contains($0.connectionID) }.map {
            PlatformRoutine(id: $0.connectionID, source: $0, card: nil)
        }
        let repeated = Set(Dictionary(grouping: platforms, by: \.name).filter { $0.value.count > 1 }.keys)
        return platforms.map { platform in
            guard repeated.contains(platform.name) else { return platform }
            return PlatformRoutine(id: platform.id, source: platform.source, card: platform.card,
                                   connectionLabel: platform.source?.label)
        }
    }
}
