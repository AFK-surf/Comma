import Foundation

/// A Loop Task's Loop as the core reads it (`TaskLoop` in the client core, the same object on the `tasks` and
/// `taskSummaries` topics): what wakes it and how the Background Loop that runs it is doing. iOS keeps only the
/// fields that its details show, which match desktop Properties: no run count, run times or end. A Task without one
/// is no Loop Task.
struct TaskLoop: Equatable, Sendable {
    enum State: String, Sendable {
        /// The Task asked for a Loop and its Worker has not made it yet.
        case pending
        /// It runs: its cadence wakes the Task's Worker.
        case active
        /// It does not run for now; `reason` says why.
        case paused
        /// It no longer runs the Task, which keeps the record that it was a Loop.
        case ended
    }

    /// Why it paused (the first six) or why it ended (the rest); the core keeps only a reason that fits the state.
    enum Reason: String, Sendable {
        case waiting, budget, exited, quota, undeliverable
        case failed
        case completed, cancelled, maxRuns = "max_runs", endsAt = "ends_at"
    }

    /// How a timed Loop repeats, as the core folds its interval or cron once for every client.
    enum Pattern: Equatable, Sendable {
        case interval(minutes: Int)
        case hourly(minute: Int)
        case daily(hour: Int, minute: Int)
        case weekdays(hour: Int, minute: Int)
        /// `days` run 0 (Sunday) to 6, sorted.
        case weekly(days: [Int], hour: Int, minute: Int)
        case monthly(day: Int, hour: Int, minute: Int)
        /// No plain pattern: the cron says it.
        case custom
    }

    /// What wakes it: a fixed interval, a cron on a zone's wall clock, or events the person named.
    enum Cadence: Equatable, Sendable {
        /// `pattern` is the interval the core folded, or a cron's plain pattern.
        case timed(pattern: Pattern, cron: String?, timezone: String?)
        case events(String)
    }

    let state: State
    let reason: Reason?
    /// Nil only for a cadence kind this client does not know yet.
    let cadence: Cadence?

    /// It still runs the Task (the core's `scheduled`).
    var runs: Bool { state != .ended }

    init?(_ item: NSDictionary?) {
        guard let item, let state = item.string("state").flatMap(State.init(rawValue:)) else { return nil }
        self.state = state
        reason = item.string("reason").flatMap(Reason.init(rawValue:))
        cadence = item.object("cadence").flatMap(Cadence.init)
    }
}

extension TaskLoop.Cadence {
    init?(_ item: NSDictionary) {
        if let events = item.string("events") {
            self = .events(events)
        } else if let pattern = item.object("pattern").flatMap(TaskLoop.Pattern.init) {
            self = .timed(pattern: pattern, cron: item.string("cron"), timezone: item.string("timezone"))
        } else {
            return nil
        }
    }
}

extension TaskLoop.Pattern {
    init?(_ item: NSDictionary) {
        let hour = item.int("hour"), minute = item.int("minute")
        switch item.string("kind") {
        case "interval": guard let minutes = item.int("minutes") else { return nil }; self = .interval(minutes: minutes)
        case "hourly": guard let minute else { return nil }; self = .hourly(minute: minute)
        case "daily": guard let hour, let minute else { return nil }; self = .daily(hour: hour, minute: minute)
        case "weekdays": guard let hour, let minute else { return nil }; self = .weekdays(hour: hour, minute: minute)
        case "weekly":
            let days = (item.array("days") ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            guard let hour, let minute, !days.isEmpty else { return nil }
            self = .weekly(days: days, hour: hour, minute: minute)
        case "monthly":
            guard let day = item.int("day"), let hour, let minute else { return nil }
            self = .monthly(day: day, hour: hour, minute: minute)
        default: self = .custom
        }
    }
}
