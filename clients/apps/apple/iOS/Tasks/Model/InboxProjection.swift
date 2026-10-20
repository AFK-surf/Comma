import Foundation

/// One day of Inbox rows, newest first.
struct InboxDay: Equatable, Identifiable, Sendable {
    /// The start of the day, in the calendar the rows were grouped with.
    let id: Date
    internal(set) var tasks: [TaskSummary]
}

/// Why the Inbox shows no rows.
enum InboxEmptyState: Equatable, Sendable {
    /// Nothing has finished or needed review yet.
    case nothingYet
    /// Every notification was cleared, or read while showing unread only.
    case caughtUp
    /// The filter hides this many rows that the default Inbox shows.
    case filtered(hidden: Int)
}

/// The Inbox as a projection of the loaded Task list, like the desktop's Inbox rail: the Tasks that finished
/// or wait on the member, newest first, never archived Tasks or rows the member cleared.
enum InboxProjection {
    /// The Inbox until the member changes its filter: Needs review, Done, and Cancelled (which includes
    /// Failed). In progress stays one filter away.
    static let defaultFilter = TaskListFilter(statuses: [.needsReview, .done, .cancelled])

    /// Every row the Inbox can show before filtering: Tasks neither archived nor cleared. Filter counts and
    /// the bulk actions' scope start here.
    static func listed(_ tasks: [TaskSummary], marks: InboxMarks) -> [TaskSummary] {
        tasks.filter { !$0.isArchived && !marks.isCleared($0) }
    }

    /// The rows that pass `filter`, and with `unreadOnly` only the unread ones, newest first.
    static func rows(_ tasks: [TaskSummary], marks: InboxMarks, filter: TaskListFilter,
                            unreadOnly: Bool = false) -> [TaskSummary] {
        listed(tasks, marks: marks)
            .filter { filter.matches($0, knownLabelIDs: []) && (!unreadOnly || marks.isUnread($0)) }
            .sorted { date(of: $0) > date(of: $1) }
    }

    /// `rows`, in order, grouped by the day each Task last changed.
    static func days(_ rows: [TaskSummary], calendar: Calendar) -> [InboxDay] {
        var days: [InboxDay] = []
        for task in rows {
            let day = calendar.startOfDay(for: date(of: task))
            if days.last?.id == day { days[days.count - 1].tasks.append(task) }
            else { days.append(InboxDay(id: day, tasks: [task])) }
        }
        return days
    }

    /// Whether the Inbox tab shows its dot: any row it can show is unread, whatever the filter.
    static func hasUnread(_ tasks: [TaskSummary], marks: InboxMarks) -> Bool {
        listed(tasks, marks: marks).contains(where: marks.isUnread)
    }

    /// Why `rows` came back empty. Rows the default filter shows count as hidden by the filter; Clear Filters
    /// brings them back, Unread only included.
    static func emptyState(_ tasks: [TaskSummary], marks: InboxMarks, filter: TaskListFilter) -> InboxEmptyState {
        if filter != defaultFilter {
            let hidden = rows(tasks, marks: marks, filter: defaultFilter).count
            if hidden > 0 { return .filtered(hidden: hidden) }
        }
        let arrived = tasks.contains { !$0.isArchived && defaultFilter.matches($0, knownLabelIDs: []) }
        return arrived ? .caughtUp : .nothingYet
    }

    /// When the Task last changed; a Task without times sorts last.
    static func date(of task: TaskSummary) -> Date { task.updatedDate ?? Date(timeIntervalSince1970: 0) }
}
