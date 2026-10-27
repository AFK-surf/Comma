import EventKit
import Foundation
import MCP

enum RemindersTools {
    static let all: [ToolDefinition] = [listLists, list, create, complete, update]

    static let listLists = ToolDefinition(
        app: .reminders,
        name: "list_lists",
        title: "List reminder lists",
        description: "Lists the lists in the Reminders app on the user's Mac.",
        inputSchema: Schema.object(),
        readOnly: true,
        requirements: [.reminders]
    ) { _, context in
        let store = context.events.current()
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        let lists = store.calendars(for: .reminder).map { list -> Value in
            [
                "id": .string(list.calendarIdentifier),
                "title": .string(list.title),
                "account": .string(list.source.title),
                "color": .string(CalendarTools.hexColor(list.cgColor)),
                "is_default": .bool(list.calendarIdentifier == defaultID),
            ]
        }
        return ["lists": .array(lists)]
    }

    static let list = ToolDefinition(
        app: .reminders,
        name: "list",
        title: "List reminders",
        description: "Lists reminders. Open ones are sorted by due date, with undated ones last; completed ones by completion, newest first.",
        inputSchema: Schema.object([
            "list_ids": Schema.strings("Only these lists."),
            "status": Schema.string("Which reminders. Defaults to open.", enum: ["open", "completed", "all"]),
            "due_after": Schema.date("Only reminders due at or after this."),
            "due_before": Schema.date("Only reminders due before this."),
            "query": Schema.string("Only reminders whose title or notes contain this text."),
            "limit": Schema.integer(Schema.limitDescription, minimum: 1, maximum: 200),
        ]),
        readOnly: true,
        requirements: [.reminders]
    ) { arguments, context in
        let status = try arguments.choice("status", ["open", "completed", "all"], default: "open")
        let dueAfter = try arguments.date("due_after")?.date
        let dueBefore = try arguments.date("due_before")?.date
        let query = try arguments.string("query")?.lowercased()
        let limit = try arguments.limit(default: 50, max: 200)
        let store = context.events.current()
        let lists = try CalendarTools.selectedCalendars(store, ids: arguments.strings("list_ids"), type: .reminder)

        var reminders = try await fetch(store, store.predicateForReminders(in: lists)).filter { reminder in
            switch status {
            case "open": !reminder.isCompleted
            case "completed": reminder.isCompleted
            default: true
            }
        }
        if dueAfter != nil || dueBefore != nil {
            reminders = reminders.filter { reminder in
                guard let due = dueDate(reminder) else { return false }
                if let dueAfter, due < dueAfter { return false }
                if let dueBefore, due >= dueBefore { return false }
                return true
            }
        }
        if let query, !query.isEmpty {
            reminders = reminders.filter { reminder in
                [reminder.title, reminder.notes].contains { $0?.lowercased().contains(query) ?? false }
            }
        }
        reminders.sort { left, right in
            if left.isCompleted != right.isCompleted { return !left.isCompleted }
            if left.isCompleted {
                return (left.completionDate ?? .distantPast) > (right.completionDate ?? .distantPast)
            }
            return (dueDate(left) ?? .distantFuture) < (dueDate(right) ?? .distantFuture)
        }
        return [
            "reminders": .array(reminders.prefix(limit).map(reminderValue)),
            "truncated": .bool(reminders.count > limit),
        ]
    }

    static let create = ToolDefinition(
        app: .reminders,
        name: "create",
        title: "Create reminder",
        description: "Creates a reminder. A due date with a time also alerts the user at that time.",
        inputSchema: Schema.object([
            "title": Schema.string("What to be reminded of."),
            "list_id": Schema.string("List to add it to. Defaults to the user's default list."),
            "notes": Schema.string("Notes."),
            "due": Schema.date("When it is due."),
            "priority": Schema.string("Priority.", enum: ["none", "low", "medium", "high"]),
            "url": Schema.string("A link."),
        ], required: ["title"]),
        readOnly: false,
        requirements: [.reminders]
    ) { arguments, context in
        let store = context.events.current()
        let reminder = EKReminder(eventStore: store)
        reminder.title = try arguments.requiredString("title")
        if let id = try arguments.string("list_id") {
            reminder.calendar = try CalendarTools.writableCalendar(store, id: id, type: .reminder)
        } else {
            guard let list = store.defaultCalendarForNewReminders() else {
                throw ToolFailure.notFound("There is no default reminder list. Pass list_id.")
            }
            reminder.calendar = list
        }
        reminder.notes = try arguments.string("notes")
        if let link = try arguments.string("url") { reminder.url = URL(string: link) }
        if let priority = try arguments.string("priority") { reminder.priority = try priorityValue(priority) }
        if let due = try arguments.date("due") { setDue(reminder, due) }
        try store.save(reminder, commit: true)
        return ["reminder": reminderValue(reminder)]
    }

    static let complete = ToolDefinition(
        app: .reminders,
        name: "complete",
        title: "Complete reminder",
        description: "Marks a reminder completed, or open again with completed: false.",
        inputSchema: Schema.object([
            "id": Schema.string("Reminder id from reminders_list."),
            "completed": Schema.boolean("Defaults to true."),
        ], required: ["id"]),
        readOnly: false,
        requirements: [.reminders]
    ) { arguments, context in
        let store = context.events.current()
        let reminder = try find(store, arguments.requiredString("id"))
        reminder.isCompleted = try arguments.bool("completed") ?? true
        try store.save(reminder, commit: true)
        return ["reminder": reminderValue(reminder)]
    }

    static let update = ToolDefinition(
        app: .reminders,
        name: "update",
        title: "Change or delete reminder",
        description: "Changes or deletes a reminder. Fields left out stay as they are; null clears due or notes.",
        inputSchema: Schema.object([
            "id": Schema.string("Reminder id from reminders_list."),
            "delete": Schema.boolean("Delete the reminder instead of changing it."),
            "title": Schema.string("New title."),
            "notes": Schema.string("New notes. Null clears them."),
            "due": Schema.date("New due date. Null clears it."),
            "priority": Schema.string("New priority.", enum: ["none", "low", "medium", "high"]),
            "list_id": Schema.string("Move it to this list."),
        ], required: ["id"]),
        readOnly: false,
        destructive: true,
        requirements: [.reminders]
    ) { arguments, context in
        let store = context.events.current()
        let reminder = try find(store, arguments.requiredString("id"))
        if try arguments.bool("delete") == true {
            let removed = reminderValue(reminder)
            try store.remove(reminder, commit: true)
            return ["deleted": .bool(true), "reminder": removed]
        }
        if let title = try arguments.string("title") { reminder.title = title }
        if arguments.isNull("notes") { reminder.notes = nil } else if let notes = try arguments.string("notes") {
            reminder.notes = notes
        }
        if arguments.isNull("due") {
            reminder.dueDateComponents = nil
            reminder.alarms?.forEach(reminder.removeAlarm)
        } else if let due = try arguments.date("due") {
            reminder.alarms?.forEach(reminder.removeAlarm)
            setDue(reminder, due)
        }
        if let priority = try arguments.string("priority") { reminder.priority = try priorityValue(priority) }
        if let id = try arguments.string("list_id") {
            reminder.calendar = try CalendarTools.writableCalendar(store, id: id, type: .reminder)
        }
        try store.save(reminder, commit: true)
        return ["reminder": reminderValue(reminder)]
    }

    // MARK: - Helpers

    private static func fetch(_ store: EKEventStore, _ predicate: NSPredicate) async throws -> [EKReminder] {
        try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private static func find(_ store: EKEventStore, _ id: String) throws -> EKReminder {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolFailure.notFound("No reminder has id \(id).")
        }
        return reminder
    }

    private static func setDue(_ reminder: EKReminder, _ due: (date: Date, dateOnly: Bool)) {
        let calendar = Calendar.current
        if due.dateOnly {
            reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day], from: due.date)
        } else {
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due.date)
            parts.timeZone = .current
            reminder.dueDateComponents = parts
            reminder.addAlarm(EKAlarm(absoluteDate: due.date))
        }
    }

    private static func dueDate(_ reminder: EKReminder) -> Date? {
        guard let parts = reminder.dueDateComponents else { return nil }
        return Calendar.current.date(from: parts)
    }

    private static func priorityValue(_ name: String) throws -> Int {
        switch name {
        case "high": return 1
        case "medium": return 5
        case "low": return 9
        case "none": return 0
        default: throw ToolFailure.invalidArguments("priority", "priority must be none, low, medium or high.")
        }
    }

    private static func priorityName(_ value: Int) -> String {
        switch value {
        case 1...4: "high"
        case 5: "medium"
        case 6...9: "low"
        default: "none"
        }
    }

    static func reminderValue(_ reminder: EKReminder) -> Value {
        let parts = reminder.dueDateComponents
        let hasTime = parts?.hour != nil
        return [
            "id": .string(reminder.calendarItemIdentifier),
            "list_id": .string(reminder.calendar.calendarIdentifier),
            "list": .string(reminder.calendar.title),
            "list_color": .string(CalendarTools.hexColor(reminder.calendar.cgColor)),
            "title": .string(reminder.title ?? ""),
            "notes": .optional(reminder.notes.map { truncated($0, 2_000) }),
            "due": .optional(dueDate(reminder), dateOnly: !hasTime),
            "priority": .string(priorityName(reminder.priority)),
            "completed": .bool(reminder.isCompleted),
            "completed_at": .optional(reminder.completionDate),
            "url": .optional(reminder.url?.absoluteString),
        ]
    }
}
