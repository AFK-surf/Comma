import CommaCore
import Foundation

/// How a Task list is narrowed: AND across fields, OR within a field, and `nil` for a field that does not
/// narrow. These narrowing rules and the Loops options by trigger kind follow the desktop Tasks route
/// (`TasksRoute.tsx`). Status is a field here because the phone has no board columns. The phone has no
/// Trigger rule filter.
struct TaskListFilter: Equatable, Sendable {
    enum Field: String, CaseIterable, Sendable {
        case status, label, schedule, platform, clientPlatform
    }

    /// The Label option for Tasks that carry no label the catalog knows.
    static let noLabel = "comma:no-label"
    /// The Loops options: Loop Tasks by the kind of their trigger (`TaskLoop.Kind`, an ended Loop by the kind it
    /// had), and every other Task.
    static let scheduled = "comma:scheduled"
    static let onUpdates = "comma:on-updates"
    static let otherTrigger = "comma:other-trigger"
    static let notScheduled = "comma:not-scheduled"
    /// The Platform option for Tasks whose origin is missing or not one of `originKeys`.
    static let unspecified = "comma:unspecified"
    /// Where a Task can be asked for, in the desktop's menu order.
    static let originKeys = ["slack", "telegram", "feishu", "lark", "wechat", "signal", "comma"]
    /// Devices with their own name; any other reported device is `unknownClientPlatform`.
    static let clientPlatformKeys = ["macos", "windows", "linux", "ios", "android", "web", "watchos"]
    static let unknownClientPlatform = "unknown"

    var statuses: Set<TaskBucket>?
    var labels: Set<String>?
    var schedules: Set<String>?
    var origins: Set<String>?
    var clientPlatforms: Set<String>?

    init(statuses: Set<TaskBucket>? = nil, labels: Set<String>? = nil, schedules: Set<String>? = nil,
         origins: Set<String>? = nil, clientPlatforms: Set<String>? = nil) {
        self.statuses = statuses; self.labels = labels; self.schedules = schedules; self.origins = origins
        self.clientPlatforms = clientPlatforms
    }

    /// Whether `task` passes every narrowed field. Label ids the catalog no longer knows are ignored, so a
    /// Task left with only deleted labels counts as unlabeled.
    func matches(_ task: TaskSummary, knownLabelIDs: Set<String>) -> Bool {
        Field.allCases.allSatisfy { field in
            guard let selected = values(field) else { return true }
            return !Self.keys(field, of: task, knownLabelIDs: knownLabelIDs).isDisjoint(with: selected)
        }
    }

    /// The field's selected option ids, or nil when it does not narrow. Status ids are `TaskBucket` raw values.
    func values(_ field: Field) -> Set<String>? {
        switch field {
        case .status: statuses.map { Set($0.map(\.rawValue)) }
        case .label: labels
        case .schedule: schedules
        case .platform: origins
        case .clientPlatform: clientPlatforms
        }
    }

    /// This filter with `field` narrowed to `values`. Selecting every option in `all` stops narrowing;
    /// selecting none narrows to nothing.
    func setting(_ field: Field, values: Set<String>, all: Set<String>) -> TaskListFilter {
        let narrowed = all.isSubset(of: values) ? nil : values
        var next = self
        switch field {
        case .status: next.statuses = narrowed.map { Set($0.compactMap(TaskBucket.init(rawValue:))) }
        case .label: next.labels = narrowed
        case .schedule: next.schedules = narrowed
        case .platform: next.origins = narrowed
        case .clientPlatform: next.clientPlatforms = narrowed
        }
        return next
    }

    /// The fields that narrow, in display order.
    var narrowedFields: [Field] { Field.allCases.filter { values($0) != nil } }

    /// The Loops option a Task belongs to.
    static func loopKey(_ loop: TaskLoop?) -> String {
        switch loop?.kind {
        case .scheduled: scheduled
        case .onUpdates: onUpdates
        case .other: otherTrigger
        case nil: notScheduled
        }
    }

    /// The Platform option a Task belongs to.
    static func originKey(_ origin: String?) -> String {
        origin.flatMap { originKeys.contains($0) ? $0 : nil } ?? unspecified
    }

    /// The Client platform option a Task belongs to; nil when the Task reports no device, as on the desktop.
    static func clientPlatformKey(_ platform: String?) -> String? {
        guard let platform, !platform.isEmpty else { return nil }
        return clientPlatformKeys.contains(platform) ? platform : unknownClientPlatform
    }

    /// How many of `tasks` each of the field's options holds, regardless of the current narrowing.
    static func counts(field: Field, tasks: [TaskSummary], knownLabelIDs: Set<String>) -> [String: Int] {
        var counts: [String: Int] = [:]
        for task in tasks {
            for key in keys(field, of: task, knownLabelIDs: knownLabelIDs) { counts[key, default: 0] += 1 }
        }
        return counts
    }

    /// The options of `field` that `task` belongs to.
    private static func keys(_ field: Field, of task: TaskSummary, knownLabelIDs: Set<String>) -> Set<String> {
        switch field {
        case .status:
            return [task.bucket.rawValue]
        case .label:
            let known = Set(task.labels).intersection(knownLabelIDs)
            return known.isEmpty ? [noLabel] : known
        case .schedule:
            return [loopKey(task.loop)]
        case .platform:
            return [originKey(task.origin)]
        case .clientPlatform:
            return clientPlatformKey(task.clientPlatform).map { [$0] } ?? []
        }
    }
}
