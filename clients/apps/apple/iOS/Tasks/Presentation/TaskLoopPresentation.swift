import Foundation

// A Loop Task's Loop for the touch layout. iOS details match desktop Properties (`useTaskLoopDetails`): the kind of
// trigger that wakes it, then for an active Loop only its trigger rule, for a pending Loop the rule and Setting up,
// for a paused Loop the rule and why it paused, and for an ended Loop only Ended. No next run, last run, run count
// or end shows.
extension TaskLoop {
    /// What kind of trigger wakes it: a time, updates the person named, or a cadence this client cannot read. An
    /// ended Loop keeps the kind its cadence had.
    enum Kind: CaseIterable, Sendable {
        case scheduled, onUpdates, other

        /// The kind's name on the Task's chip, the details heading and the Loops filter, as on desktop.
        var label: String {
            switch self {
            case .scheduled: String(localized: "Scheduled")
            case .onUpdates: String(localized: "On updates")
            case .other: String(localized: "Other trigger")
            }
        }

        /// The kind's glyph, the one desktop draws for it.
        var iconName: String {
            switch self {
            case .scheduled: "central-calendar-days"
            case .onUpdates: "central-eye-open"
            case .other: "central-infinity"
            }
        }
    }

    /// One row of the details, the same rows as desktop Properties.
    enum Detail: Hashable {
        /// What wakes it, with the cron's zone when that zone's offset is not the viewer's.
        case rule(String, zone: Zone?)
        /// An active Loop whose rule this client cannot read still says that it runs.
        case running
        /// The Task's Worker has not made the Loop yet.
        case settingUp
        /// Why it paused.
        case paused(String)
        case ended
    }

    /// A cron's zone: `offset` is short ("GMT+8"); `name` is its long name ("China Standard Time") for VoiceOver.
    struct Zone: Hashable {
        let offset: String
        let name: String
    }

    var kind: Kind {
        switch cadence {
        case .timed: .scheduled
        case .events: .onUpdates
        case nil: .other
        }
    }

    /// The details under the kind. There is always at least one row. An ended Loop shows only Ended.
    func details(calendar: Calendar = .current, viewer: TimeZone = .current, at date: Date = .now,
                 locale: Locale = .current) -> [Detail] {
        if state == .ended { return [.ended] }
        var rows = cadenceLabel(calendar: calendar).map {
            [Detail.rule($0, zone: foreignZone(viewer: viewer, at: date, locale: locale))]
        } ?? []
        switch state {
        case .pending: rows.append(.settingUp)
        case .paused: rows.append(.paused(pausedLabel))
        case .active where rows.isEmpty: rows.append(.running)
        case .active, .ended: break
        }
        return rows
    }

    /// What wakes it: "Every day at 9:00 AM", "Every hour", or the updates the person named, as they wrote them; nil
    /// for a cadence this client does not know.
    func cadenceLabel(calendar: Calendar = .current) -> String? {
        switch cadence {
        case .timed(let pattern, let cron, _): Self.label(pattern, cron: cron, calendar: calendar)
        case .events(let events): events
        case nil: nil
        }
    }

    /// Why it paused, as one short sentence; "Paused" for a reason this client does not know.
    var pausedLabel: String {
        switch reason {
        case .waiting: String(localized: "Paused until you reply")
        case .budget: String(localized: "Paused · it woke too often")
        case .exited: String(localized: "Paused · its program stopped")
        case .failed: String(localized: "Paused · it ran into an error")
        case .quota: String(localized: "Paused · usage limit reached")
        case .undeliverable: String(localized: "Paused · couldn’t reach this task")
        default: String(localized: "Paused")
        }
    }

    /// The cron's zone when its offset now differs from the viewer's: a cron's times are that zone's wall clock. Nil
    /// for an interval or events, a zone with the viewer's offset, or a zone this system does not know.
    func foreignZone(viewer: TimeZone = .current, at date: Date = .now, locale: Locale = .current) -> Zone? {
        guard case .timed(_, _, let identifier?) = cadence, let zone = TimeZone(identifier: identifier),
              zone.secondsFromGMT(for: date) != viewer.secondsFromGMT(for: date) else { return nil }
        var style = Date.FormatStyle.dateTime.timeZone(.localizedGMT(.short)).locale(locale)
        style.timeZone = zone
        // The generic name, as desktop's hover text: "Pacific Time", not "Pacific Daylight Time".
        let name = zone.localizedName(for: .generic, locale: locale)
        let offset = date.formatted(style)
        return Zone(offset: offset, name: name ?? offset)
    }

    /// "Every day at 9:00 AM", "Every Mon, Wed at 6:30 PM", "Every 6 hours", "Every 2 hours at :15"; a cron with no
    /// plain pattern as written.
    static func label(_ pattern: Pattern, cron: String?, calendar: Calendar = .current) -> String {
        switch pattern {
        case .interval(let minutes):
            switch minutes {
            case 1440: return String(localized: "Every day")
            case 60: return String(localized: "Every hour")
            case 1: return String(localized: "Every minute")
            case _ where minutes % 1440 == 0: return String(localized: "Every \(minutes / 1440) days")
            case _ where minutes % 60 == 0:
                if let minute = cron.flatMap(steppedHourMinute), minute != 0 {
                    return String(localized: "Every \(minutes / 60) hours at :\(minute)")
                }
                return String(localized: "Every \(minutes / 60) hours")
            default: return String(localized: "Every \(minutes) minutes")
            }
        case .hourly(let minute):
            return String(localized: "Every hour at :\(minute)")
        case .daily(let hour, let minute):
            return String(localized: "Every day at \(time(hour, minute, calendar))")
        case .weekdays(let hour, let minute):
            return String(localized: "Every weekday at \(time(hour, minute, calendar))")
        case .weekly(let days, let hour, let minute):
            let names = days.map { calendar.shortWeekdaySymbols[$0] }
                .formatted(.list(type: .and, width: .narrow).locale(calendar.locale ?? .current))
            return String(localized: "Every \(names) at \(time(hour, minute, calendar))")
        case .monthly(let day, let hour, let minute):
            return String(localized: "Monthly on day \(day) at \(time(hour, minute, calendar))")
        case .custom:
            return cron ?? ""
        }
    }

    /// The minute past the hour of a stepped-hour cron ("15 */2 * * *"). Its interval pattern keeps only the period.
    /// The core folds a cron into an interval of whole hours only when its first field is that minute.
    private static func steppedHourMinute(_ cron: String) -> Int? {
        cron.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
    }

    /// A time of day as the viewer's locale writes it, on the wall clock of the cron's zone.
    private static func time(_ hour: Int, _ minute: Int, _ calendar: Calendar) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let date = utc.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute))!
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current,
                                               timeZone: .gmt))
    }
}
