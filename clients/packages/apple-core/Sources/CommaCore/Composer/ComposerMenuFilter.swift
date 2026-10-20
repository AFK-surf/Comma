import Foundation

/// What a composer menu row is searched by: the fields of the desktop `AiInputMenuItem` that its ranking reads.
public struct ComposerMenuCandidate: Equatable, Sendable {
    public var id: String
    public var label: String
    public var searchText: String?
    public var description: String?
    public var keywords: [String]

    public init(id: String, label: String, searchText: String? = nil, description: String? = nil, keywords: [String] = []) {
        self.id = id; self.label = label; self.searchText = searchText; self.description = description; self.keywords = keywords
    }
}

/// The desktop ranking (`filterAiInputMenuItems` and `itemRank`, ui richText.ts). The query is trimmed and
/// lowercased. A search text, label or id that starts with it ranks 0 and one that contains it 1; a description
/// or keyword that contains it ranks 2; anything else is dropped. Ties keep source order, so a recency-ordered
/// source stays recency-ordered. An empty query keeps every row, and there is no row cap.
public enum ComposerMenuFilter {
    public static func rank(_ candidate: ComposerMenuCandidate, query: String) -> Int? {
        rank(candidate, normalized: normalize(query))
    }

    /// The items `query` keeps, best rank first and in source order within a rank.
    public static func filter<Item>(_ items: [Item], query: String, by candidate: (Item) -> ComposerMenuCandidate) -> [Item] {
        let query = normalize(query)
        guard !query.isEmpty else { return items }
        return items.enumerated()
            .compactMap { entry in rank(candidate(entry.element), normalized: query).map { (rank: $0, index: entry.offset, item: entry.element) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.item)
    }

    private static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func rank(_ candidate: ComposerMenuCandidate, normalized query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let primary = [candidate.searchText, candidate.label, candidate.id].compactMap { $0?.lowercased() }
        if primary.contains(where: { $0.hasPrefix(query) }) { return 0 }
        if primary.contains(where: { $0.contains(query) }) { return 1 }
        let secondary = ([candidate.description].compactMap { $0 } + candidate.keywords).map { $0.lowercased() }
        return secondary.contains { $0.contains(query) } ? 2 : nil
    }
}
