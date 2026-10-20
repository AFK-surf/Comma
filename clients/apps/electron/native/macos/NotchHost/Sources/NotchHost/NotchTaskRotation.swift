/// Local presentation state only; task membership remains owned by the projection.
struct CommaNotchTaskRotation {
    static let interval = 5.0

    private var taskIDs: [String] = []
    private var index = 0

    var currentTaskID: String? {
        taskIDs.isEmpty ? nil : taskIDs[index]
    }

    /// A projection update keeps the visible Task while it remains. An update
    /// that came with a notification shows the newest Task, which leads
    /// `taskIDs`, instead.
    mutating func update(taskIDs: [String], showsNewest: Bool = false) {
        let currentID = showsNewest ? nil : currentTaskID
        self.taskIDs = taskIDs
        index = currentID.flatMap { taskIDs.firstIndex(of: $0) } ?? 0
    }

    mutating func advance() {
        guard taskIDs.count > 1 else { return }
        index = (index + 1) % taskIDs.count
    }
}
