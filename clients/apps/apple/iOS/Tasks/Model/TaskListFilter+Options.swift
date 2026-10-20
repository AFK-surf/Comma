import CommaCore
import Foundation

// The choices a filter page offers for each field, following the desktop Tasks filter menu. Desktop also offers a
// Trigger rule filter, which the phone does not have.
extension TaskListFilter {
    /// Every status in display order, the desktop board's column order; each list of statuses follows it.
    /// Archived Tasks are listed apart.
    static let statusBuckets: [TaskBucket] = [.inProgress, .needsReview, .done, .cancelled]

    /// The option ids `field` offers, in menu order: every status; the catalog's labels, then No label; Scheduled,
    /// On updates, Other trigger while a loaded Task has that kind or it is selected, then No loop; the platforms and
    /// devices the loaded Tasks use, plus any still selected. An empty list hides the field: Label needs catalog
    /// labels, and Platform needs a Task that names one, as on the desktop.
    func options(_ field: Field, tasks: [TaskSummary], labelIDs: [String]) -> [String] {
        let selected = values(field) ?? []
        switch field {
        case .status:
            return Self.statusBuckets.map(\.rawValue)
        case .label:
            return labelIDs.isEmpty ? [] : labelIDs + [Self.noLabel]
        case .schedule:
            let other = selected.contains(Self.otherTrigger) || tasks.contains { $0.loop?.kind == .other }
            return [Self.scheduled, Self.onUpdates] + (other ? [Self.otherTrigger] : []) + [Self.notScheduled]
        case .platform:
            let used = selected.union(tasks.map { Self.originKey($0.origin) })
            let offered = (Self.originKeys + [Self.unspecified]).filter(used.contains)
            return offered == [Self.unspecified] && selected.isEmpty ? [] : offered
        case .clientPlatform:
            let used = selected.union(tasks.compactMap { Self.clientPlatformKey($0.clientPlatform) })
            return (Self.clientPlatformKeys + [Self.unknownClientPlatform]).filter(used.contains)
        }
    }

    /// This filter with `field` no longer narrowing. An empty option set is always fully selected.
    func clearing(_ field: Field) -> TaskListFilter {
        setting(field, values: [], all: [])
    }
}
