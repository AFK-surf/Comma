import AppKit
import EventKit
import Foundation
import MCP

enum CalendarTools {
    static let all: [ToolDefinition] = [listCalendars, listEvents, createEvent, updateEvent]

    static let listCalendars = ToolDefinition(
        app: .calendar,
        name: "list_calendars",
        title: "List calendars",
        description: "Lists the calendars in the Calendar app on the user's Mac, including iCloud, Google and Exchange accounts synced there.",
        inputSchema: Schema.object(),
        readOnly: true,
        requirements: [.calendars]
    ) { _, context in
        let store = context.events.current()
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        let calendars = store.calendars(for: .event).map { calendar -> Value in
            [
                "id": .string(calendar.calendarIdentifier),
                "title": .string(calendar.title),
                "account": .string(calendar.source.title),
                "color": .string(hexColor(calendar.cgColor)),
                "allows_changes": .bool(calendar.allowsContentModifications),
                "is_default": .bool(calendar.calendarIdentifier == defaultID),
            ]
        }
        return ["calendars": .array(calendars), "time_zone": .string(TimeZone.current.identifier)]
    }

    static let listEvents = ToolDefinition(
        app: .calendar,
        name: "list_events",
        title: "List events",
        description: "Lists events between start and end, at most 366 days apart, in time order. Filter by calendar or by text in the title, location or notes. Recurring events appear once per occurrence; use id with occurrence_start to change one.",
        inputSchema: Schema.object([
            "start": Schema.date("Start of the range."),
            "end": Schema.date("End of the range."),
            "query": Schema.string("Only events whose title, location or notes contain this text."),
            "calendar_ids": Schema.strings("Only these calendars."),
            "limit": Schema.integer(Schema.limitDescription, minimum: 1, maximum: 200),
        ], required: ["start", "end"]),
        readOnly: true,
        requirements: [.calendars]
    ) { arguments, context in
        let start = try arguments.requiredDate("start").date
        let end = try arguments.requiredDate("end").date
        guard end > start else { throw ToolFailure.invalidArguments("end", "end must be after start.") }
        guard end.timeIntervalSince(start) <= 366 * 86_400 else {
            throw ToolFailure.invalidArguments("end", "The range can be at most 366 days.")
        }
        let limit = try arguments.limit(default: 50, max: 200)
        let query = try arguments.string("query")?.lowercased()
        let store = context.events.current()
        let calendars = try selectedCalendars(store, ids: arguments.strings("calendar_ids"), type: .event)

        var events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .sorted { $0.startDate < $1.startDate }
        if let query, !query.isEmpty {
            events = events.filter { event in
                [event.title, event.location, event.notes].contains { $0?.lowercased().contains(query) ?? false }
            }
        }
        return [
            "events": .array(events.prefix(limit).map(eventValue)),
            "truncated": .bool(events.count > limit),
            "time_zone": .string(TimeZone.current.identifier),
        ]
    }

    static let createEvent = ToolDefinition(
        app: .calendar,
        name: "create_event",
        title: "Create event",
        description: "Creates an event in the user's Calendar app. Calendar cannot add invitees through this tool; mention people in notes, or draft an email with the details.",
        inputSchema: Schema.object([
            "title": Schema.string("Event title."),
            "start": Schema.date("Start."),
            "end": Schema.date("End. For an all-day event, the last day."),
            "all_day": Schema.boolean("An all-day event."),
            "calendar_id": Schema.string("Calendar to add it to. Defaults to the user's default calendar."),
            "location": Schema.string("Location."),
            "notes": Schema.string("Notes."),
            "url": Schema.string("A link for the event."),
            "alerts_minutes_before": Schema.integers("Alerts, in minutes before the start (0 to 10080)."),
        ], required: ["title", "start", "end"]),
        readOnly: false,
        requirements: [.calendars]
    ) { arguments, context in
        let store = context.events.current()
        let event = EKEvent(eventStore: store)
        event.title = try arguments.requiredString("title")
        try applyTimes(event, arguments, requireBoth: true)
        if let id = try arguments.string("calendar_id") {
            event.calendar = try writableCalendar(store, id: id, type: .event)
        } else {
            guard let calendar = store.defaultCalendarForNewEvents else {
                throw ToolFailure.notFound("There is no default calendar. Pass calendar_id.")
            }
            event.calendar = calendar
        }
        event.location = try arguments.string("location")
        event.notes = try arguments.string("notes")
        if let link = try arguments.string("url") { event.url = URL(string: link) }
        for minutes in try arguments.ints("alerts_minutes_before", in: 0...10_080) {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }
        try store.save(event, span: .thisEvent, commit: true)
        return ["event": eventValue(event)]
    }

    static let updateEvent = ToolDefinition(
        app: .calendar,
        name: "update_event",
        title: "Change or cancel event",
        description: "Changes or deletes an event. For a recurring event, pass occurrence_start to pick one occurrence, and span: future to change it and all later ones. Fields left out stay as they are.",
        inputSchema: Schema.object([
            "id": Schema.string("Event id from calendar_list_events."),
            "occurrence_start": Schema.date("Start of the occurrence, for a recurring event."),
            "span": Schema.string("For a recurring event: this occurrence only, or this and future ones.", enum: ["this", "future"]),
            "cancel": Schema.boolean("Delete the event instead of changing it."),
            "title": Schema.string("New title."),
            "start": Schema.date("New start."),
            "end": Schema.date("New end."),
            "all_day": Schema.boolean("Make it an all-day event, or not."),
            "calendar_id": Schema.string("Move it to this calendar."),
            "location": Schema.string("New location. Null clears it."),
            "notes": Schema.string("New notes. Null clears them."),
        ], required: ["id"]),
        readOnly: false,
        destructive: true,
        requirements: [.calendars]
    ) { arguments, context in
        let store = context.events.current()
        let event = try findEvent(store, id: arguments.requiredString("id"), occurrence: arguments.date("occurrence_start")?.date)
        guard event.calendar.allowsContentModifications else {
            throw ToolFailure("read_only", "The calendar \(event.calendar.title) cannot be changed.")
        }
        let span: EKSpan = try arguments.choice("span", ["this", "future"], default: "this") == "future" ? .futureEvents : .thisEvent
        if try arguments.bool("cancel") == true {
            let removed = eventValue(event)
            try store.remove(event, span: span, commit: true)
            return ["cancelled": .bool(true), "event": removed]
        }
        if let title = try arguments.string("title") { event.title = title }
        try applyTimes(event, arguments, requireBoth: false)
        if let id = try arguments.string("calendar_id") {
            event.calendar = try writableCalendar(store, id: id, type: .event)
        }
        if arguments.isNull("location") { event.location = nil } else if let location = try arguments.string("location") {
            event.location = location
        }
        if arguments.isNull("notes") { event.notes = nil } else if let notes = try arguments.string("notes") {
            event.notes = notes
        }
        try store.save(event, span: span, commit: true)
        return ["event": eventValue(event)]
    }

    // MARK: - Helpers

    private static func applyTimes(_ event: EKEvent, _ arguments: Arguments, requireBoth: Bool) throws {
        let start = requireBoth ? try arguments.requiredDate("start") : try arguments.date("start")
        let end = requireBoth ? try arguments.requiredDate("end") : try arguments.date("end")
        let allDay = try arguments.bool("all_day") ?? (requireBoth ? (start?.dateOnly ?? false) : event.isAllDay)
        event.isAllDay = allDay
        if let start { event.startDate = start.date }
        if let end {
            // An all-day event's end names its last day.
            event.endDate = allDay && end.dateOnly ? end.date.addingTimeInterval(86_399) : end.date
        }
        guard event.endDate >= event.startDate else {
            throw ToolFailure.invalidArguments("end", "end must not be before start.")
        }
    }

    private static func findEvent(_ store: EKEventStore, id: String, occurrence: Date?) throws -> EKEvent {
        guard let first = store.event(withIdentifier: id) else {
            throw ToolFailure.notFound("No event has id \(id).")
        }
        guard let occurrence = try occurrenceToChange(recurring: first.hasRecurrenceRules, occurrence) else {
            return first
        }
        let window = store.predicateForEvents(
            withStart: occurrence.addingTimeInterval(-60), end: occurrence.addingTimeInterval(86_400),
            calendars: [first.calendar])
        let match = store.events(matching: window).first {
            $0.eventIdentifier == id && abs($0.startDate.timeIntervalSince(occurrence)) < 1
        }
        guard let match else {
            throw ToolFailure.notFound("The event has no occurrence starting at \(DateText.dateTime(occurrence)).")
        }
        return match
    }

    /// The occurrence of a recurring event a change applies to. EventKit answers
    /// an id alone with the series' first occurrence, and every occurrence has the
    /// same id: without its start, a change would go to the wrong one or, with
    /// span future, to the whole series.
    static func occurrenceToChange(recurring: Bool, _ occurrence: Date?) throws -> Date? {
        guard recurring else { return nil }
        guard let occurrence else {
            throw ToolFailure.invalidArguments(
                "occurrence_start",
                "The event repeats. Pass occurrence_start, the start of the occurrence to change, as calendar_list_events gives it."
            )
        }
        return occurrence
    }

    static func selectedCalendars(_ store: EKEventStore, ids: [String], type: EKEntityType) throws -> [EKCalendar]? {
        guard !ids.isEmpty else { return nil }
        return try ids.map { id in
            guard let calendar = store.calendar(withIdentifier: id), calendar.allowedEntityTypes.contains(type == .event ? .event : .reminder) else {
                throw ToolFailure.notFound("No calendar has id \(id).")
            }
            return calendar
        }
    }

    static func writableCalendar(_ store: EKEventStore, id: String, type: EKEntityType) throws -> EKCalendar {
        guard let calendar = try selectedCalendars(store, ids: [id], type: type)?.first else {
            throw ToolFailure.notFound("No calendar has id \(id).")
        }
        guard calendar.allowsContentModifications else {
            throw ToolFailure("read_only", "The calendar \(calendar.title) cannot be changed.")
        }
        return calendar
    }

    static func eventValue(_ event: EKEvent) -> Value {
        let allDay = event.isAllDay
        let attendees = (event.attendees ?? []).map { person -> Value in
            [
                "name": .optional(person.name),
                "email": .optional(email(person.url)),
                "status": .string(participantStatus(person.participantStatus)),
            ]
        }
        return [
            "id": .optional(event.eventIdentifier),
            "occurrence_start": .optional(event.startDate, dateOnly: allDay),
            "calendar_id": .string(event.calendar.calendarIdentifier),
            "calendar": .string(event.calendar.title),
            "calendar_color": .string(hexColor(event.calendar.cgColor)),
            "title": .string(event.title ?? ""),
            "start": .optional(event.startDate, dateOnly: allDay),
            "end": .optional(event.endDate, dateOnly: allDay),
            "all_day": .bool(allDay),
            "location": .optional(event.location),
            "notes": .optional(event.notes.map { truncated($0, 2_000) }),
            "url": .optional(event.url?.absoluteString),
            "recurring": .bool(event.hasRecurrenceRules),
            "organizer": .optional(event.organizer?.name),
            "attendees": .array(attendees),
        ]
    }

    private static func email(_ url: URL) -> String? {
        let text = url.absoluteString
        return text.lowercased().hasPrefix("mailto:") ? String(text.dropFirst(7)) : nil
    }

    private static func participantStatus(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "pending"
        case .delegated: "delegated"
        case .completed: "completed"
        case .inProcess: "in_process"
        default: "unknown"
        }
    }

    static func hexColor(_ color: CGColor?) -> String {
        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "" }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded()))
    }
}

func truncated(_ text: String, _ limit: Int) -> String {
    text.count <= limit ? text : String(text.prefix(limit)) + "…"
}
