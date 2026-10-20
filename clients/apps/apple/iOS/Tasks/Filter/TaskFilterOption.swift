import SwiftUI
import CommaCore

/// One choice on a filter page: its id in `TaskListFilter`, its name and its glyph.
struct TaskFilterOption: Identifiable {
    enum Glyph {
        case status(TaskBucket), label(color: String), loop(TaskLoop.Kind), origin(TaskOrigin), device, none
    }

    let id: String
    let name: String
    let glyph: Glyph
}

/// What the filter pages choose from: the loaded Tasks and the Group's label catalog.
struct TaskFilterChoices {
    let tasks: [TaskSummary]
    let labelCatalog: TaskLabelCatalog?

    private var labels: [TaskLabel] { labelCatalog?.labels ?? [] }

    /// The options `field` offers under `filter`, in menu order.
    func options(_ field: TaskListFilter.Field, in filter: TaskListFilter) -> [TaskFilterOption] {
        filter.options(field, tasks: tasks, labelIDs: labels.map(\.id)).map { option(field, id: $0) }
    }

    /// The options a narrowed field keeps, in menu order.
    func chosen(_ field: TaskListFilter.Field, in filter: TaskListFilter) -> [TaskFilterOption] {
        let values = filter.values(field) ?? []
        return options(field, in: filter).filter { values.contains($0.id) }
    }

    /// The option ids `filter` lets through for `field`: every option while the field doesn't narrow.
    func selected(_ field: TaskListFilter.Field, in filter: TaskListFilter) -> Set<String> {
        filter.values(field) ?? Set(options(field, in: filter).map(\.id))
    }

    /// `filter` with one option checked or unchecked. Checking every option stops the field narrowing;
    /// unchecking the last one narrows to nothing, which the list behind shows as its filtered-empty state.
    func toggling(_ id: String, of field: TaskListFilter.Field, in filter: TaskListFilter) -> TaskListFilter {
        let all = Set(options(field, in: filter).map(\.id))
        var next = filter.values(field) ?? all
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        return filter.setting(field, values: next, all: all)
    }

    /// How many loaded Tasks each option of `field` holds, whatever the filter.
    func counts(_ field: TaskListFilter.Field) -> [String: Int] {
        TaskListFilter.counts(field: field, tasks: tasks, knownLabelIDs: Set(labels.map(\.id)))
    }

    private func option(_ field: TaskListFilter.Field, id: String) -> TaskFilterOption {
        switch field {
        case .status:
            let bucket = TaskBucket(rawValue: id) ?? .inProgress
            return TaskFilterOption(id: id, name: String(localized: bucket.label), glyph: .status(bucket))
        case .label:
            // Every option but No label comes from the catalog.
            let label = labels.first { $0.id == id }
            return TaskFilterOption(id: id, name: label?.name ?? String(localized: "No label"),
                                    glyph: label.map { .label(color: $0.color) } ?? .none)
        case .schedule:
            // No loop has no glyph, as on the desktop.
            let kind: TaskLoop.Kind? = switch id {
            case TaskListFilter.scheduled: .scheduled
            case TaskListFilter.onUpdates: .onUpdates
            case TaskListFilter.otherTrigger: .other
            default: nil
            }
            return TaskFilterOption(id: id, name: kind?.label ?? String(localized: "No loop"),
                                    glyph: kind.map { .loop($0) } ?? .none)
        case .platform:
            let origin = TaskOrigin(rawValue: id)
            return TaskFilterOption(id: id, name: origin?.label ?? String(localized: "Unspecified"),
                                    glyph: origin.map { .origin($0) } ?? .none)
        case .clientPlatform:
            return TaskFilterOption(id: id, name: platformLabel(id), glyph: .device)
        }
    }
}

extension TaskListFilter.Field {
    var title: LocalizedStringResource {
        switch self {
        case .status: "Status"
        case .label: "Label"
        case .schedule: "Loops"
        case .platform: "Platform"
        case .clientPlatform: "Client platform"
        }
    }

    /// Uses the same glyph as the desktop filter menu; Status shows the neutral dashed ring.
    var iconName: String {
        switch self {
        case .status: TaskBucket.neutralIconName
        case .label: "icon-tag"
        case .schedule: "central-infinity"
        case .platform: "icon-square-grid"
        case .clientPlatform: "icon-macbook"
        }
    }
}
