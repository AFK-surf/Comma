import ActivityKit
import Foundation

/// A presentation of an existing Task. It carries no credential or execution authority.
struct TaskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var status: String
        var updatedAtEpochSeconds: Int

        var presentation: TaskActivityPresentation { TaskActivityPresentation(status: status) }
    }

    let accountID: String
    let workspaceID: String
    let groupID: String
    let taskID: String

    var taskURL: URL? {
        var url = URLComponents()
        url.scheme = "comma"
        url.host = "task"
        url.queryItems = [
            URLQueryItem(name: "workspace", value: workspaceID),
            URLQueryItem(name: "group", value: groupID),
            URLQueryItem(name: "task", value: taskID),
        ]
        return url.url
    }
}

struct TaskActivityProjection: Sendable, Equatable {
    let workspaceID: String
    let groupID: String
    let taskID: String
    let title: String
    let status: String
    let updatedAt: Date

    var contentState: TaskActivityAttributes.ContentState {
        .init(
            title: String(title.prefix(160)),
            status: status,
            updatedAtEpochSeconds: Int(updatedAt.timeIntervalSince1970)
        )
    }
}

struct TaskActivityPresentation {
    let status: String

    var isTerminal: Bool { ["completed", "cancelled", "failed", "archived"].contains(status) }
    var needsAttention: Bool { ["ready_for_review", "escalated"].contains(status) }

    var label: String {
        switch status {
        case "ready_for_review": "Ready for review"
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

    var symbol: String {
        switch status {
        case "ready_for_review": "checkmark.bubble"
        case "escalated": "person.crop.circle.badge.exclamationmark"
        case "completed": "checkmark.circle.fill"
        case "failed": "exclamationmark.circle.fill"
        case "cancelled", "archived": "stop.circle"
        default: "sparkles"
        }
    }
}
