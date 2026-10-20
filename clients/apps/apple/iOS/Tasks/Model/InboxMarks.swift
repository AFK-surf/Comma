import Foundation

/// The Inbox's read, unread and cleared marks, as the client core keeps them on this device (its `marks` topic, the
/// kinds the desktop's Inbox uses): each records the Task's `updatedAt` when it was made, as the desktop's revision
/// marks do (`inboxDeletion.ts`, `taskReviewAttention.ts`):
/// - `seen` (`taskReviewSeen`): the member viewed the Task. A Needs review Task that updates afterwards reads as
///   unread again.
/// - `unread` (`inboxUnread`): the member marked the row unread. It stays until the row is read.
/// - `cleared` (`inboxDeleted`): the row is hidden until the Task updates past the mark, so new activity brings it back.
struct InboxMarks: Equatable, Sendable {
    var seen: [String: Double] = [:]
    var unread: [String: Double] = [:]
    var cleared: [String: Double] = [:]

    /// Hidden until the Task updates past the revision it was cleared at.
    func isCleared(_ task: TaskSummary) -> Bool {
        cleared[task.id].map { Self.revision(of: task) <= $0 } ?? false
    }

    /// Marked unread by the member, or a Needs review Task not viewed since it last updated.
    func isUnread(_ task: TaskSummary) -> Bool {
        if unread[task.id] != nil { return true }
        guard task.bucket == .needsReview else { return false }
        return seen[task.id].map { Self.revision(of: task) > $0 } ?? true
    }

    /// The revision a mark records. Tasks without an `updatedAt` share revision 0.
    static func revision(of task: TaskSummary) -> Double { task.updatedAt }
}
