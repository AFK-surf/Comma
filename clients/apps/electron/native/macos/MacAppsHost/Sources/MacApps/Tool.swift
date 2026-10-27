import Foundation
import MCP

/// One Mac app the user turns on or off in Plugins. A tool's name starts
/// with its app's prefix; Comma's Main relies on that to filter tools.
public enum MacApp: String, CaseIterable, Sendable {
    case calendar
    case reminders
    case contacts
    case messages
    case mail
    case notes
    case music
    case maps
    case system
    case vision

    public var toolPrefix: String { rawValue + "_" }
}

/// A macOS privacy permission a tool depends on.
public enum Requirement: Hashable, Sendable {
    case calendars
    case reminders
    case contacts
    case screenRecording
    /// Apple Events to the app with this bundle identifier ("Automation").
    case automation(String)

    public var id: String {
        switch self {
        case .calendars: "calendars"
        case .reminders: "reminders"
        case .contacts: "contacts"
        case .screenRecording: "screen_recording"
        case let .automation(bundleID): "automation:\(bundleID)"
        }
    }
}

public enum BundleID {
    public static let messages = "com.apple.MobileSMS"
    public static let mail = "com.apple.mail"
    public static let notes = "com.apple.Notes"
    public static let music = "com.apple.Music"
    public static let systemEvents = "com.apple.systemevents"
}

public enum PermissionState: String, Sendable {
    case granted
    case notDetermined = "not_determined"
    case denied
    case restricted
    /// Asked before or never; macOS does not say which (Screen Recording).
    case notGranted = "not_granted"
    /// An Automation target that is not running cannot be asked about.
    case unknown
    /// Nothing to grant on this Mac (for example, Messages was never set up).
    case unavailable
}

/// A tool failure the Agent can act on. The code is stable; the message is for people.
public struct ToolFailure: Error, Sendable {
    public let code: String
    public let message: String
    public var details: [String: Value] = [:]

    public init(_ code: String, _ message: String, details: [String: Value] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }

    public static func invalidArguments(_ field: String, _ message: String) -> ToolFailure {
        ToolFailure("invalid_arguments", message, details: ["field": .string(field)])
    }

    public static func notFound(_ message: String) -> ToolFailure {
        ToolFailure("not_found", message)
    }

    public static func permissionRequired(_ requirement: Requirement, _ state: PermissionState) -> ToolFailure {
        ToolFailure(
            "permission_required",
            "Comma does not have macOS permission for this. Ask the user to allow it in Comma > Plugins on this Mac.",
            details: ["requirement": .string(requirement.id), "state": .string(state.rawValue)]
        )
    }

    var value: Value {
        var error: [String: Value] = ["code": .string(code), "message": .string(message)]
        for (key, value) in details { error[key] = value }
        return ["error": .object(error)]
    }
}

public struct ToolDefinition: Sendable {
    public let app: MacApp
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: Value
    public let readOnly: Bool
    /// Meaningful only when not read-only: true when the tool can change or remove existing data.
    public let destructive: Bool
    /// True when the tool reaches outside this Mac's own data (sends a message, queries Apple Maps).
    public let openWorld: Bool
    /// Checked before the tool runs; a missing one is reported, never prompted for.
    public let requirements: [Requirement]
    public let run: @Sendable (Arguments, ToolContext) async throws -> Value

    public init(
        app: MacApp,
        name: String,
        title: String,
        description: String,
        inputSchema: Value,
        readOnly: Bool,
        destructive: Bool = false,
        openWorld: Bool = false,
        requirements: [Requirement] = [],
        run: @escaping @Sendable (Arguments, ToolContext) async throws -> Value
    ) {
        self.app = app
        self.name = app.toolPrefix + name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
        self.openWorld = openWorld
        self.requirements = requirements
        self.run = run
    }

    var mcpTool: Tool {
        Tool(
            name: name,
            title: title,
            description: description,
            inputSchema: inputSchema,
            annotations: .init(
                title: title,
                readOnlyHint: readOnly,
                destructiveHint: readOnly ? nil : destructive,
                openWorldHint: openWorld
            )
        )
    }
}

/// JSON Schema for a tool's input: an object with the given properties.
enum Schema {
    static func object(_ properties: [String: Value] = [:], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    static func string(_ description: String, enum values: [String]? = nil) -> Value {
        var schema: [String: Value] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map { .string($0) }) }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }

    static func number(_ description: String) -> Value {
        ["type": "number", "description": .string(description)]
    }

    static func boolean(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }

    static func strings(_ description: String) -> Value {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    static func integers(_ description: String) -> Value {
        ["type": "array", "items": ["type": "integer"], "description": .string(description)]
    }

    /// A date or date-time. Time zone offsets are honoured; a value without one is this Mac's local time.
    static func date(_ description: String) -> Value {
        string(description + " ISO 8601: 2026-10-12, 2026-10-12T15:00 (this Mac's time zone) or 2026-10-12T15:00:00+08:00.")
    }

    static let limitDescription = "Maximum number of results."
}

extension Value {
    static func optional(_ string: String?) -> Value {
        string.map { .string($0) } ?? .null
    }

    static func optional(_ date: Date?, dateOnly: Bool = false) -> Value {
        guard let date else { return .null }
        return .string(dateOnly ? DateText.day(date) : DateText.dateTime(date))
    }

    var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

/// Dates as the tools read and write them.
public enum DateText {
    public static func dateTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Parses an ISO 8601 date or date-time. `dateOnly` is true for a bare day, which is local midnight.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> (date: Date, dateOnly: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return (date, false) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return (date, false) }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        local.calendar = Calendar(identifier: .gregorian)
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: trimmed) { return (date, false) }
        }
        local.dateFormat = "yyyy-MM-dd"
        if trimmed.count == 10, let date = local.date(from: trimmed) { return (date, true) }
        return nil
    }
}
