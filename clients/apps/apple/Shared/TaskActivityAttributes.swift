import ActivityKit
import CommaCore
import Foundation

/// A bounded projection of existing Tasks. It carries no credential or execution authority.
struct TaskActivityAttributes: ActivityAttributes {
    struct TaskState: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let title: String
        let status: String
        let updatedAtEpochSeconds: Int
        var presentation: TaskActivityPresentation { .init(status: status) }
    }
    struct ContentState: Codable, Hashable, Sendable {
        var tasks: [TaskState]
        var updatedAtEpochSeconds: Int
        var needsAttention: Bool { tasks.contains { $0.presentation.needsAttention } }
    }
    let accountID: String
    let workspaceID: String
    let groupID: String

    func taskURL(id: String) -> URL? {
        var url = URLComponents()
        url.scheme = "comma"
        url.host = "task"
        url.queryItems = [URLQueryItem(name: "workspace", value: workspaceID),
                          URLQueryItem(name: "group", value: groupID), URLQueryItem(name: "task", value: id)]
        return url.url
    }
}

struct TaskActivityProjection: Sendable, Equatable {
    let workspaceID: String
    let groupID: String
    let tasks: [TaskActivityAttributes.TaskState]
    var cohort: Set<String> { Set(tasks.map(\.id)) }
    var contentState: TaskActivityAttributes.ContentState {
        .init(tasks: tasks, updatedAtEpochSeconds: tasks.map(\.updatedAtEpochSeconds).max() ?? 0)
    }
}

struct TaskActivityPresentation {
    let status: String
    var isTerminal: Bool { ["completed", "cancelled", "failed", "archived"].contains(status) }
    var needsAttention: Bool { ["needs_review", "ready_for_review", "escalated"].contains(status) }
    var label: String {
        switch status {
        case "needs_review", "ready_for_review": "Ready for review"
        case "escalated": "Needs your input"
        case "completed": "Completed"
        case "cancelled": "Cancelled"
        case "failed": "Failed"
        case "archived": "Archived"
        case "pending", "pending_assignment", "queued": "Waiting"
        case "active", "running", "in_progress": "Working"
        default: "Task status updated"
        }
    }
    /// The Task board bucket, for the same status glyph and colour as the app.
    var bucket: TaskBucket { TaskBucket(status: status) }
}
