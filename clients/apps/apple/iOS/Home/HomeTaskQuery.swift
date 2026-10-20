import SwiftUI
import Observation
import CommaCore

/// What the Home task list shows. The status switcher and the filter sheet edit the same `filter`, so
/// choosing a status in one is reflected in the other. Owned by `AppShellView`, which hands it to `HomeView`.
@MainActor @Observable
final class HomeTaskQuery {
    var filter = HomeTaskQuery.initialFilter {
        // Each filter gets its own budget of pages for filling a short list.
        didSet { if filter != oldValue { fillPages = 0 } }
    }
    @ObservationIgnored private var fillPages = 0

    /// Home opens on Needs review, the Tasks waiting on the member, whatever else the list holds and before its first
    /// page is read, so the switcher and the title never change under the member as it loads.
    private static let initialFilter = TaskListFilter(statuses: [.needsReview])
    /// A list with fewer rows than this reads further pages on its own, at most `fillLimit` per filter.
    private static let fillTarget = 20
    private static let fillLimit = 5

    /// The switcher segment, when the filter shows exactly one of the switcher's statuses.
    var selectedBucket: TaskBucket? {
        guard let statuses = filter.statuses, statuses.count == 1, let only = statuses.first,
              TaskBucket.homeStatuses.contains(only) else { return nil }
        return only
    }

    func select(_ bucket: TaskBucket) { filter.statuses = [bucket] }

    /// The section title: one status's name, "All tasks", or "N statuses".
    var title: String {
        guard let statuses = filter.statuses else { return String(localized: "All tasks") }
        if statuses.count == 1, let only = statuses.first { return String(localized: only.label) }
        return String(localized: "\(statuses.count) statuses")
    }

    /// The filters narrowing the list besides status, shown as the count on the filter button.
    var appliedCount: Int { filter.narrowedFields.filter { $0 != .status }.count }

    /// Clears every filter but status, which the switcher sets.
    func clearFilters() { filter = TaskListFilter(statuses: filter.statuses) }

    /// Whether the end of the list should read the next page. A full list always reads on; one the filter
    /// keeps short reads at most `fillLimit` pages per filter, so a narrow filter never reads every page. Past
    /// that the member reads on by hand: Load more under the rows, or, with none, Look Further Back in the
    /// empty state, which says the pages read so far hold nothing rather than that there is nothing.
    func needsMore(visible: Int, hasMore: Bool) -> Bool {
        hasMore && (visible >= Self.fillTarget || fillPages < Self.fillLimit)
    }

    /// Takes the next page for the end of the list, counting it against the filter's budget while the list is short.
    func claimPage(visible: Int, hasMore: Bool) -> Bool {
        guard needsMore(visible: visible, hasMore: hasMore) else { return false }
        if visible < Self.fillTarget { fillPages += 1 }
        return true
    }

    /// The visible Tasks: pinned ones first, then in the core's `order` (`CommaStore.taskBoardOrder`), the ones it
    /// does not name yet last in the server's order.
    func rows(tasks: [TaskSummary], pinned: Set<String>, order: [String], knownLabelIDs: Set<String>) -> [TaskSummary] {
        Self.rows(matching: filter, tasks: tasks, pinned: pinned, order: order, knownLabelIDs: knownLabelIDs)
    }

    /// The rows the list would show with `bucket` chosen instead, for the page beside the chosen status.
    func rows(for bucket: TaskBucket, tasks: [TaskSummary], pinned: Set<String>, order: [String]) -> [TaskSummary] {
        var other = filter
        other.statuses = [bucket]
        return Self.rows(matching: other, tasks: tasks, pinned: pinned, order: order, knownLabelIDs: [])
    }

    private static func rows(matching filter: TaskListFilter, tasks: [TaskSummary], pinned: Set<String>,
                             order: [String], knownLabelIDs: Set<String>) -> [TaskSummary] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = tasks.enumerated()
            .filter { filter.matches($0.element, knownLabelIDs: knownLabelIDs) }
            .sorted { (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset) }
            .map(\.element)
        return visible.filter { pinned.contains($0.id) } + visible.filter { !pinned.contains($0.id) }
    }

    /// A new workspace opens on Needs review again.
    func reset() {
        filter = Self.initialFilter
        fillPages = 0
    }
}

extension TaskBucket {
    /// The statuses Home's switcher offers, in the order every status list shows (`TaskListFilter.statusBuckets`):
    /// all four, In progress, Needs review, Done and Cancelled.
    static let homeStatuses = TaskListFilter.statusBuckets
}
