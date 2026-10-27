import CommaCore
import Foundation

/// A Task as the core's `tasks` topic lists it: its facts, and the section its status folds into, as every client shows
/// it (the core says the section; the app does not work it out).
struct TaskSummary: Identifiable, Equatable, Sendable {
    let id: String
    let groupID: String
    let workspaceID: String
    let title: String
    let status: String
    let bucket: TaskBucket
    /// The status is a failure the section `cancelled` folds in.
    let failed: Bool
    let kind: String
    let labels: [String]
    let origin: String?
    let clientPlatform: String?
    /// When it last changed, epoch milliseconds.
    let updatedAt: Double
    /// The version an archive or unarchive names (the server's `updated_at`).
    let archiveVersion: Int?
    let archiveAvailability: ArchiveAvailability?
    /// The version an acceptance of its review names, while it waits for one.
    let reviewVersion: Int?
    /// Its Loop: set on a Loop Task, while the Loop runs it and after it ended.
    let loop: TaskLoop?
    /// Where a Task a station hosts runs; nil for any other.
    let host: TaskHost?
    /// What the core says this Task cannot take (`archive`, `pin`, `share`): not offered.
    let unsupported: Set<String>

    var isTask: Bool { kind == "agent_task" }
    /// Its Loop still runs it: it never waits for a review to accept.
    var scheduled: Bool { loop?.runs == true }
    var canAcceptReview: Bool { isTask && status == "ready_for_review" && (reviewVersion ?? 0) > 0 && !scheduled }
    /// A member can end the Task by hand, a Loop too. The server also refuses Workflow and Triage Tasks.
    var canSetStatus: Bool {
        isTask && !isArchived && ["active", "ready_for_review", "escalated"].contains(status) && archiveVersion != nil
    }
    var isArchived: Bool { bucket == .archived }
    /// The section a list shows it in: an archived Task keeps the one it was archived from.
    let listBucket: TaskBucket
    var updatedDate: Date? { updatedAt > 0 ? Date(wireTimestamp: updatedAt) : nil }

    /// A row that stands in for a Task while the list loads. Its status is not known, so it shows In progress, standing
    /// still.
    init(placeholder id: String, title: String) {
        self.id = id
        groupID = ""; workspaceID = ""; self.title = title; status = ""; bucket = .inProgress; listBucket = .inProgress
        failed = false; kind = "agent_task"; labels = []; origin = nil; clientPlatform = nil; updatedAt = 0
        archiveVersion = nil; archiveAvailability = nil; reviewVersion = nil; loop = nil; host = nil; unsupported = []
    }

    init?(_ item: NSDictionary) {
        guard let id = item.string("conversationId"), let group = item.string("groupId") else { return nil }
        self.id = id
        groupID = group
        workspaceID = item.text("workspaceId") ?? ""
        title = item.text("title") ?? ""
        status = item.text("status") ?? ""
        bucket = TaskBucket(section: item.string("statusBucket"))
        failed = item.bool("statusFailed")
        kind = item.text("kind") ?? "agent_task"
        labels = item.strings("labels")
        origin = item.string("origin")
        clientPlatform = item.string("clientPlatform")
        updatedAt = item.double("updatedAt") ?? 0
        archiveVersion = item.int("archiveVersion")
        archiveAvailability = item.object("archiveAvailability").map {
            ArchiveAvailability(allowed: $0.bool("allowed"), reason: $0.string("reason"))
        }
        reviewVersion = item.int("reviewVersion")
        loop = TaskLoop(item.object("loop"))
        host = item.object("host").map(TaskHost.init)
        unsupported = Set(item.strings("unsupported"))
        listBucket = bucket
    }

    /// A Task as the core's summaries have it (the server's summary): `taskSummaries` with the section its status folds
    /// into, `archivedTasks` with the section it was archived from.
    init?(summary item: NSDictionary) {
        guard let id = item.string("id"), let group = item.string("group_id") else { return nil }
        self.id = id
        groupID = group
        workspaceID = ""
        title = item.text("title") ?? ""
        status = item.text("status") ?? ""
        let archived = item.string("archived_from_bucket")
        bucket = archived != nil ? .archived : TaskBucket(section: item.string("status_bucket"))
        listBucket = archived.map { TaskBucket(section: $0) } ?? bucket
        failed = item.bool("status_failed")
        kind = item.text("kind") ?? "agent_task"
        labels = item.strings("labels")
        origin = item.string("origin")
        clientPlatform = item.string("client_platform")
        updatedAt = item.double("updated_at") ?? 0
        archiveVersion = item.int("updated_at")
        archiveAvailability = item.object("archive_availability").map {
            ArchiveAvailability(allowed: $0.bool("allowed"), reason: $0.string("reason"))
        }
        reviewVersion = nil
        loop = TaskLoop(item.object("loop"))
        host = nil
        unsupported = []
    }
}

/// Where a Task a station hosts runs: its machine as this device knows it.
struct TaskHost: Equatable, Sendable {
    /// The machine's name; nil where this device knows none.
    let machine: String?
    /// Whether the machine is online; nil where this device knows none.
    let online: Bool?

    init(_ host: NSDictionary) {
        let machine = host.object("machine")
        self.machine = machine?.string("name")
        online = machine?["online"] as? Bool
    }
}

extension TaskBucket {
    /// The section the core names (`taskStatusBucket` in `@comma/i18n`): `in_progress`, `needs_review` and the rest.
    /// Any other section, such as the retired `backlog`, reads as In progress.
    init(section: String?) {
        switch section {
        case "in_progress": self = .inProgress
        case "needs_review": self = .needsReview
        case "done": self = .done
        case "cancelled": self = .cancelled
        case "archived": self = .archived
        default: self = .inProgress
        }
    }
}
